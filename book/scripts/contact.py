#!/usr/bin/env python3
"""Make contact sheets (grids of page thumbnails) for visual QA of the book.

usage: contact.py OUTPREFIX PAGE_PNG... [--cols 4] [--per 8] [--width 1600]
"""
import argparse
import re

from PIL import Image, ImageDraw


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("prefix")
    ap.add_argument("pages", nargs="+")
    ap.add_argument("--cols", type=int, default=4)
    ap.add_argument("--per", type=int, default=8)
    ap.add_argument("--width", type=int, default=1800)
    a = ap.parse_args()

    def key(p: str) -> int:
        m = re.findall(r"(\d+)", p)
        return int(m[-1]) if m else 0

    pages = sorted(a.pages, key=key)
    for sheet, start in enumerate(range(0, len(pages), a.per)):
        chunk = pages[start : start + a.per]
        imgs = [Image.open(p).convert("RGB") for p in chunk]
        tw = a.width // a.cols
        th = int(imgs[0].height * tw / imgs[0].width)
        rows = (len(imgs) + a.cols - 1) // a.cols
        out = Image.new("RGB", (a.cols * tw, rows * (th + 18)), "white")
        d = ImageDraw.Draw(out)
        for i, (p, im) in enumerate(zip(chunk, imgs)):
            r, c = divmod(i, a.cols)
            out.paste(im.resize((tw - 6, th - 6)), (c * tw + 3, r * (th + 18) + 3))
            d.text((c * tw + 8, r * (th + 18) + th), f"p{key(p)}", fill="red")
        path = f"{a.prefix}-{sheet + 1}.png"
        out.save(path)
        print(path)


if __name__ == "__main__":
    main()
