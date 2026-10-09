"""Disposable terminal client for the Rust PTY host; Ctrl-] detaches, not stops."""
import argparse
from collections import deque
import json
import os
import selectors
import signal
import socket
import sys
import termios
import tty


class Connection:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.connect(path)
        self.buffer = bytearray()

    def send(self, operation, **arguments):
        frame = json.dumps({"op": operation, **arguments}).encode() + b"\n"
        self.socket.sendall(frame)

    def events(self):
        while b"\n" in self.buffer:
            frame, _, remainder = self.buffer.partition(b"\n")
            self.buffer = bytearray(remainder)
            yield json.loads(frame)

    def receive(self):
        while b"\n" not in self.buffer:
            if not self.read():
                raise EOFError("POC host disconnected")
        return next(self.events())

    def read(self):
        data = self.socket.recv(4096)
        self.buffer.extend(data)
        if len(self.buffer) > 65536:
            raise ValueError("POC response exceeds client frame bound")
        return bool(data)

    def close(self):
        self.socket.close()


def resize(connection, session):
    size = os.get_terminal_size(sys.stdin.fileno())
    connection.send("resize", session=session, rows=max(1, size.lines), columns=max(1, size.columns))


def attach(connection, session):
    if not sys.stdin.isatty():
        raise ValueError("Attach needs a real terminal; use the integration tests for automation")
    connection.send("attach", session=session)
    reply = connection.receive()
    if reply["event"] != "attached":
        raise ValueError(reply.get("message", "Attachment rejected"))
    original = termios.tcgetattr(sys.stdin.fileno())
    pending_input = deque()
    resized = True

    def mark_resize(_signal, _frame):
        nonlocal resized
        resized = True

    previous_signal = signal.signal(signal.SIGWINCH, mark_resize)
    selector = selectors.DefaultSelector()
    selector.register(connection.socket, selectors.EVENT_READ)
    selector.register(sys.stdin, selectors.EVENT_READ)
    try:
        tty.setraw(sys.stdin.fileno())
        while True:
            if resized:
                resize(connection, session)
                resized = False
            for event in connection.events():
                kind = event["event"]
                if kind == "output":
                    sys.stdout.buffer.write(bytes(event["data"]))
                    sys.stdout.buffer.flush()
                elif kind == "input_accepted":
                    expected = pending_input.popleft()
                    if event["bytes"] != expected:
                        raise ValueError("Partial input accepted; nothing was automatically replayed")
                elif kind == "error":
                    raise ValueError(event["message"])
                elif kind == "exited":
                    return
            for key, _ in selector.select(timeout=0.1):
                if key.fileobj is connection.socket:
                    if not connection.read():
                        return
                else:
                    data = os.read(sys.stdin.fileno(), 1024)
                    if not data or b"\x1d" in data:
                        connection.send("detach")
                        return
                    pending_input.append(len(data))
                    connection.send("input", session=session, data=list(data))
    finally:
        termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, original)
        signal.signal(signal.SIGWINCH, previous_signal)
        selector.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True)
    commands = parser.add_subparsers(dest="operation", required=True)
    create = commands.add_parser("create")
    create.add_argument("--cwd", required=True)
    create.add_argument("command", nargs=argparse.REMAINDER)
    commands.add_parser("list")
    for name in ("attach", "stop"):
        commands.add_parser(name).add_argument("session")
    args = parser.parse_args()
    connection = Connection(args.socket)
    try:
        if args.operation == "attach":
            attach(connection, args.session)
            return
        if args.operation == "create":
            command = args.command[1:] if args.command[:1] == ["--"] else args.command
            connection.send("create", cwd=args.cwd, argv=command)
        elif args.operation == "stop":
            connection.send("stop", session=args.session)
        else:
            connection.send("list")
        reply = connection.receive()
        print(json.dumps(reply, indent=2))
        if reply["event"] == "error":
            sys.exit(1)
    finally:
        connection.close()


if __name__ == "__main__":
    main()
