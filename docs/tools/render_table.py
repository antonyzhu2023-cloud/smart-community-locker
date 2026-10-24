#!/usr/bin/env python3
"""Renders a report table as a PNG.

The report's tables are images rather than text because the word limit counts
every word in the body and the lecturer's own exemplars insert their tables the
same way. That means the table has to be rendered, and it has to look the same
as the nine others.

This script was reconstructed on 25 October after the first one was written
inside a throwaway sandbox and lost. Losing it cost an hour and risked a table
that did not match its neighbours, which is a small example of the same thing
section 3.2 says about the environment: a tool that is not in the repository
does not exist.

Usage:

    python3 render_table.py spec.json out.png

The spec is ``{"widths": [...], "rows": [[...], ...]}`` with the header as the
first row. Wrapping is measured in pixels against the real font rather than
counted in characters, because a character count clips any column holding
narrow letters.
"""

import json
import sys

from PIL import Image, ImageDraw, ImageFont

HEADER_BG = (68, 84, 106)
BORDER = (68, 84, 106)
GRID = (154, 160, 166)
ROW_BG = ((255, 255, 255), (242, 244, 247))
HEADER_FG = (255, 255, 255)
BODY_FG = (26, 26, 26)

PAD_X = 22
PAD_Y = 20
LINE_H = 42
FONT_SIZE = 30
BORDER_W = 2

REGULAR = "/usr/share/fonts/truetype/lato/Lato-Regular.ttf"
BOLD = "/usr/share/fonts/truetype/lato/Lato-Bold.ttf"


def wrap(text, font, width):
    """Breaks text to fit `width` pixels, measuring each candidate line."""
    lines = []
    for paragraph in text.split("\n"):
        words = paragraph.split()
        if not words:
            lines.append("")
            continue
        line = words[0]
        for word in words[1:]:
            candidate = f"{line} {word}"
            if font.getlength(candidate) <= width:
                line = candidate
            else:
                lines.append(line)
                line = word
        lines.append(line)
    return lines


def render(spec, out_path):
    widths = spec["widths"]
    rows = spec["rows"]
    total_w = sum(widths) + BORDER_W * 2

    regular = ImageFont.truetype(REGULAR, FONT_SIZE)
    bold = ImageFont.truetype(BOLD, FONT_SIZE)

    laid_out = []
    for index, row in enumerate(rows):
        font = bold if index == 0 else regular
        cells = [
            wrap(str(cell), font, widths[col] - PAD_X * 2)
            for col, cell in enumerate(row)
        ]
        height = max(len(cell) for cell in cells) * LINE_H + PAD_Y * 2
        laid_out.append((cells, height))

    total_h = sum(height for _, height in laid_out) + BORDER_W * 2
    image = Image.new("RGB", (total_w, total_h), BORDER)
    draw = ImageDraw.Draw(image)

    y = BORDER_W
    for index, (cells, height) in enumerate(laid_out):
        header = index == 0
        background = HEADER_BG if header else ROW_BG[(index - 1) % 2]
        draw.rectangle(
            [BORDER_W, y, total_w - BORDER_W - 1, y + height - 1], fill=background
        )

        x = BORDER_W
        for col, lines in enumerate(cells):
            if col:
                draw.line(
                    [(x, y), (x, y + height - 1)],
                    fill=GRID if not header else HEADER_BG,
                )
            text_y = y + PAD_Y
            for line in lines:
                draw.text(
                    (x + PAD_X, text_y),
                    line,
                    font=bold if header else regular,
                    fill=HEADER_FG if header else BODY_FG,
                )
                text_y += LINE_H
            x += widths[col]

        y += height
        if index and y < total_h - BORDER_W:
            draw.line([(BORDER_W, y), (total_w - BORDER_W - 1, y)], fill=GRID)

    image.save(out_path)
    print(f"{out_path}  {image.size[0]}x{image.size[1]}")


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as handle:
        render(json.load(handle), sys.argv[2])
