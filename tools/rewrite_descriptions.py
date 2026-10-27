#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
rewrite_descriptions.py —— 统一重写 debs/ 下所有 .deb 的 control 元数据

写入两个字段（数据源唯一：tools/pkgmeta.py）：
    Description:     <分类> · <一句话定位>
                     【功能】/【范围】/【类型】/【宿主】/【兼容】
    SileoDepiction:  https://.../depictions/<包名>.json   ← Sileo 原生卡片式详情页

规范格式（所有包一致，顺序固定）：
    Description: <分类> · <定位>
     【功能】
     · ……
     【范围】/【类型】/【宿主】
     【兼容】

规则：
  - 只改 control 成员里的 Description / SileoDepiction；其余字段与顺序不变
  - control.tar 内其它成员（postinst/prerm 等）、压缩格式原样保留
  - data.tar.* 字节零改动（内部 dylib 及签名不受影响），重写后逐包校验
  - 同一包所有历史版本写入同一份规范描述（装哪个版本详情页都一致）

用法：
    python3 tools/rewrite_descriptions.py          # 执行重写
    python3 tools/rewrite_descriptions.py --check  # 只校验不写入
"""
import copy
import hashlib
import io
import os
import sys
import tarfile
import gzip
import lzma

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEBS = os.path.join(ROOT, "debs")
sys.path.insert(0, HERE)

from pkgmeta import PKGS, synopsis, description_lines, depiction_url

AR_MAGIC = b"!<arch>\n"


# ---------------------------------------------------------------------------
# deb (ar 归档) 解析 / 重建
# ---------------------------------------------------------------------------
def split_ar(raw):
    """解析 ar 归档 → [(name, hdr60, data)]"""
    if raw[:8] != AR_MAGIC:
        raise ValueError("不是合法的 ar 归档")
    out, off = [], 8
    while off + 60 <= len(raw):
        hdr = raw[off:off + 60]
        name = hdr[0:16].decode("ascii", "replace").rstrip(" \x00")
        size = int(hdr[48:58].decode("ascii").strip())
        out.append((name, hdr, raw[off + 60:off + 60 + size]))
        off += 60 + size + (size % 2)
    return out


def build_ar(members):
    """members: [(name, hdr60, data)] → ar 字节流；仅更新 size 字段，其余头部字节保留"""
    out = bytearray(AR_MAGIC)
    for _name, hdr, data in members:
        h = bytearray(hdr)
        h[48:58] = b"%10d" % len(data)
        out += h
        out += data
        if len(data) % 2:
            out += b"\n"
    return bytes(out)


# ---------------------------------------------------------------------------
# control 文本重写
# ---------------------------------------------------------------------------
def rewrite_control_text(ctl_text, pkg):
    """原位替换 Description 块，插入/更新 SileoDepiction，其余字段与顺序保持不变"""
    syn, lines = synopsis(pkg), description_lines(pkg)

    src = ctl_text.split("\n")
    out, i, seen_desc, seen_dep = [], 0, False, False
    while i < len(src):
        ln = src[i]
        if ln.startswith("Description:"):
            out.append("Description: " + syn)
            for cl in lines:
                out.append(" " + cl)
            i += 1
            while i < len(src) and src[i].startswith(" "):
                i += 1
            seen_desc = True
            # SileoDepiction 紧跟 Description 之后（APT 惯例）
            out.append("SileoDepiction: " + depiction_url(pkg))
            seen_dep = True
            continue
        if ln.startswith("SileoDepiction:"):
            i += 1
            continue  # 统一在 Description 后重写
        out.append(ln)
        i += 1

    if not seen_desc:
        raise ValueError("control 里没有 Description 字段")
    if not seen_dep:
        # 无 Description 的极端情况才会走到这；补在末尾
        out.append("SileoDepiction: " + depiction_url(pkg))

    # 去掉尾部多余空行差异：保留原始尾部结构
    return "\n".join(out)


def fields_except_description(ctl_text):
    """提取除 Description / SileoDepiction 外的全部字段行（供前后一致性比对）"""
    lines = ctl_text.split("\n")
    out, i = [], 0
    while i < len(lines):
        if lines[i].startswith("Description:"):
            i += 1
            while i < len(lines) and lines[i].startswith(" "):
                i += 1
            continue
        if lines[i].startswith("SileoDepiction:"):
            i += 1
            continue
        out.append(lines[i])
        i += 1
    return out


# ---------------------------------------------------------------------------
# control.tar 重写
# ---------------------------------------------------------------------------
def rewrite_control_tar(ctl_blob, pkg):
    """解压 control.tar.* → 重写 control 成员 → 按原压缩格式重打包"""
    if ctl_blob[:2] == b"\x1f\x8b":
        mode, raw_tar = "w:gz", gzip.decompress(ctl_blob)
    elif ctl_blob[:6] == b"\xfd7zXZ\x00":
        mode, raw_tar = "w:xz", lzma.decompress(ctl_blob)
    else:
        mode, raw_tar = "w", ctl_blob

    src = tarfile.open(fileobj=io.BytesIO(raw_tar))
    members = src.getmembers()
    out = io.BytesIO()
    replaced = False
    with tarfile.open(fileobj=out, mode=mode, format=tarfile.GNU_FORMAT) as dst:
        for m in members:
            f = src.extractfile(m) if m.isreg() else None
            mi = copy.copy(m)
            if f is not None and m.name.rstrip("/").endswith("control"):
                old = f.read().decode("utf-8")
                new = rewrite_control_text(old, pkg)
                b = new.encode("utf-8")
                mi.size = len(b)
                dst.addfile(mi, io.BytesIO(b))
                replaced = True
            elif f is not None:
                mi.size = m.size
                dst.addfile(mi, f)
            else:
                dst.addfile(mi)
    if not replaced:
        raise ValueError("control.tar 里没有 control 成员")
    return out.getvalue()


def read_control_text(ctl_blob):
    if ctl_blob[:2] == b"\x1f\x8b":
        raw_tar = gzip.decompress(ctl_blob)
    elif ctl_blob[:6] == b"\xfd7zXZ\x00":
        raw_tar = lzma.decompress(ctl_blob)
    else:
        raw_tar = ctl_blob
    with tarfile.open(fileobj=io.BytesIO(raw_tar)) as tf:
        for m in tf.getmembers():
            if m.name.rstrip("/").endswith("control"):
                return tf.extractfile(m).read().decode("utf-8")
    raise ValueError("control 未找到")


def package_name(ctl_text):
    for ln in ctl_text.split("\n"):
        if ln.startswith("Package:"):
            return ln.split(":", 1)[1].strip()
    raise ValueError("control 里没有 Package 字段")


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def process_deb(path, check_only=False):
    raw = open(path, "rb").read()
    members = split_ar(raw)
    ctl_idx = next(i for i, (n, _, _) in enumerate(members) if n.startswith("control.tar"))
    ctl_name, _, ctl_blob = members[ctl_idx]

    old_ctl = read_control_text(ctl_blob)
    pkg = package_name(old_ctl)
    if pkg not in PKGS:
        return ("SKIP", pkg, None)

    if check_only:
        syn, lines = synopsis(pkg), description_lines(pkg)
        want = ("Description: " + syn) + "".join("\n " + c for c in lines)
        ok = want in old_ctl and ("SileoDepiction: " + depiction_url(pkg)) in old_ctl
        return ("OK" if ok else "MISMATCH", pkg, None)

    new_ctl_blob = rewrite_control_tar(ctl_blob, pkg)
    new_members = list(members)
    new_members[ctl_idx] = (ctl_name, members[ctl_idx][1], new_ctl_blob)
    new_raw = build_ar(new_members)

    # ---- 校验：data.tar.* 字节必须与原来完全一致 ----
    old_data = {n: d for n, _, d in members if n.startswith("data.tar")}
    new_data = {n: d for n, _, d in split_ar(new_raw) if n.startswith("data.tar")}
    assert old_data == new_data, "%s: data.tar 变了！" % path
    # ---- 校验：新 control 可读回，Description / SileoDepiction 均已写入 ----
    new_ctl = read_control_text(new_ctl_blob)
    assert ("Description: " + synopsis(pkg)) in new_ctl, "%s: Description 未替换" % path
    assert ("SileoDepiction: " + depiction_url(pkg)) in new_ctl, "%s: SileoDepiction 未写入" % path
    # ---- 校验：其余字段不变 ----
    assert fields_except_description(old_ctl) == fields_except_description(new_ctl), \
        "%s: 其余 control 字段被改动" % path

    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(new_raw)
    os.replace(tmp, path)
    return ("DONE", pkg, (hashlib.sha256(raw).hexdigest()[:12],
                          hashlib.sha256(new_raw).hexdigest()[:12]))


def main():
    check_only = "--check" in sys.argv
    stats = {}
    for fn in sorted(os.listdir(DEBS)):
        if not fn.endswith(".deb"):
            continue
        p = os.path.join(DEBS, fn)
        try:
            status, pkg, extra = process_deb(p, check_only)
        except Exception as e:
            print("  !! %s: %s" % (fn, e))
            stats.setdefault("FAIL", []).append(fn)
            continue
        stats.setdefault(status, []).append(fn)
        if status == "DONE":
            print("  %s %-55s %s %s→%s" % (status, fn, pkg, extra[0], extra[1]))
        elif status in ("MISMATCH", "SKIP"):
            print("  %s %-55s %s" % (status, fn, pkg))
    print("\n== 汇总 ==")
    for k in ("DONE", "OK", "MISMATCH", "SKIP", "FAIL"):
        if k in stats:
            print("  %-8s %d" % (k, len(stats[k])))
    if "FAIL" in stats or "MISMATCH" in stats:
        sys.exit(1)


if __name__ == "__main__":
    main()
