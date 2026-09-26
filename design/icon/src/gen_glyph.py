"""Extract the outline of a CJK glyph from a system font and emit an SVG path.

The glyph is normalised so that its ink bounding box is centred on the origin
and its longest side equals 1. Place it in an SVG with
    <path transform="translate(CX CY) scale(S)" d="..."/>

Usage:
    gen_glyph.py <font.ttc> <faceIndex> <char> <out.svgpath>

The committed foreground.svg contains the generated path inline, so this script
is only needed to regenerate the path from another font or glyph.
"""

import sys

from fontTools.misc.transform import Transform
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTCollection, TTFont


def load_font(path, face):
    try:
        return TTCollection(path, lazy=False).fonts[face]
    except Exception:
        return TTFont(path, lazy=False)


def main():
    font_path, face, char, out = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    font = load_font(font_path, face)
    glyph_name = font.getBestCmap()[ord(char)]

    glyph_set = font.getGlyphSet()
    glyph = glyph_set[glyph_name]

    bounds_pen = BoundsPen(glyph_set)
    glyph.draw(bounds_pen)
    x_min, y_min, x_max, y_max = bounds_pen.bounds
    width, height = x_max - x_min, y_max - y_min
    scale = 1.0 / max(width, height)

    transform = Transform(
        scale,
        0,
        0,
        -scale,
        -scale * (x_min + x_max) / 2.0,
        scale * (y_min + y_max) / 2.0,
    )
    path_pen = SVGPathPen(glyph_set, ntos=lambda v: f"{v:.4f}")
    glyph.draw(TransformPen(path_pen, transform))

    with open(out, "w") as handle:
        handle.write(path_pen.getCommands())
    print(f"{char} glyph={glyph_name} ink={width:.0f}x{height:.0f} units -> {out}")


if __name__ == "__main__":
    main()