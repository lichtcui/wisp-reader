#!/usr/bin/env python3
"""v2 图标（方案 B 定稿）导出与落地。

链路：
  source/background.svg + source/foreground.svg
    -> rsvg-convert: dist/background.png, dist/foreground.png (1024)
    -> 合成:          dist/icon-1024.png (方形不透明，供人工核对)
    -> 缩放 + 圆角:   dist/startIcon-512.png (RGBA，启动页图标)

  --apply 时落地：
    AppScope/resources/base/media/{background,foreground}.png
    entry/src/main/resources/base/media/{background,foreground}.png
    entry/src/main/resources/base/media/startIcon.png

依赖：rsvg-convert；PNG 解码/合成复用 design/icon/src/iconlib.py（纯标准库）。
"""
import argparse
import hashlib
import pathlib
import shutil
import subprocess
import sys

SRC = pathlib.Path(__file__).resolve().parent
PKG = SRC.parent
ROOT = SRC.parents[2]
SOURCE = PKG / "source"
DIST = PKG / "dist"
ICONLIB = ROOT / "design/icon/src"

sys.path.insert(0, str(ICONLIB))
import iconlib  # noqa: E402  (path depends on the line above)

LAYER_DIRS = (
    ROOT / "AppScope/resources/base/media",
    ROOT / "entry/src/main/resources/base/media",
)
START_TARGET = ROOT / "entry/src/main/resources/base/media/startIcon.png"
SIZE = 1024
START_SIZE = 512


def render():
    DIST.mkdir(parents=True, exist_ok=True)
    for name in ("background", "foreground"):
        out = DIST / f"{name}.png"
        subprocess.run(
            ["rsvg-convert", "-w", str(SIZE), "-h", str(SIZE),
             "-o", str(out), str(SOURCE / f"{name}.svg")],
            check=True,
        )
        print(f"  {(DIST / name).relative_to(ROOT)}.png")

    bg = iconlib.read_png(DIST / "background.png")
    fg = iconlib.read_png(DIST / "foreground.png")
    flat = iconlib.flatten(fg, bg)
    iconlib.write_rgb(DIST / "icon-1024.png", SIZE, SIZE, flat)
    print(f"  {(DIST / 'icon-1024.png').relative_to(ROOT)}")

    scaled = iconlib.resize((SIZE, SIZE, 3, flat), START_SIZE)[3]
    rounded = iconlib.squircle(scaled, START_SIZE)[3]
    iconlib.write_rgba(DIST / "startIcon-512.png", START_SIZE, START_SIZE, rounded)
    print(f"  {(DIST / 'startIcon-512.png').relative_to(ROOT)}")


def apply():
    for d in LAYER_DIRS:
        for name in ("background.png", "foreground.png"):
            shutil.copyfile(DIST / name, d / name)
            print(f"  -> {(d / name).relative_to(ROOT)}")
    shutil.copyfile(DIST / "startIcon-512.png", START_TARGET)
    sha = hashlib.sha256(START_TARGET.read_bytes()).hexdigest()[:16]
    print(f"  -> {START_TARGET.relative_to(ROOT)}  sha256:{sha}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true", help="同步覆盖工程资源")
    args = parser.parse_args()
    print("渲染分层图标：")
    render()
    if args.apply:
        print("落地到工程资源：")
        apply()


if __name__ == "__main__":
    main()
