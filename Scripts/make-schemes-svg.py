#!/usr/bin/env python3
"""make-schemes-svg.py - the colour scheme overview of the README and the website (docs/site/schemes.svg).

One small tile per built-in scheme, drawn in the colours the editor really uses (after the legibility step): a heading with its marker,
a task with inline code and a link, and a quote with its band and bar. Vector text, so it stays sharp at any size and is readable at
a quarter of the space the screenshot contact sheets took.

    build.noindex/luftig-SelfTest.app/Contents/MacOS/luftig-SelfTest --selftest schemes-dump --out /tmp/schemes.jsonl
    python3 Scripts/make-schemes-svg.py /tmp/schemes.jsonl docs/site/schemes.svg

The default scheme follows the system: its light variant is shown (the window screenshots show both); "luftig-dark" is skipped.
"""
import json
import sys
from xml.sax.saxutils import escape

COLS, TILE_W, TILE_H, GAP_X, GAP_Y, LABEL_H = 4, 180, 92, 12, 10, 22
SANS = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
MONO_ADVANCE = 0.602 * 12          # one character of a 12 px monospaced font


def tile(s, x, y):
    t = []
    pad = 10
    t.append(f'<rect x="{x}" y="{y}" width="{TILE_W}" height="{TILE_H}" rx="8" fill="{s["bg"]}" stroke="#8080803a"/>')
    # 1. ## Heading
    t.append(f'<text x="{x + pad}" y="{y + 25}" font-family="{SANS}">'
             f'<tspan font-size="12" fill="{s["marker"]}">##</tspan>'
             f'<tspan font-size="15" font-weight="700" fill="{s["heading"]}"> Heading</tspan></text>')
    # 2. - [x] `code` and a link   (marker and code in the monospaced font, so the pill can be placed without measuring)
    y2 = y + 49
    code_x = x + pad + 6 * MONO_ADVANCE
    code_w = 6 * MONO_ADVANCE
    t.append(f'<rect x="{code_x - 2:.1f}" y="{y2 - 12}" width="{code_w + 4:.1f}" height="16" rx="3" fill="{s["pill"]}"/>')
    t.append(f'<text x="{x + pad}" y="{y2}" font-family="{MONO}" font-size="12">'
             f'<tspan fill="{s["accent"]}">- [x] </tspan><tspan fill="{s["code"]}">`code`</tspan></text>')
    t.append(f'<text x="{code_x + code_w + 4:.1f}" y="{y2}" font-family="{SANS}" font-size="12">'
             f'<tspan fill="{s["text"]}">and a </tspan><tspan fill="{s["link"]}" text-decoration="underline">link</tspan></text>')
    # 3. > a quote, on its band with the bar
    qy = y + 60
    t.append(f'<rect x="{x + 6}" y="{qy}" width="{TILE_W - 12}" height="22" rx="3" fill="{s["quote"]}"/>')
    t.append(f'<rect x="{x + 6}" y="{qy}" width="2.5" height="22" fill="{s["bar"]}"/>')
    t.append(f'<text x="{x + pad + 4}" y="{qy + 15}" font-family="{SANS}" font-size="12">'
             f'<tspan fill="{s["marker"]}">&gt; </tspan><tspan fill="{s["quoteText"]}">A quieter quote</tspan></text>')
    # the name, under the tile, in a grey that reads on a light and a dark page
    t.append(f'<text x="{x + 2}" y="{y + TILE_H + 16}" font-family="{SANS}" font-size="12" fill="#8a8a92">{escape(s["name"])}</text>')
    return "\n  ".join(t)


def main():
    src, out = sys.argv[1], sys.argv[2]
    schemes = [json.loads(line) for line in open(src) if line.strip()]
    schemes = [s for s in schemes if s["id"] != "luftig-dark"]
    rows = (len(schemes) + COLS - 1) // COLS
    width = COLS * TILE_W + (COLS - 1) * GAP_X
    height = rows * (TILE_H + LABEL_H) + (rows - 1) * GAP_Y
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" '
             f'aria-label="The {len(schemes)} colour schemes of luftig, each showing a heading, a task with inline code and a link, and a quote">']
    for i, s in enumerate(schemes):
        x = (i % COLS) * (TILE_W + GAP_X)
        y = (i // COLS) * (TILE_H + LABEL_H + GAP_Y)
        parts.append("  " + tile(s, x, y))
    parts.append("</svg>")
    with open(out, "w") as f:
        f.write("\n".join(parts) + "\n")
    print(f"wrote {out}: {len(schemes)} schemes, {width} x {height}")


if __name__ == "__main__":
    main()
