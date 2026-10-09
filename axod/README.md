# axod

Axo's standalone per-user Rust session-manager daemon. Active implementation and hardening happen here, not in new POCs. `axod` directly owns terminal children and PTYs; no tmux, screen, or Zellij backend is used.

**Current boundary:** the Mac app remains on its existing process-ownership path while another agent updates its relay/iOS compatibility. This crate is not launched by, linked into, or packaged with the app yet. The later Mac refactor comes after daemon completion/hardening and a coordinated ownership handoff. No existing workspace registry, Pi history, relay deployment, login registration, or live process is changed by these commands.

## Build and validate

Currently macOS-only; tested using Rust 1.99.0. Run from this directory:

```sh
cargo build --locked
cargo fmt --check
cargo test --locked --offline
cargo clippy --locked --offline --all-targets -- -D warnings
python3 tests/test_daemon.py
```

Offline commands require cached dependencies. Python tests build the daemon and use owned, disposable real terminal children in private temporary directories. They are not fabricated Pi transcripts, real-provider tests, or native application acceptance.

## Run explicitly

```sh
state="$(mktemp -d /tmp/axod-local.XXXXXX)"
chmod 700 "$state"
cargo run --locked -- serve "$state"
```

`serve` runs in the foreground and creates `control.sock`, `owner.lock`, and, after a mutation, `runtime-state.json` in that directory. Keep socket paths below 91 bytes. The directory must already exist, be absolute, belong to this OS user, and deny group/other access. Socket/journal/lock files are private; symlinked journal/lock files are rejected.

Clients connect to this daemon directly through the private Unix socket. A same-user peer check is admission, **not a sandbox against code already running as this user**. There is no TCP endpoint, shell attachment CLI, native Ghostty adapter, or relay transport yet.

SIGINT/SIGTERM stop accepting launches, request termination of owned child process groups, escalate after one second, and wait boundedly for child reaping/journal completion. Disconnecting a client never requests process termination. **General shell job-control/descendant cleanup is not complete:** a shell's additional process groups or deliberately detached descendants are not covered by the initial group signal. Do not use this slice for production workloads or assume host/OS crash survival.

An existing socket is never automatically removed/replaced. A duplicate live daemon cannot acquire the directory lock. After an abrupt host crash, inspect ownership and surviving work before an operator removes a stale socket; do not automate endpoint replacement, restart uncertain children, or signal historical PIDs. Process IDs alone cannot prove ownership across daemon generations.

## Versioned local protocol

Frames are newline-delimited JSON, maximum **64 KiB including the newline**. Requests reject unknown fields. The request envelope is:

```json
{"version":1,"request_id":1,"host_generation":null,"command":{"op":"hello"}}
```

The hello response supplies the protocol version and current `host_generation`. All other commands require that generation. Responses use `{"frame":"response","request_id":1,"response":{...}}`; unsolicited events use `frame: "output"` or `"exited"` and carry the exact attachment reference.

A target always contains explicit UUID `session_id` and `pane_id`. A runtime reference adds `host_generation` and `runtime_generation`. An attachment reference adds `attachment_id`. No command uses an ambient selected session, text-derived identity, or Pi conversation guess.

Commands:

| Operation | Fields | Contract |
| --- | --- | --- |
| `hello` | none | Read current protocol/host identity. |
| `list` | optional `after` pane UUID, `limit` (default 50, 1–50) | Bounded ordered metadata page, `terminals` and `next`; never launches/restores work. Pages are current observations, not a transactional catalog snapshot. |
| `start` | `command_id`, `target`, `launch: {directory, argv}` | Explicit launch only; durable intent before spawn. Absolute cwd/executable; argv/environment prepared before fork. No shell interpolation. |
| `attach` | `runtime` | One connection-owned input/resize lease per terminal; at most one attachment per connection. Returns snapshot plus bounded raw backlog before live output. |
| `input` | `attachment`, integer-byte `data` | At most 4096 bytes; reports only bytes accepted by the PTY write, not execution or Pi submission. No implicit retry of partial writes. |
| `resize` | `attachment`, `rows`, `columns` | Connection owner and generations required; dimensions 1–500. |
| `detach` | `attachment` | Releases that lease only, including after process exit. |
| `stop` | `runtime` | Explicit owned-generation termination request, not completion confirmation. Observe process exit separately. |

Request IDs are positive and monotonically increasing per connection. Up to 64 replies/128 KiB are cached for identical retries; conflicting reuse is rejected. Evicted/lower IDs are rejected rather than executed again. This prevents duplicate input within a connection; **it does not authorize replaying input after reconnect**.

`start.command_id` is a separate durable idempotency key. Repeating it with the same target/launch reconciles the original runtime without launching again. Different arguments conflict. Known failures remain failures; known completed launches can reconcile to their original exited runtime after reboot. Superseded runtime receipts are stale. Uncertain previous work returns recovery-required. A fresh command ID is explicit new intent, not implicit restoration.

## Ownership, persistence, and bounds

- `src/model.rs`: typed UUID identities and distinct process states. `Running` means a spawned child not yet observed exited, **not admitted/ready Pi**.
- `src/pty.rs`: native `forkpty`, host-side **controller** handle, child-side exec, nonblocking I/O, resize; no Rust allocation/logging/locking in the post-fork child. Inherited `AXO_*` configuration is removed so an active parent turn cannot retarget a child.
- `src/runtime.rs`: terminal ownership, leases, continuous headless output drain, byte offsets/backlog, reaping, and generation checks. Reaped/fully drained terminals release their controller descriptors. PTYs still draining count against capacity even after their initial child exits.
- `src/journal.rs`: exclusive OS lock, bounded private versioned JSON, atomic rename/fsync, durable launch receipts, fail-closed uncertain persistence. Stores identities/process dispositions and launch fingerprints, **not argv, prompts, output, or Pi history**. This runtime journal is not a second writer to the Mac workspace registry.
- `src/server.rs`: same-user socket admission, bounded connections/queues/reply cache, version/generation fencing, metadata paging, controlled shutdown.

Limits: 128 live terminal resources, 1000 terminal records, 2000 durable start receipts, 4 MiB journal, 16 client readers, 32 queued frames/client, 1 KiB output chunks, 8 KiB raw backlog/terminal, and 500 ms socket writes. Slow consumers lose their connection/lease, not the child or headless drain. Receipt exhaustion fails closed; eviction/retention is not silently introduced.

The attach response discloses `first_offset`, `next_offset`, and whether the raw backlog is `truncated`. Snapshot/backlog and live-output handoff are serialized with terminal output. Exit events follow the final drained output.

**Raw bytes are not reconstructed terminal state.** This slice does not claim alternate-screen, cursor/modes, scrollback, feature-query, graphics/image, Unicode/IME, paste, or Ghostty reconnection fidelity. Terminal bytes remain local; they must never be placed in phone relay frames.

## Remaining implementation/hardening

1. Terminal-state ownership/snapshot/replay and headless terminal feature negotiation.
2. Real vanilla Pi launch/admission and structured extension registration; no Pi patches or transcript fabrication.
3. Complete shell job-control, descendant shutdown, unexpected I/O/reaper failures, and orphan/recovery operations, including crash drills.
4. Daemon-owned workspace/session registry compatibility and one-writer cutover/rollback; explicit launch profiles and broker/relay ownership. Do not write the current live Mac registry during standalone development.
5. Phone routing/catalog/control with no workbench process, concurrency/failure coverage, and bounded lifecycle/retention policies.
6. After daemon hardening: coordinated Mac attachment/client refactor, signing/bundling, consentful handoff, explicit host shutdown/menu-bar controls, opt-in startup, and operational acceptance.

See [RFD0007](../docs/rfds/RFD0007-mac-session-manager.md). Its startup/availability/persistence policy proposals are not silently accepted by this initial implementation.
