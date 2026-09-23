#!/usr/bin/env python3
"""Run a command on a pseudo-terminal and type keys into it.

    pty_run.py [KEY ...] -- COMMAND [ARG ...]

The installer's selector refuses to run unless stdin and stdout are terminals,
so bats can only reach it through a pty. Each KEY is one keypress, written in
Python escape syntax (\\x1b[B for the down arrow, \\r for Enter), sent after
the selector has drawn its first frame and 0.2s apart so each read sees exactly
one key. Prints everything the command wrote and exits with its status.
"""
import codecs
import os
import pty
import select
import sys
import time

sep = sys.argv.index("--")
keys = [codecs.decode(k, "unicode_escape") for k in sys.argv[1:sep]]
cmd = sys.argv[sep + 1:]

pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)

out = b""


def pump(seconds):
    """Read output for up to `seconds`. False once the command has exited."""
    global out
    end = time.time() + seconds
    while True:
        left = end - time.time()
        if left <= 0:
            return True
        ready, _, _ = select.select([fd], [], [], left)
        if not ready:
            return True
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            return False
        if not chunk:
            return False
        out += chunk


alive = True
deadline = time.time() + 10
while alive and b"enter confirm" not in out and time.time() < deadline:
    alive = pump(0.1)
for key in keys:
    if not alive:
        break
    os.write(fd, key.encode())
    alive = pump(0.2)
deadline = time.time() + 20
while alive and time.time() < deadline:
    alive = pump(0.5)

_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace"))
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status))
