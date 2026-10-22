#!/usr/bin/env python3
"""Visual tests: render zsh's output with a terminal emulator and check, after
every key, that the screen shows exactly what zshelix's model says it
should: the buffer's text, the selection highlights (and nothing stale), the
cursor position, and no leftover popups or messages.

Requires pyte (`pip install pyte`).

    tests/visual.py -n 100           random key sequences
    tests/visual.py --keys 'C l l'   specific commands (space-separated; the
                                     screen is checked after each one)
    tests/visual.py --plugins DIR    also load zsh-syntax-highlighting and
                                     zsh-autosuggestions from DIR
    ZHM_TEST_DEBUG=PATH ...           also write region_highlight to PATH.N
"""

import argparse
import concurrent.futures
import os
import random
import shutil
import sys
import tempfile

import pyte
from pyte.graphics import FG_BG_256

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fuzz  # noqa: E402
import harness  # noqa: E402

ROWS, COLS = 30, 100

# Writes the model's state after each key: the buffer, CURSOR, the mode and
# the selection ranges (primary first).
STATE = r"""
function _zhm_test_state() {
    emulate -L zsh
    local -a ranges
    local -i i
    for (( i = 1; i <= ${#_zhm_sa}; i++ )); do
        ranges+=( "${_zhm_sa[i]} ${_zhm_sh[i]}" )
    done
    local -a msg=()
    [[ -n $_zhm_msg ]] && msg=( "${(@f)_zhm_msg}" )
    {
        print -r -- "$_zhm_mode $CURSOR $_zhm_pi ${#_zhm_sa} ${#msg}"
        (( ${#msg} )) && print -rl -- "${msg[@]}"
        print -rl -- "${ranges[@]}"
        print -rn -- "$BUFFER"
    } >| $ZHM_TEST_STATE.$(( ++_zhm_test_states ))
    [[ -n $ZHM_TEST_DEBUG ]] && print -rl -- "${region_highlight[@]}" "--- $(zstyle -L zle-line-pre-redraw)" >| $ZHM_TEST_DEBUG.$_zhm_test_states
}
typeset -gi _zhm_test_states=0
zle -N _zhm_test_state
for km in zhm-normal zhm-select viins; do
    bindkey -M $km '\e[23~' _zhm_test_state
done
"""

F11 = b"\x1b[23~"


def color(n):
    return FG_BG_256[n]


SELECTION = color(238)
PRIMARY = color(240)
CURSOR_BG = color(250)


def char_width(ch):
    return max(1, pyte.screens.wcwidth(ch))


def layout(text, start_col):
    """Screen positions (row offset, col) of each character of the buffer when
    zsh draws it after a prompt ending at start_col."""
    positions = []
    row, col = 0, start_col
    for ch in text:
        if ch == "\n":
            positions.append((row, col))
            row, col = row + 1, 0
            continue
        if ch == "\t":
            # zsh draws a tab as spaces up to the next multiple of 8.
            w = (col // 8 + 1) * 8 - col
        elif ord(ch) < 32 or ord(ch) == 127:
            # Control characters are drawn as ^X.
            w = 2
        else:
            w = char_width(ch)
        if col + w > COLS and ch != "\t":
            row, col = row + 1, 0
        positions.append((row, col))
        col += w
        if col >= COLS:
            row, col = row + 1, 0
    return positions, (row, col)


def check(screen, state, prompt_row):
    """Compare the screen with the model state. Returns a list of problems."""
    header, *rest = state.split("\n")
    mode, cursor, primary, count, msg_lines = header.split()
    cursor, primary, count, msg_lines = int(cursor), int(primary), int(count), int(msg_lines)
    message, rest = rest[:msg_lines], rest[msg_lines:]
    ranges = [tuple(map(int, line.split())) for line in rest[:count]]
    buffer = "\n".join(rest[count:])
    problems = []

    positions, end = layout(buffer, 2)
    n = len(buffer)

    # Expected background for each character.
    want_bg = ["default"] * n
    for i, (a, h) in enumerate(ranges, 1):
        lo, hi = min(a, h), min(max(a, h), n)
        for p in range(lo, hi):
            want_bg[p] = PRIMARY if i == primary else SELECTION
    for i, (a, h) in enumerate(ranges, 1):
        if i == primary:
            continue
        c = h - 1 if h > a else h
        if c >= n and n > 0:
            c = n - 1
        if 0 <= c < n:
            want_bg[c] = CURSOR_BG

    for p, ch in enumerate(buffer):
        if ch == "\n":
            continue
        row, col = positions[p]
        cell = screen.buffer[prompt_row + row][col]
        shown = " " if ch == "\t" else ("^" if ord(ch) < 32 or ord(ch) == 127 else ch)
        if cell.data != shown:
            problems.append(f"char {p}: screen shows {cell.data!r}, buffer has {ch!r}")
        if cell.bg != want_bg[p]:
            problems.append(f"char {p} ({ch!r}): background {cell.bg}, expected {want_bg[p]}")

    # Nothing after the end of the buffer on its last row, and no highlights
    # anywhere else on the buffer's rows.
    last_row, last_col = end
    for col in range(last_col, COLS):
        cell = screen.buffer[prompt_row + last_row][col]
        if cell.data != " " or cell.bg != "default":
            problems.append(f"leftover {cell.data!r} (bg {cell.bg}) after the buffer at column {col}")
            break

    # Below the buffer there's only the current message, if any: popups and
    # old messages must be gone. zsh escapes control characters in messages
    # and wraps long ones, which isn't modelled, so those aren't checked.
    check_message = not any(len(m) >= COLS or any(ord(c) < 32 for c in m) for m in message)
    for i, row in enumerate(range(prompt_row + last_row + 1, ROWS) if check_message else []):
        line = "".join(screen.buffer[row][c].data for c in range(COLS)).rstrip()
        want = message[i] if i < len(message) else ""
        if line != want:
            problems.append(f"below the buffer: {line!r}, expected {want!r}")
            break

    # The terminal cursor is on the primary cursor.
    if cursor <= n:
        if cursor < n:
            want = positions[cursor]
        else:
            want = end
        got = (screen.cursor.y - prompt_row, screen.cursor.x)
        if got != want:
            problems.append(f"terminal cursor at {got}, expected {want} (CURSOR={cursor})")
    return problems


def run(text, tokens, plugins=None):
    d = tempfile.mkdtemp(prefix="zhm-visual-")
    try:
        inp = os.path.join(d, "in.txt")
        with open(inp, "w") as f:
            f.write(text)
        state_path = os.path.join(d, "state")
        rc = harness.ZSHRC % {
            "input": inp,
            "output": os.path.join(d, "out"),
            "plugin": os.path.join(harness.ROOT, "zshelix.plugin.zsh"),
        }
        if plugins:
            rc += f"\nsource {plugins}/zsh-autosuggestions/zsh-autosuggestions.zsh"
            rc += f"\nsource {plugins}/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh\n"
        rc += STATE
        with open(os.path.join(d, ".zshrc"), "w") as f:
            f.write(rc)
        env = dict(os.environ, ZDOTDIR=d, TERM="xterm-256color", HOME=d, ZHM_TEST_STATE=state_path,
                   ZHM_INDENT_WIDTH="0", ZHM_TAB_WIDTH="4")
        for k in list(env):
            if k.startswith("ZHM_") and k not in ("ZHM_TEST_STATE", "ZHM_TEST_DEBUG", "ZHM_INDENT_WIDTH", "ZHM_TAB_WIDTH"):
                env.pop(k)
        screen = pyte.Screen(COLS, ROWS)
        stream = pyte.ByteStream(screen)
        p = harness.Pty(["zsh", "-d", "-i"], env, cwd=d)
        fed = 0

        def feed():
            nonlocal fed
            stream.feed(p.output[fed:])
            fed = len(p.output)

        try:
            p.read(0.4)
            feed()
            problems = []
            states = 0
            keys_so_far = ""
            for token in tokens:
                harness.send_keys(p, harness.parse_keys(token), 0.03)
                keys_so_far += token
                states += 1
                os.write(p.fd, F11)
                path = f"{state_path}.{states}"
                if not harness.wait_for(path, p):
                    problems.append((keys_so_far, ["no state written"]))
                    break
                p.read_until_quiet(0.03)
                feed()
                with open(path) as f:
                    state = f.read()
                # The prompt is on the first row (the harness never runs a
                # command line).
                found = check(screen, state, 0)
                if found:
                    rows = ["".join(screen.buffer[r][c].data for c in range(COLS)).rstrip() for r in range(6)]
                    problems.append((keys_so_far, found + ["screen: " + repr(rows)]))
                    break
            return problems
        finally:
            p.close()
    finally:
        shutil.rmtree(d, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=50)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--keys")
    ap.add_argument("--text", default="hello world foo\nbar baz qux\n")
    ap.add_argument("--plugins")
    ap.add_argument("-j", "--jobs", type=int, default=8)
    args = ap.parse_args()

    if args.keys:
        cases = [(args.text.encode().decode("unicode_escape"), args.keys.split(" "))]
    else:
        seed = args.seed if args.seed is not None else random.randrange(1 << 30)
        print(f"seed {seed}")
        rng = random.Random(seed)
        cases = [fuzz.make_case(rng) for _ in range(args.n)]
        # Long lines, which zsh wraps.
        long_line = "the quick brown fox jumps over the lazy dog " * 5 + "\n"
        cases += [(long_line + "short\n", toks) for _, toks in (fuzz.make_case(rng) for _ in range(args.n // 4))]

    failures = 0
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        for (text, tokens), problems in zip(cases, pool.map(lambda c: run(*c, plugins=args.plugins), cases)):
            if not problems:
                continue
            failures += 1
            for keys, found in problems:
                print(f"FAIL {keys!r} on {text!r}")
                for line in found:
                    print(f"  {line}")
    print(f"{len(cases) - failures}/{len(cases)} rendered correctly")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
