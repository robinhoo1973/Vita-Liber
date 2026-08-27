#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""App 图标背景优化：把 AI 图标的白色底替换为 Fluent 风格渐变背景。

方法：
  1. 边缘洪泛填充 —— 只替换「与外边界相连」的近似白背景，图标内容（含内部白色字形）
     因不与边界相连而完整保留；
  2. 背景填 Fluent 三段色相偏移对角渐变（亮蓝 → 主蓝 → 紫）+ 左上径向光晕
     + 斜向玻璃光带 + 底部弧形暗角；
  3. 背景/内容交界做羽化（高斯模糊 mask 混合），内容底部叠加柔和投影使其浮在渐变上。

用法：python3 design/tools/appicon_fluent_bg.py
输出：直接改写 design/brand/app-icon.png（位图母版）；随后重跑 generate_assets.py 同步。
"""

import math
import sys
from collections import deque
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
MASTER = ROOT / "design/brand/app-icon.png"

# Fluent 三段色相偏移对角渐变（左上亮 → 右下加深且色相偏移到紫）
GRAD = [
    (0.00, (63, 161, 242)),   # #3FA1F2 亮蓝
    (0.55, (37, 102, 214)),   # #2566D6 主蓝（brand/primary 系）
    (1.00, (122, 59, 216)),   # #7A3BD8 紫
]
BG_WHITE = (249, 250, 250)
BG_TOL = 30


def grad_color(t: float) -> tuple:
    t = max(0.0, min(1.0, t))
    for i in range(len(GRAD) - 1):
        t0, c0 = GRAD[i]
        t1, c1 = GRAD[i + 1]
        if t0 <= t <= t1:
            k = (t - t0) / (t1 - t0)
            return tuple(round(c0[j] + (c1[j] - c0[j]) * k) for j in range(3))
    return GRAD[-1][1]


def is_bg(p: tuple) -> bool:
    return sum(abs(p[i] - BG_WHITE[i]) for i in range(3)) < BG_TOL


def flood_bg_mask(im: Image.Image) -> Image.Image:
    """从四条边界向内洪泛，标记与外边界相连的近似白像素为背景。"""
    w, h = im.size
    px = im.load()
    mask = Image.new("L", (w, h), 0)
    mp = mask.load()
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            if is_bg(px[x, y]) and mp[x, y] == 0:
                mp[x, y] = 255
                q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            if is_bg(px[x, y]) and mp[x, y] == 0:
                mp[x, y] = 255
                q.append((x, y))
    while q:
        x, y = q.popleft()
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and mp[nx, ny] == 0 and is_bg(px[nx, ny]):
                mp[nx, ny] = 255
                q.append((nx, ny))
    return mask


def build_gradient(w: int, h: int) -> Image.Image:
    g = Image.new("RGB", (w, h))
    gp = g.load()
    for y in range(h):
        for x in range(w):
            t = (x + y) / (w + h)          # 对角：左上 0 → 右下 1
            gp[x, y] = grad_color(t)
    return g


def add_effects(im: Image.Image) -> Image.Image:
    """左上径向光晕 + 斜向玻璃光带 + 底部弧形暗角。"""
    w, h = im.size
    glow = Image.new("L", (w, h), 0)
    gd = ImageDraw.Draw(glow)
    cx, cy, r = int(w * 0.28), int(h * 0.16), int(w * 0.85)
    for y in range(h):
        for x in range(w):
            d = math.hypot(x - cx, y - cy) / r
            if d < 1:
                glow.putpixel((x, y), int(255 * (1 - d) ** 2 * 0.30))
    white = Image.new("RGB", (w, h), (255, 255, 255))
    im = Image.composite(white, im, glow)

    # 斜向玻璃光带（-19°，白色 5% 渐隐）
    band = Image.new("L", (w, h), 0)
    bd = ImageDraw.Draw(band)
    for i in range(w):
        x = i
        y_top = int(h * 0.42 - i * 0.20)
        y_bot = y_top + int(h * 0.05)
        for y in range(max(0, y_top), min(h, y_bot)):
            band.putpixel((x, y), 13)
    band = band.filter(ImageFilter.GaussianBlur(30))
    white2 = Image.new("RGB", (w, h), (255, 255, 255))
    im = Image.composite(white2, im, band)

    # 底部弧形暗角（内阴影）
    vig = Image.new("L", (w, h), 0)
    vd = ImageDraw.Draw(vig)
    for y in range(int(h * 0.62), h):
        for x in range(w):
            k = (y - h * 0.62) / (h * 0.38)
            vd.point((x, y), fill=int(40 * k * k))
    vig = vig.filter(ImageFilter.GaussianBlur(40))
    dark = Image.new("RGB", (w, h), (6, 30, 80))
    im = Image.composite(dark, im, vig)

    return im


def process(im: Image.Image) -> Image.Image:
    """对单张图标做 Fluent 背景化，返回新图（不改输入）。"""
    w, h = im.size
    mask = flood_bg_mask(im)
    soft = mask.filter(ImageFilter.GaussianBlur(6))
    soft = soft.point(lambda v: min(v, 255))
    grad = build_gradient(w, h)
    grad = add_effects(grad)
    out = Image.composite(grad, im, soft)
    content = Image.composite(im, Image.new("RGB", (w, h), (0, 0, 0)), mask)
    shadow = Image.new("L", (w, h), 0)
    shd = ImageDraw.Draw(shadow)
    for y in range(int(h * 0.30), h):
        for x in range(w):
            k = (y - h * 0.30) / (h * 0.70)
            shd.point((x, y), fill=int(90 * k * k))
    shd_blur = shadow.filter(ImageFilter.GaussianBlur(28))
    shdark = Image.new("RGB", (w, h), (5, 20, 60))
    shadow_layer = Image.composite(shdark, out, shd_blur)
    out = Image.composite(shadow_layer, out, mask.point(lambda v: 255 if v > 0 else 0))
    return out


def main() -> None:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", default=str(MASTER))
    ap.add_argument("--out", dest="dst", default=str(MASTER))
    args = ap.parse_args()
    src, dst = Path(args.src), Path(args.dst)
    if not src.exists():
        sys.exit(f"missing {src}")
    im = Image.open(src).convert("RGB")
    if im.size != (1024, 1024):
        im = im.resize((1024, 1024), Image.LANCZOS)
    out = process(im)
    out.save(dst)
    print(f"[ok] {dst} 背景已替换为 Fluent 渐变（洪泛填充 + 羽化 + 光晕/玻璃光带/暗角/投影）")


if __name__ == "__main__":
    main()
