#!/usr/bin/env python3
"""Draw kobo/openshelf.png, the launcher icon KFMon watches and Nickel shows in
the library (same 1440x1920 as koreader.png). Grayscale, high contrast for e-ink.

Run from the repo root:  python3 tools/make-icon.py [--font path/to/font.ttf]
Needs Pillow. Default font: NotoSans-Bold from the emulator build in ../koreader
(the same face KOReader renders the UI with)."""
import argparse
import glob
import os
import sys

from PIL import Image, ImageDraw, ImageFont

W, H = 1440, 1920


def find_font():
    hits = glob.glob(os.path.join("..", "koreader", "koreader-emulator-*", "koreader", "fonts", "noto", "NotoSans-Bold.ttf"))
    hits += glob.glob("/System/Library/Fonts/Supplemental/Arial Bold.ttf")
    if not hits:
        sys.exit("no font found; pass --font")
    return hits[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--font")
    ap.add_argument("--out", default=os.path.join("kobo", "openshelf.png"))
    args = ap.parse_args()
    font_path = args.font or find_font()

    img = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(img)

    # Card border so the icon reads as a tile among covers.
    d.rounded_rectangle([36, 36, W - 36, H - 36], radius=64, outline=0, width=16)

    # Five books standing on a shelf. (x, width, height, fill)
    shelf_y = 1130
    books = [
        (230, 150, 600, 0),
        (400, 205, 690, 110),
        (625, 160, 540, 0),
        (805, 235, 735, 70),
        (1060, 165, 620, 0),
    ]
    for x, w, h, fill in books:
        top = shelf_y - h
        d.rounded_rectangle([x, top, x + w, shelf_y], radius=14, fill=fill, outline=0, width=8)
        # Two label bands across the spine, in the inverse tone.
        band = 255 if fill < 128 else 0
        for frac in (0.18, 0.72):
            y = top + int(h * frac)
            d.rectangle([x + 28, y, x + w - 28, y + 22], fill=band)
    # Shelf plank with a shadow line.
    d.rectangle([150, shelf_y, W - 150, shelf_y + 44], fill=0)
    d.rectangle([150, shelf_y + 58, W - 150, shelf_y + 70], fill=120)

    title = ImageFont.truetype(font_path, 200)
    text = "OpenShelf"
    tw = d.textlength(text, font=title)
    d.text(((W - tw) / 2, 1290), text, font=title, fill=0)

    sub = ImageFont.truetype(font_path, 64)
    for i, line in enumerate(("free & public-domain books", "straight to your Kobo")):
        lw = d.textlength(line, font=sub)
        d.text(((W - lw) / 2, 1560 + i * 92), line, font=sub, fill=70)

    img.save(args.out, optimize=True)
    print("wrote", args.out, os.path.getsize(args.out), "bytes")


if __name__ == "__main__":
    main()
