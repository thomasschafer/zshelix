#!/usr/bin/env python3
"""Tests for zshelix's shell integration, where there's no Helix behaviour to
compare against: history, running commands, the clipboard, other widgets
changing the buffer, pasting, and so on.

    tests/shell.py
"""

import concurrent.futures
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness  # noqa: E402

HISTORY = 'ZHM_HISTORY_NAVIGATION=1; print -s "echo first"; print -s "echo second line"\n'

# A clipboard backed by a file, so tests don't touch the real clipboard.
CLIPBOARD = r"""
ZHM_CLIPBOARD_COPY=(zsh -c 'cat >| $ZHM_TEST_CLIP')
ZHM_CLIPBOARD_PASTE=(zsh -c 'cat $ZHM_TEST_CLIP 2>/dev/null')
"""

# A widget that changes the buffer behind zshelix's back, as completion and
# other plugins do.
EXTERNAL = r"""
function _test_external() { LBUFFER+="EXT"; }
zle -N _test_external
bindkey -M viins '^X^T' _test_external
bindkey -M zhm-normal '^X^T' _test_external
"""

PREEXEC = r"""
function preexec() { print -r -- "$1" >> $ZHM_TEST_RAN; }
"""

CASES = [
    # (name, text, keys, expected mode, expected text, rc_before, rc_after)
    ("history: k goes to the previous entry", "\n", "k", "NOR", "«e¦‡»cho second line\n", "", HISTORY),
    ("history: kk goes further back", "\n", "kk", "NOR", "«e¦‡»cho first\n", "", HISTORY),
    ("history: kkj comes back", "\n", "kkj", "NOR", "«e¦‡»cho second line\n", "", HISTORY),
    ("history: column is kept", "\n", "kkllllllj", "NOR", "echo s«e¦‡»cond line\n", "", HISTORY),
    ("history: up in insert mode", "\n", "i<up>", "INS", "echo second line«\n¦‡»", "", HISTORY),
    ("history: Ctrl-p in normal mode", "\n", "<C-p>", "NOR", "«e¦‡»cho second line\n", "", HISTORY),
    ("history: k moves within a multi-line buffer", "one\ntwo\n", "jk", "NOR", "«o¦‡»ne\ntwo\n", "", HISTORY),
    ("history: off when disabled", "\n", "k", "NOR", "«\n¦‡»", "", HISTORY + "ZHM_HISTORY_NAVIGATION=0"),
    ("clipboard: space y and space p", "hello world\n", "w<space>yb<space>p", "NOR", "hello ¦‡«hello »world\n", CLIPBOARD, ""),
    ("clipboard: y with ZSH_HELIX_SYSTEM_CLIPBOARD", "hello world\n", "wyb<space>P", "NOR", "¦‡«hello »hello world\n",
     CLIPBOARD + "ZSH_HELIX_SYSTEM_CLIPBOARD=1", ""),
    ("clipboard: multiple selections round trip", "a b\n", "%s\\w<ret><space>y<space>p", "NOR", "a«a¦‡» b«b¦»\n", CLIPBOARD, ""),
    ("clipboard: \"+ register", "hello\n", '"+yw"+p', "NOR", "hello«h¦‡»\n", CLIPBOARD, ""),
    ("external: change is picked up", "hello\n", "A<C-x><C-t><esc>", "NOR", "helloEXT«\n¦‡»", "", EXTERNAL),
    ("external: change can be undone", "hello\n", "<C-x><C-t>u", "NOR", "«h¦‡»ello\n", "", EXTERNAL),
    ("external: editing continues normally", "hello\n", "A<C-x><C-t>!<esc>b", "NOR", "helloEXT¦‡«!»\n", "", EXTERNAL),
    ("macro register holds key notation", "one two\n", 'Qw<esc>Q"@P', "NOR", "«w<esc>¦‡»one two\n", "", ""),
    ("unicode typing", "x\n", "iéñ日<esc>", "NOR", "éñ日¦‡«x»\n", "", ""),
    ("insert mode Alt key inserts its letter", "x\n", "i<A-q><esc>", "NOR", "q¦‡«x»\n", "", ""),
    ("insert mode Ctrl-v inserts literally", "x\n", "i<C-v><C-a><esc>", "NOR", "\x01«x¦‡»\n", "", ""),
    ("unbound function key is ignored in normal mode", "abc\n", "l<F5>l", "NOR", "ab«c¦‡»\n", "", ""),
    ("unbound function key is ignored in insert mode", "abc\n", "i<F5>x<esc>", "NOR", "x¦‡«a»bc\n", "", ""),
    ("initial mode can be normal", "abc\n", "l", "NOR", "a«b¦‡»c\n", "", ""),
]


def run_case(case):
    name, text, keys, want_mode, want, rc_before, rc_after = case
    clip = tempfile.mktemp(prefix="zhm-clip-")
    env = {"ZHM_TEST_CLIP": clip}
    try:
        mode, marked = harness.run_zsh(text, keys, env_extra=env, rc_before=rc_before, rc_after=rc_after)
    except Exception as e:  # noqa: BLE001
        mode, marked = "ERROR", str(e)
    finally:
        if os.path.exists(clip):
            os.remove(clip)
    ok = mode == want_mode and marked == want
    return name, ok, (want_mode, want), (mode, marked)


def run_accept_cases():
    """Running the command line, and Ctrl-d on an empty line."""
    failures = []
    d = tempfile.mkdtemp(prefix="zhm-accept-")
    ran = os.path.join(d, "ran")
    for name, keys, expect in [
        ("Enter runs the line in insert mode", "iecho hi<ret>", "echo hi\n"),
        ("Enter runs the line in normal mode", "iecho hi<esc><ret>", "echo hi\n"),
        (":w runs the line", "iecho hi<esc>:w<ret>", "echo hi\n"),
        (":q abandons the line", "iecho hi<esc>:q<ret>", ""),
    ]:
        if os.path.exists(ran):
            os.remove(ran)
        harness.run_zsh("\n", keys, env_extra={"ZHM_TEST_RAN": ran}, rc_after=PREEXEC)
        got = open(ran).read() if os.path.exists(ran) else ""
        if got != expect:
            failures.append((name, expect, got))
    return failures


def main():
    failures = 0
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        for name, ok, want, got in pool.map(run_case, CASES):
            if ok:
                continue
            failures += 1
            print(f"FAIL {name}")
            print(f"  expected ({want[0]}): {want[1]!r}")
            print(f"  got      ({got[0]}): {got[1]!r}")
    for name, want, got in run_accept_cases():
        failures += 1
        print(f"FAIL {name}\n  expected: {want!r}\n  got:      {got!r}")
    total = len(CASES) + 4
    print(f"{total - failures}/{total} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
