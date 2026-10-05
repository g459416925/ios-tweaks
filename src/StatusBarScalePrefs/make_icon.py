#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""make_icon.py —— 无依赖生成设置面板图标（iOS 蓝底 + 灵动岛 + 辅助条示意）"""
import zlib, struct, os

HERE = os.path.dirname(os.path.abspath(__file__))
SS = 4  # 超采样倍数

BG_TOP = (79, 168, 255)
BG_BOT = (10, 92, 255)
FG     = (255, 255, 255)


def _px(w, h):
    return [[(0, 0, 0, 0)] * w for _ in range(h)]


def _rounded(x, y, w, h, r, W, H):
    if x < 0 or y < 0 or x >= W or y >= H:
        return False
    cx = min(max(x, r), w - r)
    cy = min(max(y, r), h - r)
    dx, dy = x - cx, y - cy
    return dx * dx + dy * dy <= r * r


def render(size):
    W = H = size * SS
    img = _px(W, H)
    # ⚠️ 图形内容只占画布中央 84%、四周留 8% 透明边距 —— 设置列表的图标槽自带内边距，
    #    全出血圆角方块会显得比其他插件图标大一圈（实测 2026-10-05）。
    m = int(W * 0.08)
    bw = W - 2 * m
    radius = bw * 0.2237
    for y in range(m, H - m):
        t = (y - m) / max(1, bw - 1)
        col = tuple(int(BG_TOP[i] + (BG_BOT[i] - BG_TOP[i]) * t) for i in range(3))
        for x in range(m, W - m):
            lx, ly = x - m, y - m
            if _rounded(lx, ly, bw, bw, radius, bw, bw):
                img[y][x] = (col[0], col[1], col[2], 255)

    def fill_round(nx0, ny0, nx1, ny1, r, alpha):
        """归一化坐标相对中央背景区域（0..1 = 圆角方块内）"""
        X0 = m + int(nx0 * bw)
        Y0 = m + int(ny0 * bw)
        X1 = m + int(nx1 * bw)
        Y1 = m + int(ny1 * bw)
        rr = r * bw
        for y in range(Y0, Y1):
            for x in range(X0, X1):
                if x < 0 or y < 0 or x >= W or y >= H:
                    continue
                cx = min(max(x - X0, rr), (X1 - X0) - rr)
                cy = min(max(y - Y0, rr), (Y1 - Y0) - rr)
                dx, dy = (x - X0) - cx, (y - Y0) - cy
                if dx * dx + dy * dy > rr * rr:
                    continue
                bg = img[y][x]
                a = alpha
                img[y][x] = (int(FG[0] * a + bg[0] * (1 - a)),
                             int(FG[1] * a + bg[1] * (1 - a)),
                             int(FG[2] * a + bg[2] * (1 - a)),
                             255)

    # 灵动岛（胶囊）
    fill_round(0.30, 0.20, 0.70, 0.355, 0.0775, 0.96)
    # 辅助条：三个小圆点
    for cx, r in ((0.36, 0.055), (0.50, 0.055), (0.64, 0.055)):
        fill_round(cx - r, 0.60, cx + r, 0.60 + 2 * r, r, 0.96)

    # 降采样
    out = _px(size, size)
    for y in range(size):
        for x in range(size):
            rs = gs = bs = as_ = 0
            for dy in range(SS):
                for dx in range(SS):
                    p = img[y * SS + dy][x * SS + dx]
                    rs += p[0]; gs += p[1]; bs += p[2]; as_ += p[3]
            n = SS * SS
            out[y][x] = (rs // n, gs // n, bs // n, as_ // n)
    return out


def write_png(path, w, h, rows):
    raw = b"".join(b"\x00" + bytes(v for p in row for v in p) for row in rows)

    def chunk(t, d):
        c = t + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    hdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    data = (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", hdr)
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(data)


def main():
    for name, size in (("icon.png", 58), ("icon@2x.png", 116), ("icon@3x.png", 174)):
        rows = render(size)
        p = os.path.join(HERE, name)
        write_png(p, size, size, rows)
        print("生成 %s (%dx%d, %d 字节)" % (name, size, size, os.path.getsize(p)))


if __name__ == "__main__":
    main()
