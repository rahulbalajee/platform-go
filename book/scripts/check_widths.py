#!/usr/bin/env python3
"""Report code lines included in the book that are too wide for the page.

Scans book/chapters/*.typ for #src("path", region: "name") calls, extracts
the same regions the Typst template does, expands tabs to 4 columns, and
prints every line wider than --max columns. Exit status 1 if any are found,
so CI can enforce it.
"""
from __future__ import annotations

import argparse
import glob
import re
import sys

SRC = re.compile(r'#src\("([^"]+)"(?:,\s*region:\s*"([^"]+)")?(?:,\s*head:\s*(\d+))?')


def region_lines(path: str, region: str | None) -> list[tuple[int, str]]:
    lines = open(path, encoding="utf-8").read().split("\n")
    numbered = list(enumerate(lines, start=1))
    if region:
        start = next(i for i, (_, l) in enumerate(numbered) if f"START {region} OMIT" in l)
        end = next(i for i, (_, l) in enumerate(numbered) if f"END {region} OMIT" in l)
        numbered = numbered[start + 1 : end]
    return [(n, l) for n, l in numbered if "OMIT" not in l]


def fold_marker(line: str, width: int) -> list[str]:
    """Mirror of _fold-marker in book/template/book.typ."""
    w = lambda s: len(s.expandtabs(4))
    body = line.lstrip()
    if w(line) <= width or not body.startswith("// +"):
        return [line]
    indent = line[: len(line) - len(body)]
    tokens, cur = [], ""
    for ch in body:
        cur += ch
        if ch in ", ":
            tokens.append(cur)
            cur = ""
    if cur:
        tokens.append(cur)
    out, acc, cont = [], indent, indent + "//   ↪ "
    for t in tokens:
        if w(acc + t.rstrip()) > width and acc.strip() and acc != cont:
            out.append(acc.rstrip())
            acc = cont + t.lstrip()
        else:
            acc += t
    out.append(acc.rstrip())
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--max", type=int, default=86)
    a = ap.parse_args()
    bad = 0
    seen = set()
    sources = sorted(glob.glob("book/chapters/*.typ")) + sorted(
        glob.glob("book/appendix/**/*.typ", recursive=True))
    for chapter in sources:
        for m in SRC.finditer(open(chapter, encoding="utf-8").read()):
            key = (m.group(1), m.group(2), m.group(3))
            if key in seen:
                continue
            seen.add(key)
            lines = region_lines(m.group(1), m.group(2))
            if m.group(3):  # head: N shows only the first N lines
                lines = lines[: int(m.group(3))]
            for n, raw_line in lines:
                for line in fold_marker(raw_line, a.max):
                    width = len(line.expandtabs(4))
                    if width > a.max:
                        bad += 1
                        print(f"{m.group(1)}:{n}: {width} cols  {line.strip()[:70]}")
    print(f"{bad} line(s) wider than {a.max} columns", file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
