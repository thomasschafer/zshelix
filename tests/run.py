#!/usr/bin/env python3
"""Run zshelix's key tests.

Each case in tests/cases/*.txt is a key sequence and a starting text. The
expected result for every case comes from Helix itself and is recorded in
tests/expected.json, so the tests can run without Helix installed.

    tests/run.py                 run all cases against the recorded results
    tests/run.py -k PATTERN      only run cases whose keys contain PATTERN
    tests/run.py --record        (re)record expected results from Helix
                                 (only for cases without a recorded result,
                                 unless --force is given)
    tests/run.py --live          compare zsh against Helix directly

Case file format: blank lines and lines starting with `#` are ignored. A
line `ext: ...` sets the file extension Helix uses for the following cases
(default txt, i.e. no language), and a line `text: ...` sets the starting text for the following cases (with \\n,
\\t and \\\\ escapes; a trailing newline is added if missing). Every other
line is a key sequence in Helix macro notation, e.g. `w<A-;>x<esc>`.
"""

import argparse
import concurrent.futures
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness  # noqa: E402

TESTS = os.path.dirname(os.path.abspath(__file__))
EXPECTED = os.path.join(TESTS, "expected.json")
MARKERS = "«»¦‡"


def unescape(s):
    out = []
    i = 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            out.append({"n": "\n", "t": "\t", "\\": "\\"}.get(s[i + 1], "\\" + s[i + 1]))
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def load_cases():
    cases = []
    for path in sorted(glob.glob(os.path.join(TESTS, "cases", "*.txt"))):
        name = os.path.basename(path)[:-4]
        text = None
        ext = "txt"
        with open(path) as f:
            for lineno, line in enumerate(f, 1):
                line = line.rstrip("\n")
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                if line.startswith("ext: "):
                    ext = line[len("ext: ") :].strip()
                    continue
                if line.startswith("text: "):
                    text = unescape(line[len("text: ") :])
                    if not text.endswith("\n"):
                        text += "\n"
                    continue
                if text is None:
                    raise SystemExit(f"{path}:{lineno}: keys before any text")
                cases.append((name, text, line, ext))
    return cases


def case_key(case):
    _, text, keys, ext = case
    parts = [text, keys] if ext == "txt" else [text, keys, ext]
    return json.dumps(parts, ensure_ascii=False)


def canonical(marked):
    """Drop the final newline: zshelix always keeps the virtual newline that
    Helix documents usually end with, even when Helix's text loses it."""
    i = len(marked)
    while i > 0 and marked[i - 1] in MARKERS:
        i -= 1
    if i > 0 and marked[i - 1] == "\n":
        return marked[: i - 1] + marked[i:]
    return marked


def show(marked):
    return marked.replace("\n", "⏎\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-k", dest="pattern")
    ap.add_argument("--record", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--live", action="store_true")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4)
    args = ap.parse_args()

    cases = load_cases()
    if args.pattern:
        cases = [c for c in cases if args.pattern in c[2] or args.pattern in c[0]]

    expected = {}
    if os.path.exists(EXPECTED):
        with open(EXPECTED) as f:
            expected = json.load(f)

    if args.record or args.live:
        todo = [c for c in cases if args.force or args.live or case_key(c) not in expected]

        def helix(c):
            # Helix occasionally misses the deadline under heavy load, so
            # retry before giving up.
            for attempt in range(3):
                try:
                    return c, harness.run_helix(c[1], c[2], ext=c[3])
                except Exception as e:  # noqa: BLE001
                    error = e
            return c, error

        errors = 0
        with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
            for c, result in pool.map(helix, todo):
                if isinstance(result, Exception):
                    errors += 1
                    print(f"helix failed: {c[0]}: {c[2]!r}: {result}")
                else:
                    expected[case_key(c)] = list(result)
        if args.record:
            # Keep only results for cases that still exist.
            live = {case_key(c) for c in load_cases()}
            expected = {k: v for k, v in sorted(expected.items()) if k in live}
            with open(EXPECTED, "w") as f:
                json.dump(expected, f, ensure_ascii=False, indent=0, sort_keys=True)
                f.write("\n")
            print(f"recorded {len(todo) - errors} cases")
            return 1 if errors else 0

    missing = [c for c in cases if case_key(c) not in expected]
    if missing:
        for name, text, keys, _ in missing:
            print(f"no recorded result: {name}: {keys!r} on {text!r}")
        print("run tests/run.py --record (requires hx) to record them")
        return 1

    failures = 0
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        def zsh(c):
            try:
                return c, harness.run_zsh(c[1], c[2], ext=c[3])
            except Exception as e:  # noqa: BLE001
                return c, ("ERROR", str(e))

        for c, (mode, marked) in pool.map(zsh, cases):
            name, text, keys, _ = c
            want_mode, want = expected[case_key(c)]
            if mode == want_mode and canonical(marked) == canonical(want):
                continue
            failures += 1
            print(f"FAIL {name}: {keys!r} on {text!r}")
            print(f"  helix ({want_mode}):\n    " + show(want).replace("\n", "\n    "))
            print(f"  zsh   ({mode}):\n    " + show(marked).replace("\n", "\n    "))
    print(f"{len(cases) - failures}/{len(cases)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
