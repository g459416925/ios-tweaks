#!/usr/bin/env python3
"""debbuild.py — 纯 Python 打 .deb（ar + xz），不依赖 dpkg-deb。

用法：debbuild.py <stage目录> <输出deb>
  stage/ 下：
    DEBIAN/control, DEBIAN/postinst, DEBIAN/postrm
    其余路径原样进 data.tar.xz

权限：.dylib / 可执行 -> 0755；DEBIAN 脚本 -> 0755；其余 -> 0644（沿用文件本身模式位）。
"""
import io
import lzma
import os
import sys
import tarfile
import time


def tgz(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        for name, data, mode in entries:
            ti = tarfile.TarInfo(name)
            ti.mode = mode
            ti.uid = ti.gid = 0
            ti.uname = "root"
            ti.gname = "wheel"
            ti.mtime = int(time.time())
            if name.endswith("/"):
                ti.type = tarfile.DIRTYPE
                ti.size = 0
                tf.addfile(ti)
            else:
                ti.size = len(data)
                tf.addfile(ti, io.BytesIO(data))
    return lzma.compress(buf.getvalue(), preset=6)


def ar_write(path, members):
    out = b"!<arch>\n"
    for name, data in members:
        header = ("%-16s%-12d%-6d%-6d%-8s%-10d`\n"
                  % (name, int(time.time()), 0, 0, "100644", len(data))).encode()
        out += header + data
        if len(data) % 2:
            out += b"\n"
    with open(path, "wb") as f:
        f.write(out)


def collect(stage):
    """返回 data 条目（排除 DEBIAN/）与 control 条目。"""
    data, ctrl = [], []
    for dirpath, dirnames, filenames in os.walk(stage):
        dirnames.sort()
        rel_dir = os.path.relpath(dirpath, stage)
        is_debian = (rel_dir == "DEBIAN" or rel_dir.startswith("DEBIAN" + os.sep))
        if rel_dir != "." and not is_debian:
            data.append(("./" + rel_dir.replace(os.sep, "/") + "/", b"", 0o755))
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, stage).replace(os.sep, "/")
            with open(full, "rb") as f:
                blob = f.read()
            mode = os.stat(full).st_mode & 0o777
            if is_debian:
                ctrl.append(("./" + fn, blob, 0o755 if fn != "control" else 0o644))
            else:
                data.append(("./" + rel, blob, mode))
    return data, ctrl


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    stage, out = sys.argv[1], sys.argv[2]
    data, ctrl = collect(stage)
    names = {n for n, _, _ in ctrl}
    for need in ("./control",):
        if need not in names:
            raise SystemExit(f"缺少 DEBIAN/control：{need}")
    ar_write(out, [
        ("debian-binary", b"2.0\n"),
        ("control.tar.xz", tgz(sorted(ctrl))),
        ("data.tar.xz", tgz(data)),
    ])
    print(f"   deb: {out} ({os.path.getsize(out)} bytes, data {len(data)} 条, control {len(ctrl)} 条)")


if __name__ == "__main__":
    main()
