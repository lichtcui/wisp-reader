"""Render the Source Reader app icon sources into every required asset.

Pipeline
    background.svg + foreground.svg
        -> rsvg-convert (1024x1024)
        -> flattened icon-1024.png
        -> squircle-masked variants + size ladder in dist/
        -> AppScope / entry resources when --apply is given

Run:  python3 export.py [--apply] [--rsvg PATH]
"""

import argparse
import hashlib
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import iconlib

SRC = pathlib.Path(__file__).resolve().parent
ICON = SRC.parent
ROOT = SRC.parents[2]
DIST = ICON / 'dist'
SIZES = [1024, 512, 256, 192, 144, 96, 72, 48]
START_ICON_SIZE = 512

APP_TARGETS = {
    'background.png': (ROOT / 'AppScope/resources/base/media/background.png', 'rgb'),
    'foreground.png': (ROOT / 'AppScope/resources/base/media/foreground.png', 'rgba'),
    'startIcon.png': (ROOT / 'entry/src/main/resources/base/media/startIcon.png', 'start'),
}


def render(svg, out, rsvg):
    subprocess.run([rsvg, str(svg), '-o', str(out)], check=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()[:16]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--apply', action='store_true', help='copy assets into AppScope/entry resources')
    parser.add_argument('--rsvg', default='rsvg-convert', help='path to rsvg-convert')
    args = parser.parse_args()

    build = ICON / 'build'
    build.mkdir(exist_ok=True)
    DIST.mkdir(exist_ok=True)

    background_png = build / 'background-1024.png'
    foreground_png = build / 'foreground-1024.png'
    render(SRC / 'background.svg', background_png, args.rsvg)
    render(SRC / 'foreground.svg', foreground_png, args.rsvg)

    background = iconlib.read_png(background_png)
    foreground = iconlib.read_png(foreground_png)
    flat = iconlib.flatten(foreground, background)
    iconlib.write_rgb(DIST / 'icon-1024.png', 1024, 1024, flat)
    iconlib.write_rgb(DIST / 'background-1024.png', 1024, 1024, background[3])
    iconlib.write_rgba(DIST / 'foreground-1024.png', 1024, 1024, foreground[3])

    for size in SIZES:
        scaled = flat if size == 1024 else iconlib.resize((1024, 1024, 3, flat), size)[3]
        if size != 1024:
            iconlib.write_rgb(DIST / f'icon-{size}.png', size, size, scaled)
        rounded = iconlib.squircle(scaled, size)
        iconlib.write_rgba(DIST / f'icon-{size}-round.png', size, size, rounded[3])

    start = iconlib.squircle(
        iconlib.resize((1024, 1024, 3, flat), START_ICON_SIZE)[3], START_ICON_SIZE)
    iconlib.write_rgba(DIST / f'startIcon-{START_ICON_SIZE}.png', START_ICON_SIZE, START_ICON_SIZE, start[3])

    print(f'dist/ -> {len(SIZES) * 2 + 3} files')

    if args.apply:
        for name, (target, kind) in APP_TARGETS.items():
            target.parent.mkdir(parents=True, exist_ok=True)
            if kind == 'rgb':
                iconlib.write_rgb(target, 1024, 1024, background[3])
            elif kind == 'rgba':
                iconlib.write_rgba(target, 1024, 1024, foreground[3])
            else:
                iconlib.write_rgba(target, START_ICON_SIZE, START_ICON_SIZE, start[3])
            print(f'{target.relative_to(ROOT)}  sha256:{digest(target)}')


if __name__ == '__main__':
    main()