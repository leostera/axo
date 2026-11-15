#!/usr/bin/python3
"""Owned PTY fixture: proves rendering, keyboard input and SIGWINCH delivery."""
import fcntl
import json
import os
import pathlib
import signal
import struct
import sys
import termios

state_file = pathlib.Path(sys.argv[1])
state = {'pid': os.getpid(), 'input': None, 'inputCount': 0, 'exited': False}


def publish(*_):
    rows, columns, _, _ = struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, b'\0' * 8))
    state.update(rows=rows, columns=columns, tty=os.isatty(0))
    temporary = state_file.with_suffix('.tmp')
    temporary.write_text(json.dumps(state))
    temporary.replace(state_file)


signal.signal(signal.SIGWINCH, publish)
print('\033[2J\033[H\033[32mGHOSTTY_RENDER_PROBE\033[0m')
print('\033[42m                         \033[0m  Rust + GTK4 + Ghostty')
if '--replay-probe' in sys.argv[2:]:
    print('REPLAY_LONG_BEGIN' + '0123456789' * 16 + 'REPLAY_LONG_END')
print('Unicode: λ café 日本語 👻')
print('Type into this real PTY:')
sys.stdout.flush()
publish()
for line in sys.stdin:
    state['input'] = line.strip()
    state['inputCount'] += 1
    publish()
    print('INPUT_OK:', state['input'], flush=True)
    if state['input'] == 'quit':
        state['exited'] = True
        publish()
        break
