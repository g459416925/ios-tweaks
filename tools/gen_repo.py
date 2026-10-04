#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_repo.py —— 扫描 debs/ 生成 APT 源索引（Packages / Packages.bz2 / Release）

用法（任意位置均可）:
    python3 tools/gen_repo.py

产出（写到仓库根）:
    Packages      明文索引
    Packages.bz2  bzip2 压缩（Sileo / Cydia 优先读它）
    Release       含 MD5Sum / SHA256 校验（apt-get update 需要）

以后新增插件：把 deb 丢进 debs/，重跑本脚本即可。

注意：macOS 的 APFS 默认大小写不敏感，仓库根目录里**不能**同时存在
      `Packages`（索引文件）和一个 `packages/`（目录），否则互相覆盖。
      因此源码目录已命名为 `src/`。
"""
import os, io, gzip, tarfile, hashlib, bz2, lzma, email.utils

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

ORIGIN = "g459416925"
LABEL  = "g459416925's iOS Tweaks"
DESC   = "Personal iOS tweak repository (RootHide / arm64e)"


def read_control(deb_path):
    """从 .deb（Debian ar 归档）里取出 control.tar.*，再解出 control 文本"""
    raw = open(deb_path, "rb").read()
    if raw[:8] != b"!<arch>\n":
        raise SystemExit("不是合法的 ar 归档: %s" % deb_path)
    off, ctl_blob = 8, None
    while off + 60 <= len(raw):
        hdr = raw[off:off + 60]
        name = hdr[0:16].decode("ascii", "replace").strip()
        size = int(hdr[48:58].decode("ascii").strip())
        data = raw[off + 60:off + 60 + size]
        if name.startswith("control.tar"):
            ctl_blob = data
        off += 60 + size + (size % 2)
    if not ctl_blob:
        raise SystemExit("deb 里没有 control.tar.*: %s" % deb_path)

    if ctl_blob[:2] == b"\x1f\x8b":
        buf = io.BytesIO(gzip.decompress(ctl_blob))
    elif ctl_blob[:6] == b"\xfd7zXZ\x00":
        buf = io.BytesIO(lzma.decompress(ctl_blob))
    else:
        buf = io.BytesIO(ctl_blob)

    with tarfile.open(fileobj=buf) as tf:
        for m in tf.getmembers():
            if m.name.endswith("control"):
                return tf.extractfile(m).read().decode("utf-8")
    raise SystemExit("control 未找到: %s" % deb_path)


def main():
    debs_dir = os.path.join(ROOT, "debs")
    if not os.path.isdir(debs_dir):
        raise SystemExit("找不到 debs/ 目录")

    entries = []
    for fn in sorted(os.listdir(debs_dir)):
        if not fn.endswith(".deb"):
            continue
        p = os.path.join(debs_dir, fn)
        blob = open(p, "rb").read()
        ctl = read_control(p).rstrip()
        extra = [
            "Filename: ./debs/%s" % fn,
            "Size: %d" % len(blob),
            "MD5sum: %s" % hashlib.md5(blob).hexdigest(),
            "SHA256: %s" % hashlib.sha256(blob).hexdigest(),
        ]
        entries.append(ctl + "\n" + "\n".join(extra) + "\n")
        print("  + %s" % fn)

    body = "\n".join(entries).encode("utf-8")
    open(os.path.join(ROOT, "Packages"), "wb").write(body)
    open(os.path.join(ROOT, "Packages.bz2"), "wb").write(bz2.compress(body, 9))

    def sum_line(name, algo):
        d = open(os.path.join(ROOT, name), "rb").read()
        h = hashlib.md5(d).hexdigest() if algo == "md5" else hashlib.sha256(d).hexdigest()
        return " %s %d %s" % (h, len(d), name)

    lines = [
        "Origin: %s" % ORIGIN,
        "Label: %s" % LABEL,
        "Suite: stable",
        "Version: 1.0",
        "Codename: ios",
        "Date: %s" % email.utils.formatdate(usegmt=True),
        "Architectures: iphoneos-arm64e iphoneos-arm64 iphoneos-arm",
        "Components: main",
        "Description: %s" % DESC,
        "MD5Sum:",
    ]
    for n in ("Packages", "Packages.bz2"):
        lines.append(sum_line(n, "md5"))
    lines.append("SHA256:")
    for n in ("Packages", "Packages.bz2"):
        lines.append(sum_line(n, "sha256"))
    lines.append("")
    open(os.path.join(ROOT, "Release"), "w", encoding="utf-8").write("\n".join(lines))

    print("完成：%d 个包 → Packages / Packages.bz2 / Release" % len(entries))


if __name__ == "__main__":
    main()
