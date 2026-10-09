"""Real axod integration tests using private state and owned synthetic terminal children."""
from collections import deque
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "target/debug/axod"


def identity():
    return str(uuid.uuid4())


def eventually(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.02)
    raise AssertionError("axod condition exceeded deadline")


class Client:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(3)
        self.socket.connect(str(path))
        self.reader = self.socket.makefile("rb")
        self.events = deque()
        self.next_id = 0
        self.generation = None
        hello = self.call({"op": "hello"})
        assert hello["kind"] == "hello", hello
        assert hello["protocol_version"] == 1
        self.generation = hello["host_generation"]

    def call(self, command, *, request_id=None, generation=None, version=1):
        if request_id is None:
            self.next_id += 1
            request_id = self.next_id
        request = {"version": version, "request_id": request_id,
                   "host_generation": self.generation if generation is None else generation,
                   "command": command}
        self.socket.sendall(json.dumps(request).encode() + b"\n")
        while True:
            frame = self.receive()
            if frame["frame"] == "response":
                assert frame["request_id"] == request_id
                return frame["response"]
            self.events.append(frame)

    def receive(self):
        frame = self.reader.readline(65537)
        if not frame:
            raise EOFError("axod closed connection")
        assert len(frame) <= 65536 and frame.endswith(b"\n")
        return json.loads(frame)

    def close(self):
        self.reader.close()
        self.socket.close()


class DaemonTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(["cargo", "build", "--offline"], cwd=ROOT, check=True)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="axod-tests-", dir="/tmp")
        self.directory = Path(self.temporary.name)
        self.endpoint = self.directory / "control.sock"
        self.host = None
        self.client = None
        self.launch_host()

    def launch_host(self):
        self.host = subprocess.Popen([str(BINARY), "serve", str(self.directory)],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        eventually(lambda: self.endpoint.exists() or self.host.poll() is not None)
        self.assertIsNone(self.host.poll())
        self.client = Client(self.endpoint)

    def stop_host(self):
        if self.client:
            self.client.close()
            self.client = None
        self.host.terminate()
        self.host.wait(timeout=5)
        self.host.stderr.close()
        self.assertEqual(self.host.returncode, 0)

    def tearDown(self):
        try:
            if self.host and self.host.poll() is None:
                self.stop_host()
        finally:
            self.temporary.cleanup()

    def start(self, name, target=None, command_id=None, flood=False):
        target = target or {"session_id": identity(), "pane_id": identity()}
        state = self.directory / f"{name}.json"
        argv = [sys.executable, str(ROOT / "tests/fixtures/terminal_child.py"), str(state)]
        if flood:
            argv.append("--flood")
        command = {"op": "start", "command_id": command_id or identity(), "target": target,
                   "launch": {"directory": str(self.directory), "argv": argv}}
        reply = self.client.call(command)
        self.assertEqual(reply["kind"], "started", reply)
        eventually(lambda: state.exists())
        self.assertEqual(self.read(state)["inherited_axo"], [])
        self.assertEqual(self.read(state)["inherited_fds"], [])
        return reply["terminal"], state, command

    @staticmethod
    def read(path):
        return json.loads(path.read_text())

    def snapshots(self):
        reply = self.client.call({"op": "list"})
        self.assertEqual(reply["kind"], "terminals")
        return reply["terminals"]

    def attachment(self, client, terminal):
        reply = client.call({"op": "attach", "runtime": terminal["runtime"]})
        self.assertEqual(reply["kind"], "attached", reply)
        self.assertEqual(reply["attachment"]["runtime"], terminal["runtime"])
        return reply

    def test_start_is_durably_idempotent_and_conflicting_reuse_is_rejected(self):
        terminal, state, command = self.start("one")
        repeated = self.client.call(command)
        self.assertEqual(repeated["terminal"]["runtime"], terminal["runtime"])
        self.assertEqual(self.read(state)["pid"], terminal["process"]["pid"])
        conflict = dict(command, launch={"directory": str(self.directory), "argv": ["/bin/sh"]})
        self.assertEqual(self.client.call(conflict)["code"], "conflict")
        self.assertEqual(len(self.snapshots()), 1)
        saved = (self.directory / "runtime-state.json").read_text()
        self.assertNotIn("argv", saved)
        self.assertNotIn(str(ROOT), saved)
        self.assertEqual(os.stat(self.directory / "runtime-state.json").st_mode & 0o777, 0o600)

    def test_disconnect_reconnect_preserves_runtime_and_changes_attachment(self):
        terminal, state, _ = self.start("one")
        first = Client(self.endpoint)
        original = self.attachment(first, terminal)
        first.close()
        eventually(lambda: self.snapshots()[0]["attached"] is False)
        ticks = self.read(state)["ticks"]
        eventually(lambda: self.read(state)["ticks"] > ticks + 3)
        second = Client(self.endpoint)
        try:
            replacement = self.attachment(second, terminal)
            self.assertNotEqual(replacement["attachment"], original["attachment"])
            self.assertEqual(self.read(state)["pid"], terminal["process"]["pid"])
            rejected = second.call({"op": "input", "attachment": original["attachment"], "data": [65]})
            self.assertEqual(rejected["code"], "stale_attachment")
        finally:
            second.close()

    def test_parallel_input_resize_and_request_retry_never_replays_input(self):
        one, state, _ = self.start("one")
        _, other_state, _ = self.start("two")
        attached = self.attachment(self.client, one)["attachment"]
        command = {"op": "input", "attachment": attached, "data": list("hello λ\n".encode())}
        reply = self.client.call(command)
        request_id = self.client.next_id
        self.assertEqual(reply["bytes"], len("hello λ\n".encode()))
        self.assertEqual(self.client.call(command, request_id=request_id), reply)
        eventually(lambda: self.read(state)["received"])
        time.sleep(0.1)
        self.assertEqual(len(self.read(state)["received"]), 1)
        self.assertEqual(self.read(other_state)["received"], [])
        self.assertEqual(self.client.call({"op": "resize", "attachment": attached, "rows": 42, "columns": 91})["kind"], "ok")
        eventually(lambda: self.read(state)["rows"] == 42)
        self.assertEqual(self.read(state)["columns"], 91)

    def test_generation_version_and_second_attachment_are_fenced(self):
        terminal, _, _ = self.start("one")
        self.assertEqual(self.client.call({"op": "list"}, generation=identity())["code"], "stale_host")
        self.assertEqual(self.client.call({"op": "list"}, version=99)["code"], "incompatible_version")
        old_runtime = dict(terminal["runtime"], runtime_generation=identity())
        self.assertEqual(self.client.call({"op": "stop", "runtime": old_runtime})["code"], "stale_runtime")
        self.attachment(self.client, terminal)
        other = Client(self.endpoint)
        try:
            self.assertEqual(other.call({"op": "attach", "runtime": terminal["runtime"]})["code"], "already_attached")
        finally:
            other.close()

    def test_headless_and_slow_output_are_bounded_with_contiguous_offsets(self):
        terminal, state, _ = self.start("flood", flood=True)
        eventually(lambda: self.read(state)["ticks"] > 10)
        self.assertLessEqual(self.snapshots()[0]["backlog_bytes"], 8192)
        slow = Client(self.endpoint)
        try:
            reply = self.attachment(slow, terminal)
            self.assertTrue(reply["backlog"]["truncated"])
            first = slow.receive()
            self.assertEqual(first["frame"], "output")
            self.assertEqual(first["offset"], reply["backlog"]["next_offset"])
            ticks = self.read(state)["ticks"]
            eventually(lambda: self.read(state)["ticks"] > ticks + 40)
            eventually(lambda: self.snapshots()[0]["attached"] is False)
        finally:
            slow.close()

    def test_clean_shutdown_reaps_children_and_does_not_restart_on_next_boot(self):
        terminal, _, command = self.start("one")
        generation = self.client.generation
        self.stop_host()
        self.assertFalse(self.endpoint.exists())
        self.launch_host()
        self.assertNotEqual(self.client.generation, generation)
        records = self.snapshots()
        self.assertEqual(records[0]["process"]["kind"], "exited")
        reconciled = self.client.call(command)
        self.assertEqual(reconciled["kind"], "started")
        self.assertEqual(reconciled["terminal"]["runtime"], terminal["runtime"])
        self.assertEqual(reconciled["terminal"]["process"]["kind"], "exited")
        # A fresh explicit intent can reopen that same pane with a new generation, not replay its old request.
        next_command = dict(command, command_id=identity())
        restarted = self.client.call(next_command)
        self.assertEqual(restarted["kind"], "started")
        self.assertNotEqual(restarted["terminal"]["runtime"], terminal["runtime"])
        self.assertEqual(self.client.call(command)["code"], "stale_runtime")

    def test_uncertain_previous_runtime_is_read_only_recovery_not_auto_launch(self):
        terminal, _, command = self.start("one")
        self.stop_host()
        path = self.directory / "runtime-state.json"
        saved = json.loads(path.read_text())
        record = next(iter(saved["terminals"].values()))
        record["process"] = {"kind": "starting"}
        path.write_text(json.dumps(saved))
        self.launch_host()
        self.assertEqual(self.snapshots()[0]["process"]["kind"], "recovery_required")
        command = dict(command, command_id=identity())
        self.assertEqual(self.client.call(command)["code"], "recovery_required")
        self.assertFalse(self.snapshots()[0]["attached"])

    def test_stopped_record_paging_is_bounded_and_never_starts_processes(self):
        self.stop_host()
        records = {}
        for _ in range(3):
            pane = identity()
            records[pane] = {"runtime": {"host_generation": identity(),
                "target": {"session_id": identity(), "pane_id": pane},
                "runtime_generation": identity()}, "process": {"kind": "exited", "wait_status": 0},
                "attached": False, "backlog_bytes": 0}
        path = self.directory / "runtime-state.json"
        path.write_text(json.dumps({"version": 1, "terminals": records, "receipts": {}}))
        os.chmod(path, 0o600)
        self.launch_host()
        first = self.client.call({"op": "list", "limit": 2})
        self.assertEqual(len(first["terminals"]), 2)
        self.assertIsNotNone(first["next"])
        second = self.client.call({"op": "list", "after": first["next"], "limit": 2})
        self.assertEqual(len(second["terminals"]), 1)
        self.assertIsNone(second["next"])
        self.assertEqual(self.client.call({"op": "list", "limit": 51})["code"], "invalid_request")
        self.assertTrue(all(record["process"]["kind"] == "exited" for record in first["terminals"] + second["terminals"]))

    def test_final_output_is_delivered_before_exit_and_detach_releases_exited_lease(self):
        command = {"op": "start", "command_id": identity(),
            "target": {"session_id": identity(), "pane_id": identity()},
            "launch": {"directory": str(self.directory), "argv": [
                "/bin/sh", "-c", "read -r ignored; printf 'final-output\\n'; exit 7"]}}
        terminal = self.client.call(command)["terminal"]
        attached = self.attachment(self.client, terminal)["attachment"]
        self.client.call({"op": "input", "attachment": attached, "data": list(b"go\n")})
        output = bytearray()
        while True:
            event = self.client.events.popleft() if self.client.events else self.client.receive()
            if event["frame"] == "output":
                output.extend(event["data"])
            elif event["frame"] == "exited":
                self.assertEqual(os.waitstatus_to_exitcode(event["wait_status"]), 7)
                break
        self.assertIn(b"final-output", output)
        self.assertEqual(self.client.call({"op": "detach", "attachment": attached})["kind"], "ok")

    def test_failed_launch_is_a_durable_failure_not_an_automatic_retry(self):
        command = {"op": "start", "command_id": identity(),
            "target": {"session_id": identity(), "pane_id": identity()},
            "launch": {"directory": "/does/not/exist", "argv": ["/bin/sh"]}}
        self.assertEqual(self.client.call(command)["code"], "launch_failed")
        self.assertEqual(self.client.call(command)["code"], "launch_failed")
        self.assertEqual(self.snapshots()[0]["process"]["kind"], "failed")
        self.stop_host()
        self.launch_host()
        self.assertEqual(self.client.call(command)["code"], "launch_failed")

    def test_repeated_stop_escalates_once_without_stopping_a_sibling(self):
        sibling, sibling_state, _ = self.start("sibling")
        ready = self.directory / "stop-ready"
        command = {"op": "start", "command_id": identity(),
            "target": {"session_id": identity(), "pane_id": identity()},
            "launch": {"directory": str(self.directory), "argv": [
                "/bin/sh", "-c", "trap '' TERM; : > \"$1\"; read -r value", "axod-test", str(ready)]}}
        terminal = self.client.call(command)["terminal"]
        eventually(ready.exists)
        for _ in range(64):
            self.assertEqual(self.client.call({"op": "stop", "runtime": terminal["runtime"]})["kind"], "ok")
        exited = eventually(lambda: next((record for record in self.snapshots()
            if record["runtime"] == terminal["runtime"] and record["process"]["kind"] == "exited"), None))
        self.assertEqual(os.waitstatus_to_exitcode(exited["process"]["wait_status"]), -9)
        ticks = self.read(sibling_state)["ticks"]
        eventually(lambda: self.read(sibling_state)["ticks"] > ticks + 3)
        self.assertEqual(self.read(sibling_state)["pid"], sibling["process"]["pid"])

    def test_duplicate_daemon_and_symlink_journal_are_rejected(self):
        duplicate = subprocess.run([str(BINARY), "serve", str(self.directory)], capture_output=True, timeout=3)
        self.assertNotEqual(duplicate.returncode, 0)
        self.assertEqual(self.snapshots(), [])
        self.stop_host()
        (self.directory / "runtime-state.json").symlink_to(self.directory / "elsewhere")
        invalid = subprocess.run([str(BINARY), "serve", str(self.directory)], capture_output=True, timeout=3)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertFalse((self.directory / "elsewhere").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
