"""Owned, time-bounded descendant keeps a real PTY open after its initial child exits."""
import json
import os
from pathlib import Path
import signal
import sys
import time

state, release, done = map(Path, sys.argv[1:])
parent_pid = os.getpid()
child_pid = os.fork()
if child_pid:
    deadline = time.monotonic() + 3
    while not state.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    os._exit(0)

signal.signal(signal.SIGHUP, signal.SIG_IGN)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
state.write_text(json.dumps({"parent_pid": parent_pid, "child_pid": os.getpid()}))
# A release file avoids signaling any unverified historical PID, even after a daemon restart.
deadline = time.monotonic() + 15
while not release.exists() and time.monotonic() < deadline:
    time.sleep(0.02)
done.touch()
os._exit(0)
