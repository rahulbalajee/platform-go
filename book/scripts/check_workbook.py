#!/usr/bin/env python3
"""Verify the book's build track (see book/AUTHORING.md, "The build track").

Layout checked, per chapter NN:
  workbook/chNN/stepK/          one Go module per build step (K = 1..N)
  workbook/chNN/exercises/exK/  acceptance tests only; overlaid on the base step
      BASE (optional file)      name of the base step dir; default: the last step
  solutions/chNN/exK/           full module: base step + solution + same tests
  workbook/chNN/GENERATED       (optional) glob patterns, relative to a step dir,
                                of files produced by commands the book prints
                                (kubebuilder init, controller-gen, stringer);
                                exempt from coverage
  workbook/chNN/SYNC (optional) "workbook/... = pkg/..." file pairs and
                                "@import old = new" rewrites; the final step must
                                match the production code it was promoted to

Checks:
  coverage   every new or changed line in stepK (vs stepK-1) is printed by some
             #src("workbook/chNN/stepK/...") region in book/chapters, so a
             reader typing from the PDF alone can reach every step
  modules    gofmt, go vet and go test pass in every step and solution module
  exercises  acceptance tests FAIL on the base step and the solution carries
             byte-identical copies of them (solutions pass via `modules`)
  sync       final-step files equal their production counterparts after
             dropping OMIT markers and rewriting import paths

Usage: check_workbook.py [--chapter 04] [--only coverage,sync] [--race]
Exit status 1 if any check fails.
"""
from __future__ import annotations

import argparse
import difflib
import filecmp
import fnmatch
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

SRC = re.compile(r'#src\(\s*"([^"]+)"(?:\s*,\s*region:\s*"([^"]+)")?')
SKIP_COVERAGE = ("go.sum", "go.mod")
failures: list[str] = []


def fail(msg: str) -> None:
    failures.append(msg)
    print("FAIL", msg)


def step_dirs(root: str, ch: str) -> list[str]:
    dirs = glob.glob(os.path.join(root, "workbook", f"ch{ch}", "step*"))
    nums = {}
    for d in dirs:
        m = re.search(r"step(\d+)$", d)
        if m and os.path.isdir(d):
            nums[d] = int(m.group(1))
    return sorted(nums, key=nums.__getitem__)


def files_in(d: str) -> list[str]:
    out = []
    for dp, _, fns in os.walk(d):
        for fn in fns:
            out.append(os.path.relpath(os.path.join(dp, fn), d))
    return sorted(out)


def content_lines(path: str) -> list[tuple[int, str]]:
    """(1-based line number, text) for every line that is not an OMIT marker."""
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().split("\n")
    return [(i + 1, l) for i, l in enumerate(lines) if "OMIT" not in l]


def shown_lines(root: str) -> dict[str, set[int]]:
    """Map repo-relative file -> set of 1-based line numbers printed by #src."""
    shown: dict[str, set[int]] = {}
    for chap in glob.glob(os.path.join(root, "book", "chapters", "*.typ")):
        text = open(chap, encoding="utf-8").read()
        for path, region in SRC.findall(text):
            full = os.path.join(root, path)
            if not os.path.isfile(full):
                continue
            lines = open(full, encoding="utf-8", errors="replace").read().split("\n")
            if region:
                try:
                    s = next(i for i, l in enumerate(lines) if f"START {region} OMIT" in l)
                    e = next(i for i, l in enumerate(lines) if f"END {region} OMIT" in l)
                except StopIteration:
                    fail(f"{chap}: region {region!r} not found in {path}")
                    continue
                rng = range(s + 2, e + 1)  # 1-based lines strictly between markers
            else:
                rng = range(1, len(lines) + 1)
            shown.setdefault(path, set()).update(n for n in rng if "OMIT" not in lines[n - 1])
    return shown


DECL = re.compile(r"^(func|type|var|const|import|package)\b")


def describe_ranges(path: str, nums: list[int]) -> list[str]:
    """Group line numbers into ranges, each with its enclosing declaration."""
    lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    ranges, start, prev = [], None, None
    for n in sorted(nums):
        if start is None:
            start = prev = n
        elif n == prev + 1:
            prev = n
        else:
            ranges.append((start, prev))
            start = prev = n
    if start is not None:
        ranges.append((start, prev))
    out = []
    for a, b in ranges:
        decl = next((lines[i].strip() for i in range(a - 1, -1, -1) if DECL.match(lines[i])), "")
        span = f"{a}" if a == b else f"{a}-{b}"
        out.append(f"lines {span}" + (f" (in `{decl[:60]}`)" if decl else ""))
    return out


def generated_patterns(root: str, ch: str) -> list[str]:
    p = os.path.join(root, "workbook", f"ch{ch}", "GENERATED")
    if not os.path.isfile(p):
        return []
    pats = []
    for line in open(p, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if line:
            pats.append(line)
    return pats


def check_coverage(root: str, ch: str, shown: dict[str, set[int]]) -> None:
    prev = None
    gen = generated_patterns(root, ch)
    for d in step_dirs(root, ch):
        for rel in files_in(d):
            if os.path.basename(rel) in SKIP_COVERAGE or rel.endswith(".golden"):
                continue
            if any(fnmatch.fnmatch(rel, g) for g in gen):
                continue
            cur_path = os.path.join(d, rel)
            try:
                cur = content_lines(cur_path)
            except UnicodeDecodeError:
                continue
            old = []
            if prev and os.path.isfile(os.path.join(prev, rel)):
                old = content_lines(os.path.join(prev, rel))
            sm = difflib.SequenceMatcher(a=[t for _, t in old], b=[t for _, t in cur], autojunk=False)
            changed = []
            for op, _, _, j1, j2 in sm.get_opcodes():
                if op in ("replace", "insert"):
                    changed += [cur[j] for j in range(j1, j2)]
            changed = [(n, t) for n, t in changed if t.strip()]
            if not changed:
                continue
            key = os.path.relpath(cur_path, root)
            missing = [n for n, _ in changed if n not in shown.get(key, set())]
            if missing:
                fail(f"coverage: {key}: {len(missing)} new/changed line(s) never printed: "
                     + "; ".join(describe_ranges(cur_path, missing)))
        prev = d


def run(cmd: list[str], cwd: str) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def gofmt() -> str:
    goroot = subprocess.run(["go", "env", "GOROOT"], capture_output=True, text=True).stdout.strip()
    return os.path.join(goroot, "bin", "gofmt")


def check_modules(root: str, ch: str, race: bool) -> None:
    mods = step_dirs(root, ch) + sorted(glob.glob(os.path.join(root, "solutions", f"ch{ch}", "ex*")))
    fmt = gofmt()
    for m in mods:
        rel = os.path.relpath(m, root)
        if not os.path.isfile(os.path.join(m, "go.mod")):
            fail(f"modules: {rel} has no go.mod")
            continue
        r = run([fmt, "-l", "."], m)
        if r.stdout.strip():
            fail(f"modules: {rel}: gofmt needed: {r.stdout.split()}")
        for cmd in (["go", "vet", "./..."],
                    ["go", "test", "-count=1"] + (["-race"] if race else []) + ["./..."]):
            r = run(cmd, m)
            if r.returncode != 0:
                fail(f"modules: {rel}: `{' '.join(cmd)}` failed:\n{(r.stdout + r.stderr)[-1500:]}")
        print("ok  ", rel)


def check_exercises(root: str, ch: str) -> None:
    steps = step_dirs(root, ch)
    for ex in sorted(glob.glob(os.path.join(root, "workbook", f"ch{ch}", "exercises", "ex*"))):
        name = os.path.basename(ex)
        base_name = os.path.basename(steps[-1]) if steps else None
        if os.path.isfile(os.path.join(ex, "BASE")):
            base_name = open(os.path.join(ex, "BASE")).read().strip()
        base = os.path.join(root, "workbook", f"ch{ch}", base_name or "")
        if not base_name or not os.path.isdir(base):
            fail(f"exercises: {name}: base step {base_name!r} not found")
            continue
        tests = [f for f in files_in(ex) if f != "BASE"]
        sol = os.path.join(root, "solutions", f"ch{ch}", name)
        for t in tests:
            if not os.path.isfile(os.path.join(sol, t)):
                fail(f"exercises: {name}: solution lacks acceptance file {t}")
            elif not filecmp.cmp(os.path.join(ex, t), os.path.join(sol, t), shallow=False):
                fail(f"exercises: {name}: {t} differs between workbook and solution")
        with tempfile.TemporaryDirectory() as tmp:
            work = os.path.join(tmp, "m")
            shutil.copytree(base, work)
            for t in tests:
                os.makedirs(os.path.dirname(os.path.join(work, t)), exist_ok=True)
                shutil.copy(os.path.join(ex, t), os.path.join(work, t))
            r = run(["go", "test", "-count=1", "./..."], work)
            if r.returncode == 0:
                fail(f"exercises: {name}: acceptance tests already pass on {base_name}; "
                     "they do not test the exercise")
            else:
                print("ok  ", f"workbook/ch{ch}/exercises/{name} fails on {base_name} as intended")


def check_sync(root: str, ch: str) -> None:
    sync = os.path.join(root, "workbook", f"ch{ch}", "SYNC")
    if not os.path.isfile(sync):
        return
    rewrites, pairs = [], []
    for line in open(sync, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("@import"):
            old, new = (x.strip() for x in line[len("@import"):].split("="))
            rewrites.append((old, new))
        else:
            a, b = (x.strip() for x in line.split("="))
            pairs.append((a, b))

    def norm(path: str) -> list[str]:
        text = "\n".join(t for _, t in content_lines(os.path.join(root, path)))
        for old, new in rewrites:
            text = text.replace(f'"{old}', f'"{new}')
        return [l.rstrip() for l in text.split("\n") if l.strip()]

    for a, b in pairs:
        if not (os.path.isfile(os.path.join(root, a)) and os.path.isfile(os.path.join(root, b))):
            fail(f"sync: missing file in pair {a} = {b}")
            continue
        na, nb = norm(a), norm(b)
        if na != nb:
            diff = list(difflib.unified_diff(nb, na, b, a, lineterm="", n=1))
            fail(f"sync: {a} differs from {b}:\n" + "\n".join(diff[:30]))
        else:
            print("ok  ", f"{a} == {b}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--chapter", help="two-digit chapter number, e.g. 04 (default: all)")
    ap.add_argument("--only", default="coverage,modules,exercises,sync")
    ap.add_argument("--race", action="store_true", help="run module tests with -race")
    ap.add_argument("--root", default=os.path.join(os.path.dirname(__file__), "..", ".."))
    a = ap.parse_args()
    root = os.path.abspath(a.root)
    only = set(a.only.split(","))
    chapters = [a.chapter] if a.chapter else sorted(
        os.path.basename(d)[2:] for d in glob.glob(os.path.join(root, "workbook", "ch*")))
    shown = shown_lines(root) if "coverage" in only else {}
    for ch in chapters:
        print(f"== chapter {ch}")
        if "coverage" in only:
            check_coverage(root, ch, shown)
        if "modules" in only:
            check_modules(root, ch, a.race)
        if "exercises" in only:
            check_exercises(root, ch)
        if "sync" in only:
            check_sync(root, ch)
    print(f"{len(failures)} failure(s)", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
