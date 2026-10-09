"""Real disposable PTY child for tests, not a fabricated Pi transcript/lifecycle."""
import argparse
import json
import os
from pathlib import Path
import selectors
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument("state", type=Path)
parser.add_argument("--flood", action="store_true")
args = parser.parse_args()
selector = selectors.DefaultSelector()
selector.register(sys.stdin, selectors.EVENT_READ)
received = []
ticks = 0
print(f"PTY child {os.getpid()}", flush=True)
while True:
    for _, _ in selector.select(timeout=0.02):
        data = os.read(sys.stdin.fileno(), 4096)
        if not data:
            sys.exit(0)
        received.append(data.decode("utf-8", errors="replace"))
        received = received[-10:]
        print(f"input: {received[-1]!r}", flush=True)
    ticks += 1
    size = os.get_terminal_size(sys.stdin.fileno())
    state = {"pid": os.getpid(), "ticks": ticks, "received": received,
             "rows": size.lines, "columns": size.columns,
             "inherited_axo": [key for key in os.environ if key.startswith("AXO_")]}
    temporary = args.state.with_suffix(".tmp")
    temporary.write_text(json.dumps(state))
    temporary.replace(args.state)
    if args.flood:
        os.write(sys.stdout.fileno(), b"x" * 16384)
    else:
        print(f"tick {ticks}", flush=True)
