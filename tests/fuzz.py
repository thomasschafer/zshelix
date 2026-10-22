#!/usr/bin/env python3
"""Differential fuzzing: random key sequences run in Helix and in zsh.

    tests/fuzz.py -n 200          run 200 random cases
    tests/fuzz.py --seed 5        reproducible run

Mismatches are printed and appended to tests/fuzz-failures.txt (which isn't
tracked); once triaged, move them into tests/cases and record them with
`tests/run.py --record`.
"""

import argparse
import concurrent.futures
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness  # noqa: E402
from run import show  # noqa: E402

TEXTS = [
    "git commit -m \"fix: thing\" && git push origin main\n",
    "for f in *.txt; do\n  echo \"$f\"\ndone\n",
    "a\n",
    "\n",
    "  \n",
    "word\n\n\nword\n",
    "hello world foo\nbar baz qux\n",
    "foo(bar, baz) [x] {y}\n  indented line\n\nlast line here\n",
    "a b c\nd e f\ng h i\n",
    "one\n\ntwo three\n\n\nfour\n",
    "fn main() {\n    let x = (1 + 2) * 3;\n}\n",
    'echo "hello world" | grep -o \'o\' && ls -la\n',
    "x\n",
    "  leading and trailing  \n\tTabbed\tline\n",
    "CamelCase snake_case kebab-case 123 0x1f\n",
    "héllo wörld\n日本語 テキスト\n",
    "((a) (b [c] {d}))\n",
    "short\nmuch longer line of text\nmid line\n",
]

CHARS = list("aeo ()[]\"'x")

# Tokens that never leave Helix waiting for input.
SIMPLE = (
    "h j k l w b e W B E x X ; , % C _ & J ~ ` > < u U d y p P R ( ) n N * "
    "gh gl gs gg ge gk gj g. <A-;> <A-x> <A-C> <A-s> <A-,> <A-(> <A-)> <A-J> "
    "<A-`> <A-d> <A-:> <A-_> <A-minus> <A-u> <A-U> <A-*> miw maw miW maW mip "
    "map mim mam mm ]p [p ]<space> [<space> v v v <esc> 2 3 <C-a> <C-x> "
    "<A-.> <C-o> <C-i> <C-s>"
).split()


REGEXES = ["o", "a|e", "\\w+", "[a-z]+", "\\s", "^", "$", "x*", "\\b", "(", "b.", "l+"]


def token(rng):
    r = rng.random()
    if r < 0.08:
        cmd = rng.choice(["s", "S", "K", "<A-K>", "/", "?"])
        return cmd + rng.choice(REGEXES) + "<ret>"
    if r < 0.11:
        return rng.choice(['"a', '"b', '"_']) + rng.choice(["y", "p", "P", "R", "d", "c<esc>"])
    if r < 0.13:
        return rng.choice(["|tr a-z A-Z<ret>", "!echo x<ret>", "<A-!>echo y<ret>", "$grep o<ret>", ":sort<ret>"])
    if r < 0.15:
        return rng.choice(["Q", "q", "."])
    if r < 0.55:
        return rng.choice(SIMPLE)
    if r < 0.7:
        cmd = rng.choice(["f", "t", "F", "T", "r", "mi", "ma", "ms", "md", "]", "["])
        return cmd + rng.choice(CHARS)
    if r < 0.75:
        return "mr" + rng.choice("()[]\"'m") + rng.choice("([{\"'") + "<esc>"
    insert = rng.choice(["i", "a", "I", "A", "o", "O", "c", "<A-c>"])
    typed = "".join(
        rng.choice(["x", "y", " ", "(", '"', "<backspace>", "<C-w>", "<C-j>", "<del>", "<C-k>", "<C-u>",
                    "<A-d>", "<left>", "<right>", "<up>", "<down>", "<home>", "<end>", ")", "[", "'", "<S-tab>"])
        for _ in range(rng.randint(0, 4))
    )
    return insert + typed + "<esc>"


def make_case(rng):
    text = rng.choice(TEXTS)
    tokens = [token(rng) for _ in range(rng.randint(2, 7))]
    return text, tokens


def split_keys(keys):
    """Split keys into a list of tokens, keeping <...> names together."""
    out = []
    i = 0
    while i < len(keys):
        if keys[i] == "<" and ">" in keys[i + 1 :]:
            j = keys.index(">", i)
            out.append(keys[i : j + 1])
            i = j + 1
        else:
            out.append(keys[i])
            i += 1
    return out


def mismatch(text, keys):
    # Make sure nothing is left waiting for a key.
    keys += "<esc><esc>"
    try:
        want = harness.run_helix(text, keys)
    except Exception:  # noqa: BLE001
        return False
    try:
        got = harness.run_zsh(text, keys)
    except Exception as e:  # noqa: BLE001
        got = ("ERROR", str(e))
    return not (want[0] == got[0] and want[1] == got[1])


def minimize(text, tokens):
    """Greedily drop tokens while Helix and zsh still disagree. Tokens are
    whole commands (including any prompt input), so that removing part of a
    command can't turn prompt input into commands."""
    tokens = list(tokens)
    changed = True
    while changed:
        changed = False
        for size in (4, 2, 1):
            i = 0
            while i < len(tokens):
                candidate = tokens[:i] + tokens[i + size :]
                if candidate and mismatch(text, "".join(candidate)):
                    tokens = candidate
                    changed = True
                else:
                    i += 1
    return "".join(tokens)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=100)
    ap.add_argument("--minimize", action="store_true")
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("-j", "--jobs", type=int, default=8)
    args = ap.parse_args()
    seed = args.seed if args.seed is not None else random.randrange(1 << 30)
    rng = random.Random(seed)
    cases = [make_case(rng) for _ in range(args.n)]
    print(f"seed {seed}")

    def run(case):
        text, tokens = case
        keys = "".join(tokens) + "<esc><esc>"
        try:
            want = harness.run_helix(text, keys)
        except Exception as e:  # noqa: BLE001
            return case, None, str(e)
        try:
            got = harness.run_zsh(text, keys)
        except Exception as e:  # noqa: BLE001
            got = ("ERROR", str(e))
        return case, want, got

    failures = []
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        for (text, tokens), want, got in pool.map(run, cases):
            if want is None:
                continue
            if want[0] == got[0] and want[1] == got[1]:
                continue
            keys = "".join(tokens)
            failures.append((text, tokens))
            print(f"FAIL {keys!r} on {text!r}")
            print(f"  helix ({want[0]}):\n    " + show(want[1]).replace("\n", "\n    "))
            print(f"  zsh   ({got[0]}):\n    " + show(got[1]).replace("\n", "\n    "))
    if failures and args.minimize:
        with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
            minimal = list(pool.map(lambda f: (f[0], minimize(*f)), failures))
        print("minimised:")
        for text, tokens in minimal:
            print(f"  {''.join(tokens)!r} on {text!r}")
        failures = minimal
    if failures:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fuzz-failures.txt")
        with open(path, "a") as f:
            for text, tokens in failures:
                keys = "".join(tokens) + "<esc><esc>"
                escaped = text.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")
                f.write(f"text: {escaped}\n{keys}\n")
    print(f"{len(cases) - len(failures)}/{len(cases)} matched")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
