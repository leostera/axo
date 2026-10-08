"""Run the real Pi TUI on a PTY without requiring a graphical terminal."""
import fcntl
import os
import pty
import signal
import struct
import subprocess
import sys
import termios

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
child = subprocess.Popen(sys.argv[1:], stdin=slave, stdout=slave, stderr=slave)
os.close(slave)

def stop(_signum, _frame):
    child.terminate()
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
    sys.exit(0)

signal.signal(signal.SIGTERM, stop)
try:
    while child.poll() is None:
        try:
            data = os.read(master, 65536)
            if not data:
                break
            os.write(sys.stdout.fileno(), data)
        except OSError:
            break
finally:
    if child.poll() is None:
        child.terminate()
    child.wait()
    os.close(master)
