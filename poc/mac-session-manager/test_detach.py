"""Isolated real-process tests; no live Axo, tmux, Pi account, or Accessibility."""
import json
import os
from pathlib import Path
import pty
import subprocess
import sys
import tempfile
import time
import unittest

from client import Connection

HERE = Path(__file__).resolve().parent
BINARY = HERE / "target/debug/axo-host-poc"


def eventually(predicate, timeout=4):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.02)
    raise AssertionError("POC condition did not become true within the deadline")


class DetachTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(["cargo", "build", "--offline"], cwd=HERE, check=True)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="axo-pty-poc-", dir="/tmp")
        self.root = Path(self.temporary.name)
        self.socket = str(self.root / "host.sock")
        self.host = subprocess.Popen([str(BINARY), "serve", self.socket], stdout=subprocess.DEVNULL,
                                     stderr=subprocess.PIPE)
        self.sessions = []
        eventually(lambda: Path(self.socket).exists() or self.host.poll() is not None)
        self.assertIsNone(self.host.poll())

    def tearDown(self):
        try:
            for session in self.sessions:
                self.request("stop", session=session)
            if self.sessions:
                eventually(lambda: all(value["process"]["kind"] == "exited"
                                       for value in self.request("list")["sessions"]))
        finally:
            self.host.terminate()
            self.host.wait(timeout=3)
            self.host.stderr.close()
            self.temporary.cleanup()

    def request(self, operation, **arguments):
        connection = Connection(self.socket)
        connection.socket.settimeout(3)
        try:
            connection.send(operation, **arguments)
            return connection.receive()
        finally:
            connection.close()

    def create(self, name, flood=False):
        state = self.root / f"{name}.json"
        arguments = [sys.executable, str(HERE / "fixture.py"), str(state)]
        if flood:
            arguments.append("--flood")
        reply = self.request("create", cwd=str(self.root), argv=arguments)
        self.assertEqual(reply["event"], "created", reply)
        session = reply["session"]
        self.sessions.append(session["id"])
        eventually(lambda: state.exists())
        self.assertEqual(self.state(state)["pid"], session["process"]["pid"])
        self.assertEqual(self.state(state)["inherited_axo"], [])
        return session, state

    @staticmethod
    def state(path):
        return json.loads(path.read_text())

    def connect(self, session):
        connection = Connection(self.socket)
        connection.socket.settimeout(3)
        connection.send("attach", session=session["id"])
        reply = connection.receive()
        self.assertEqual(reply["event"], "attached", reply)
        self.assertEqual(reply["session"]["process"]["pid"], session["process"]["pid"])
        return connection

    def detached(self, session):
        return next(value for value in self.request("list")["sessions"]
                    if value["id"] == session["id"])["attached"] is False

    def test_disconnect_reconnect_keeps_same_real_process_and_output(self):
        session, state = self.create("one")
        first = self.connect(session)
        self.assertEqual(first.receive()["event"], "output")
        first.close()
        eventually(lambda: self.detached(session))
        ticks = self.state(state)["ticks"]
        eventually(lambda: self.state(state)["ticks"] > ticks + 3)
        second = self.connect(session)
        self.assertEqual(second.receive()["event"], "output")
        self.assertEqual(self.state(state)["pid"], session["process"]["pid"])
        second.close()

    def test_parallel_destinations_input_lease_and_real_resize(self):
        one, first_state = self.create("one")
        two, second_state = self.create("two")
        client = self.connect(one)
        try:
            client.send("input", session=one["id"], data=list("hello λ\n".encode()))
            client.send("resize", session=one["id"], rows=42, columns=91)
            eventually(lambda: self.state(first_state)["received"])
            eventually(lambda: self.state(first_state)["rows"] == 42)
            self.assertEqual(self.state(first_state)["columns"], 91)
            self.assertIn("hello λ", self.state(first_state)["received"][0])
            self.assertEqual(self.state(second_state)["received"], [])
            self.assertEqual(self.request("input", session=two["id"], data=[65])["event"], "error")
            self.assertEqual(self.request("attach", session=one["id"])["event"], "error")
            self.assertEqual(self.request("resize", session=one["id"], rows=0, columns=80)["event"], "error")
        finally:
            client.close()

    def test_terminating_frontend_process_does_not_terminate_child(self):
        session, state = self.create("one")
        host_endpoint, child_endpoint = pty.openpty()
        frontend = subprocess.Popen([sys.executable, str(HERE / "client.py"), "--socket", self.socket,
                                     "attach", session["id"]], stdin=child_endpoint, stdout=child_endpoint, stderr=child_endpoint)
        os.close(child_endpoint)
        try:
            eventually(lambda: not self.detached(session))
            frontend.kill()
            frontend.wait(timeout=3)
            eventually(lambda: self.detached(session))
            ticks = self.state(state)["ticks"]
            eventually(lambda: self.state(state)["ticks"] > ticks + 3)
            connection = self.connect(session)
            connection.close()
        finally:
            if frontend.poll() is None:
                frontend.kill()
                frontend.wait(timeout=3)
            os.close(host_endpoint)

    def test_real_terminal_interrupt_stops_only_its_addressed_child(self):
        session, state = self.create("one")
        sibling, sibling_state = self.create("two")
        client = self.connect(session)
        try:
            client.send("input", session=session["id"], data=[3])
            eventually(lambda: next(value for value in self.request("list")["sessions"]
                                    if value["id"] == session["id"])["process"]["kind"] == "exited")
            ticks = self.state(sibling_state)["ticks"]
            eventually(lambda: self.state(sibling_state)["ticks"] > ticks + 3)
            self.assertEqual(self.state(sibling_state)["pid"], sibling["process"]["pid"])
        finally:
            client.close()

    def test_exit_event_follows_final_terminal_output(self):
        reply = self.request("create", cwd=str(self.root), argv=[
            "/bin/sh", "-c", "read -r ignored; printf 'final-output\\n'; exit 7"])
        self.assertEqual(reply["event"], "created")
        session = reply["session"]
        self.sessions.append(session["id"])
        client = self.connect(session)
        output = bytearray()
        try:
            client.send("input", session=session["id"], data=list(b"go\n"))
            while True:
                event = client.receive()
                if event["event"] == "output":
                    output.extend(event["data"])
                elif event["event"] == "exited":
                    self.assertEqual(os.waitstatus_to_exitcode(event["wait_status"]), 7)
                    break
            self.assertIn(b"final-output", output)
        finally:
            client.close()

    def test_headless_output_is_drained_and_backlog_is_bounded(self):
        session, state = self.create("flood", flood=True)
        eventually(lambda: self.state(state)["ticks"] > 30)
        snapshot = self.request("list")["sessions"][0]
        self.assertFalse(snapshot["attached"])
        self.assertLessEqual(snapshot["backlog_bytes"], 16384)
        self.assertEqual(snapshot["process"]["pid"], session["process"]["pid"])

    def test_slow_client_cannot_block_child_and_loses_lease(self):
        session, state = self.create("flood", flood=True)
        client = self.connect(session)
        try:
            ticks = self.state(state)["ticks"]
            eventually(lambda: self.state(state)["ticks"] > ticks + 40)
            eventually(lambda: self.detached(session))
        finally:
            client.close()

    def test_invalid_create_and_duplicate_host_do_not_launch_or_replace(self):
        self.assertEqual(self.request("create", cwd="/does/not/exist", argv=["/bin/zsh"])["event"], "error")
        self.assertEqual(self.request("create", cwd=str(self.root), argv=[])["event"], "error")
        self.assertEqual(self.request("create", cwd=str(self.root), argv=["/bin/zsh\0"])["event"], "error")
        self.assertEqual(self.request("list")["sessions"], [])
        duplicate = subprocess.run([str(BINARY), "serve", self.socket], capture_output=True, timeout=3)
        self.assertNotEqual(duplicate.returncode, 0)
        self.assertEqual(self.request("list")["sessions"], [])
        self.assertIsNone(self.host.poll())


if __name__ == "__main__":
    unittest.main(verbosity=2)
