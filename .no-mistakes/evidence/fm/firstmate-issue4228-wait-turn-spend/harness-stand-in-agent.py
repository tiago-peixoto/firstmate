#!/usr/bin/env python3
# Stand-in harness agent: draws a Claude-like composer box, echoes typed keys
# into it, and on Enter records the submitted line as a new "turn".
import os, sys, tty, termios, shutil, datetime, select, time
BUSY_SECS = float(os.environ.get("BUSY_SECS", "0"))
busy_until = 0.0
LOG = os.environ["FAKE_AGENT_LOG"]
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setcbreak(fd)
buf = ""
history = []
def draw():
    global busy_until
    cols, rows = shutil.get_terminal_size()
    w = min(cols, 100) - 2
    out = "\x1b[2J\x1b[H"
    out += " * Claude Code (stand-in agent for firstmate live test)\n\n"
    for h in history[-(rows - 8):]:
        out += h[:w] + "\n"
    top = rows - 4
    out += f"\x1b[{top};1H" + "╭" + "─" * w + "╮"
    content = ("> " + buf).ljust(w - 1)
    out += f"\x1b[{top+1};1H" + "│ " + content[: w - 1] + "│"
    out += f"\x1b[{top+2};1H" + "╰" + "─" * w + "╯"
    if time.time() < busy_until:
        out += f"\x1b[{top-1};1H" + "✻ Working… (3s · esc to interrupt)"
    out += f"\x1b[{top+3};1H" + "  ? for shortcuts"
    out += f"\x1b[{top+1};{5 + len(buf)}H"
    sys.stdout.write(out); sys.stdout.flush()
try:
    draw()
    while True:
        r, _, _ = select.select([fd], [], [], 0.5)
        if not r:
            draw()
            continue
        ch = os.read(fd, 1)
        if not ch:
            break
        c = ch.decode("utf-8", "replace")
        if c in ("\r", "\n"):
            line = buf; buf = ""
            ts = datetime.datetime.now().strftime("%H:%M:%S")
            with open(LOG, "a") as f:
                f.write(f"{ts} TURN {line}\n")
            history.append(f"[{ts}] user turn: {line}")
            history.append(f"[{ts}] (agent would spend a full-context model turn here)")
            busy_until = time.time() + BUSY_SECS
        elif c in ("\x7f", "\b"):
            buf = buf[:-1]
        elif c == "\x15":
            buf = ""
        elif c >= " ":
            buf += c
        draw()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
