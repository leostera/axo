# Mac session-manager POC

**Historical reference.** Active daemon implementation and hardening now live in [`axod`](../../axod/README.md). Do not add another POC or extend this one; the current Mac app remains independent until the later daemon cutover.

A small **Rust-owned native PTY host**, independent of the Mac workbench. No tmux, screen, Zellij, replacement Pi CLI, relay, or live Axo state is used.

The host owns each PTY and child process. A disposable Python terminal client attaches through a private Unix socket. Closing/killing that client releases its input lease, not its child. The host drains output even with no attached client. Session IDs are random, validated, POC-local runtime identifiers—not Pi conversation IDs or persisted Axo sessions.

See [RFD0007](../../docs/rfds/RFD0007-mac-session-manager.md) for the proposed production boundaries and sequencing.

## Validate

Tested with macOS and Rust 1.99.0; the binary intentionally targets macOS. This separate crate does not change Axo's Swift/iOS deployment targets.

```sh
cd poc/mac-session-manager
cargo test --offline
cargo clippy --offline --all-targets -- -D warnings
python3 test_detach.py
cargo fmt --check
```

`--offline` requires the locked crates to be cached; a normal `cargo build` can fetch them. Dependencies are `libc`, `serde`, and `serde_json`. No terminal multiplexer dependency or source copied from other terminal projects.

Current checks: **2 Rust tests + 8 real-process integration tests**:

- Disconnect/reconnect to the same child process, with output continuing between attachments.
- Kill an actual frontend process and attach a replacement without restarting its child.
- Parallel terminals with independent input; reject another client's input/resize and a second interactive attachment.
- UTF-8 input and real kernel terminal resizing.
- Ctrl-C delivered through the PTY interrupts only the addressed fixture child.
- The exit event follows the child's final drained terminal output.
- Headless output is continuously drained with bounded backlog.
- A slow client loses its lease without blocking the child's output.
- Invalid cwd/argv launch nothing; a second host cannot replace the first host's socket.

Tests use private temporary directories and synthetic terminal children, with no microphone, model requests, Accessibility, or real Pi transcripts. Test-owned children are stopped/reaped before the test host is terminated. They do not terminate any live Axo/Pi or existing multiplexer server.

## Try a shell manually

From this directory, in a disposable terminal:

```sh
cargo build --offline
POC_ROOT=$(mktemp -d /tmp/axo-host-poc.XXXXXX)
target/debug/axo-host-poc serve "$POC_ROOT/host.sock" &
POC_HOST_PID=$!
```

Create a terminal; this uses an argv vector, not concatenated shell source:

```sh
SESSION_ID=$(python3 client.py --socket "$POC_ROOT/host.sock" create --cwd "$PWD" -- /bin/zsh -l \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["session"]["id"])')
python3 client.py --socket "$POC_ROOT/host.sock" attach "$SESSION_ID"
```

**Ctrl-] detaches.** Attach again with the same command: the existing shell remains. Normal Ctrl-C is forwarded to that shell's PTY; it does not mean detach. Resize follows the attached terminal. The client restores its terminal mode on ordinary return/error; killing an interactive raw-mode client may require `reset` in that disposable terminal.

List/stop only this POC's terminals:

```sh
python3 client.py --socket "$POC_ROOT/host.sock" list
python3 client.py --socket "$POC_ROOT/host.sock" stop "$SESSION_ID"
# Verify the listed process has exited before terminating this POC host.
python3 client.py --socket "$POC_ROOT/host.sock" list
kill "$POC_HOST_PID"
```

Stop every POC session you created before ending the host. The POC does not implement automatic crash/orphan recovery or a production service shutdown policy. It deliberately refuses to unlink an existing socket: use a new private directory for a new run rather than guessing that an old owner is dead. No login item is registered.

## Implementation boundaries and limits

- `src/pty.rs`: native `forkpty`, argv/environment preparation, nonblocking host endpoint, terminal resize. The post-fork child uses libc calls and `execve`/`_exit`, not Rust allocations/locks. Inherited `AXO_*` binding configuration is removed.
- `src/main.rs`: process/attachment ownership, bounded wire parsing and output, private socket and same-user admission, explicit stop and locked child reaping.
- `client.py`: disposable terminal transport, not the eventual Swift/Ghostty frontend.
- `fixture.py` / `test_detach.py`: isolated real-child acceptance checks, not Pi lifecycle observations.

POC ceilings: 8 session records, 16 client connections, 64-KiB control frames, 4096-byte input requests, 16-KiB raw backlog per terminal, and 32 queued output/control events per client. Output chunks are at most 1024 bytes; slow writes have a timeout and disconnect. Exact accepted input byte counts are returned; partial/uncertain input is not automatically replayed. One interactive attachment owns input/resize. This is same-user routing, not a sandbox against malicious local code.

## Not proven or implemented

This is **process/byte-stream continuity**, not complete terminal-state recovery. A truncated raw backlog can begin inside a VT sequence and cannot reproduce arbitrary alternate-screen, scrollback, modes, hyperlinks, or images. Terminal snapshots/replay and Ghostty feature negotiation need the next integration slice.

Also absent: real Pi admission/history/steering acceptance, durable workspace registry compatibility, phone routing, host/runtime-generation protocol, create idempotency, comprehensive descendant/job-control shutdown, orphan recovery, notifications, startup registration, and signed helper packaging. Stop currently targets the initial process group; shell jobs can form additional groups. Do not use this POC as an unattended production host.

The POC is not wired into `AxoMac`, `AxoPhone`, or `dist/Axo.app`. A successful POC test is not evidence that the running app or phone has this behavior.

## Prior art inspected

- Zellij at `333d7898a840314e41d3cc9d2a264a1b9732bb7b`: Rust server ownership, separate detach/kill instructions, bounded slow-client output buffering.
- cmux at `1308c8e3466a9e97325c0a16b1a14261926c8282`: Swift/AppKit frontend and Rust PTY/terminal/protocol components, including snapshot/replay contracts. Its tmux persistence profile is not Axo's selected backend.

These inform design, not copied implementation. Resolve component/file-specific licenses before any future reuse; cmux's root and Rust workspace advertise different license scopes.
