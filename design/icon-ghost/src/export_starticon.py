"""Export the launch (start window) icon from the current ghost layered icon.

`startWindowIcon` in `entry/src/main/module.json5` points at a flat, non-layered
PNG (`$media:startIcon`), so it does NOT follow the layered icon automatically:
regenerate it whenever `dist/foreground.png` / `dist/background.png` change,
otherwise the splash screen keeps showing the previous app icon.

Pipeline
    dist/foreground.png + dist/background.png
        -> flatten (foreground alpha over opaque background)
        -> resize to 512x512
        -> squircle mask (radius 22.5%, transparent corners)
        -> dist/startIcon-512.png
        -> entry/src/main/resources/base/media/startIcon.png   (with --apply)

Run:  python3 export_starticon.py [--apply]
"""

import argparse
import hashlib
import pathlib
import sys

SRC = pathlib.Path(__file__).resolve().parent
GHOST = SRC.parent
ROOT = SRC.parents[2]
DIST = GHOST / 'dist'
ICONLIB = ROOT / 'design/icon/src'

SIZE = 512
TARGET = ROOT / 'entry/src/main/resources/base/media/startIcon.png'

sys.path.insert(0, str(ICONLIB))

import iconlib  # noqa: E402  (path depends on the line above)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--apply', action='store_true', help='copy the start icon into entry resources')
    args = parser.parse_args()

    background = iconlib.read_png(DIST / 'background.png')
    foreground = iconlib.read_png(DIST / 'foreground.png')
    flat = iconlib.flatten(foreground, background)
    scaled = iconlib.resize((1024, 1024, 3, flat), SIZE)[3]
    rounded = iconlib.squircle(scaled, SIZE)

    dist_out = DIST / f'startIcon-{SIZE}.png'
    iconlib.write_rgba(dist_out, SIZE, SIZE, rounded[3])
    print(f'{dist_out.relative_to(ROOT)}')

    if args.apply:
        iconlib.write_rgba(TARGET, SIZE, SIZE, rounded[3])
        sha = hashlib.sha256(TARGET.read_bytes()).hexdigest()[:16]
        print(f'{TARGET.relative_to(ROOT)}  sha256:{sha}')


if __name__ == '__main__':
    main()