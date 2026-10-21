"""Drive Helix and zsh (with zshelix) in pseudo-terminals.

Both are given the same text and key sequence, and the resulting text,
selections and mode are captured in the same format so they can be compared:

    «...¦»   a forward selection (the cursor is on the last character)
    ¦«...»   a backward selection (the cursor is on the first character)
    ‡        follows the ¦ of the primary selection

For Helix, this is captured by having Helix itself insert the markers
(`ms«`, then inserting ¦ at every cursor and ‡ at the primary cursor), so the
expected output comes entirely from Helix's own behaviour.
"""

import fcntl
import os
import pty
import re
import select
import shutil
import signal
import struct
import tempfile
import termios
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

ROWS, COLS = 30, 100

NAMED_KEYS = {
    "esc": b"\x1b",
    "ret": b"\r",
    "tab": b"\t",
    "S-tab": b"\x1b[Z",
    "backspace": b"\x7f",
    "del": b"\x1b[3~",
    "left": b"\x1b[D",
    "right": b"\x1b[C",
    "up": b"\x1b[A",
    "down": b"\x1b[B",
    "home": b"\x1b[H",
    "end": b"\x1b[F",
    "pageup": b"\x1b[5~",
    "pagedown": b"\x1b[6~",
    "space": b" ",
    "lt": b"<",
    "gt": b">",
    "minus": b"-",
    "F5": b"\x1b[15~",
}


def parse_keys(spec):
    """Parse keys in Helix macro notation (e.g. `w<A-;>x<esc>`) into the
    byte sequences a terminal sends for each key."""
    events = []
    i = 0
    while i < len(spec):
        c = spec[i]
        if c == "<" and ">" in spec[i + 1 :]:
            j = spec.index(">", i)
            name = spec[i + 1 : j]
            i = j + 1
            if name in NAMED_KEYS:
                events.append(NAMED_KEYS[name])
            elif name.startswith("paste:"):
                # A bracketed paste, sent all at once as a terminal would.
                content = name[len("paste:") :].replace("\\n", "\n").replace("\\t", "\t")
                events.append(b"\x1b[200~" + content.encode() + b"\x1b[201~")
            elif name.startswith("A-"):
                rest = name[2:]
                events.append(b"\x1b" + NAMED_KEYS.get(rest, rest.encode()))
            elif name.startswith("C-"):
                events.append(bytes([ord(name[2:].lower()) & 0x1F]))
            else:
                raise ValueError(f"unknown key <{name}>")
        else:
            events.append(c.encode())
            i += 1
    return events


class Pty:
    def __init__(self, argv, env, cwd=None):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            if cwd:
                os.chdir(cwd)
            os.execvpe(argv[0], argv, env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        self.output = b""

    def read(self, timeout):
        end = time.time() + timeout
        while True:
            r, _, _ = select.select([self.fd], [], [], max(0, end - time.time()))
            if not r:
                return
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                return
            if not data:
                return
            self.output += data

    def read_until_quiet(self, quiet, limit=2.0):
        """Read until there's been no output for `quiet` seconds."""
        end = time.time() + limit
        while time.time() < end:
            before = len(self.output)
            self.read(quiet)
            if len(self.output) == before:
                return

    def send(self, data, wait):
        os.write(self.fd, data)
        self.read(wait)

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass
        os.close(self.fd)


# Extra time to wait after Escape, so it isn't merged with the next key into
# an Alt combination. Slow machines (like CI runners) may need more.
ESC_DELAY = float(os.environ.get("ZHM_TEST_ESC_DELAY", "0.06"))


def send_keys(p, events, delay):
    for ev in events:
        os.write(p.fd, ev)
        # Wait until the program has finished responding to the key, so that
        # keys never queue up (which can change how they're parsed).
        p.read_until_quiet(delay)
        if ev == b"\x1b":
            p.read(ESC_DELAY)


def wait_for(path, p, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(path) and os.path.getsize(path) > 0:
            # Give the writer a moment to finish.
            p.read(0.02)
            return True
        p.read(0.02)
    return False


def run_helix(text, keys, delay=0.03, ext="txt"):
    """Returns (mode, marked_text) as produced by Helix."""
    d = tempfile.mkdtemp(prefix="zhm-hx-")
    try:
        home = os.path.join(d, "home")
        cfg = os.path.join(home, ".config", "helix")
        os.makedirs(cfg)
        with open(os.path.join(cfg, "config.toml"), "w") as f:
            f.write("[editor]\ninsert-final-newline = false\n")
        path = os.path.join(d, "t." + ext)
        out = os.path.join(d, "out.txt")
        with open(path, "w") as f:
            f.write(text)
        env = dict(
            os.environ,
            HOME=home,
            XDG_CONFIG_HOME=os.path.join(home, ".config"),
            TERM="xterm-256color",
        )
        env.pop("HELIX_RUNTIME", None)
        p = Pty(["hx", path], env, cwd=d)
        try:
            p.read(0.5)
            send_keys(p, parse_keys(keys), delay)
            p.read(0.15)
            # The mode is drawn in the status line, directly after an escape
            # sequence that sets its colours.
            modes = re.findall(rb"(?:m| )(NOR|INS|SEL)(?=\x1b| )", p.output)
            mode = modes[-1].decode() if modes else "?"
            extract = "ms«;i¦<esc>,i‡<esc>:w! " + out + "<ret>:q!<ret>"
            if mode == "INS":
                extract = "<esc>" + extract
            send_keys(p, parse_keys(extract), delay)
            if not wait_for(out, p):
                raise RuntimeError(f"helix produced no output for {keys!r}")
            with open(out) as f:
                return mode, f.read()
        finally:
            p.close()
    finally:
        shutil.rmtree(d, ignore_errors=True)


ZSHRC = r"""
PS1='> '
PROMPT_EOL_MARK=''
unsetopt beep
HISTFILE=
# Helix has no shell history to move into from the first and last lines.
ZHM_HISTORY_NAVIGATION=0
# Ctrl-s is a Helix binding, so don't let the terminal use it for flow control.
unsetopt flow_control
ZHM_TEST_IN=%(input)s
ZHM_TEST_OUT=%(output)s
source %(plugin)s

function _zhm_test_dump() {
    emulate -L zsh
    local mode
    case $_zhm_mode in
        (normal) mode=NOR ;;
        (insert) mode=INS ;;
        (select) mode=SEL ;;
    esac
    local text=$_zhm_text out="" i
    local -A opens closes points
    local -i n=${#_zhm_sa}
    for (( i = 1; i <= n; i++ )); do
        local -i a=${_zhm_sa[i]} h=${_zhm_sh[i]}
        local -i from=$(( a < h ? a : h )) to=$(( a < h ? h : a ))
        local mark=¦
        (( i == _zhm_pi )) && mark=¦‡
        if (( a == h )); then
            points[$from]+=«$mark»
        elif (( h >= a )); then
            opens[$from]+=«
            closes[$to]+=$mark»
        else
            opens[$from]+=$mark«
            closes[$to]+=»
        fi
    done
    local -i p
    for (( p = 0; p <= ${#text}; p++ )); do
        out+=${closes[$p]}${points[$p]}${opens[$p]}
        (( p < ${#text} )) && out+=${text[p+1]}
    done
    print -rn -- "$mode"$'\n'"$out" >| $ZHM_TEST_OUT.$(( ++_zhm_test_dumps ))
}
typeset -gi _zhm_test_dumps=0
zle -N _zhm_test_dump
for km in zhm-normal zhm-select viins; do
    bindkey -M $km '\e[24~' _zhm_test_dump
done

function _zhm_test_line_init() {
    local content
    content=$(<$ZHM_TEST_IN; print -n x)
    content=${content%%x}
    BUFFER=${content%%$'\n'}
    CURSOR=0
    ZHM_INITIAL_MODE=normal _zhm_line_init
}
add-zle-hook-widget line-init _zhm_test_line_init
"""

F12 = b"\x1b[24~"


# Settings matching Helix's defaults for each file type the tests use.
LANGUAGE_ENV = {
    # No language: tabs for indentation, displayed 4 wide.
    "txt": {"ZHM_INDENT_WIDTH": "0", "ZHM_TAB_WIDTH": "4"},
    # Helix's bash language configuration.
    "sh": {"ZHM_INDENT_WIDTH": "2", "ZHM_TAB_WIDTH": "2"},
}


def run_zsh(text, keys, delay=0.02, env_extra=None, ext="txt", rc_before="", rc_after=""):
    """Returns (mode, marked_text) as produced by zsh with zshelix. rc_before
    and rc_after are extra zshrc lines to run before and after sourcing
    zshelix."""
    if not text.endswith("\n"):
        raise ValueError("test text must end with a newline")
    d = tempfile.mkdtemp(prefix="zhm-zsh-")
    try:
        inp = os.path.join(d, "in.txt")
        out = os.path.join(d, "out")
        with open(inp, "w") as f:
            f.write(text)
        with open(os.path.join(d, ".zshrc"), "w") as f:
            rc = ZSHRC % {
                "input": inp,
                "output": out,
                "plugin": os.path.join(ROOT, "zshelix.plugin.zsh"),
            }
            rc = rc.replace("source " + os.path.join(ROOT, "zshelix.plugin.zsh"),
                            rc_before + "\nsource " + os.path.join(ROOT, "zshelix.plugin.zsh") + "\n" + rc_after)
            f.write(rc)
        env = dict(os.environ, ZDOTDIR=d, TERM="xterm-256color", HOME=d)
        for k in list(env):
            if k.startswith("ZHM_") or k == "ZSH_HELIX_SYSTEM_CLIPBOARD":
                env.pop(k)
        env.update(LANGUAGE_ENV[ext])
        if env_extra:
            env.update(env_extra)
        p = Pty(["zsh", "-d", "-i"], env, cwd=d)
        try:
            p.read(0.3)
            send_keys(p, parse_keys(keys), delay)
            p.send(F12, 0)
            if not wait_for(out + ".1", p):
                raise RuntimeError(
                    f"zsh produced no output for {keys!r}; screen:\n"
                    + p.output.decode(errors="replace")[-2000:]
                )
            with open(out + ".1") as f:
                mode = f.read().split("\n", 1)[0]
            target = out + ".1"
            if mode == "INS":
                p.send(b"\x1b", 0.06)
                p.send(F12, 0)
                if not wait_for(out + ".2", p):
                    raise RuntimeError(f"zsh produced no second output for {keys!r}")
                target = out + ".2"
            with open(target) as f:
                _, marked = f.read().split("\n", 1)
            return mode, marked
        finally:
            p.close()
    finally:
        shutil.rmtree(d, ignore_errors=True)
