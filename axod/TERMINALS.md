# Local terminal attachment plane

The host owns Pi/shell processes, PTYs and continuous output draining. A renderer
owns a presentation lease, never launch or stop authority. Terminal bytes do not
enter control RPC, the cloud relay or phone history.

## Implemented transport slice

`axod serve` and `serve-user` publish a separate owner-only,
single-link `terminal-endpoint.json`, using the same boot-fenced discovery envelope
as control discovery. Its numeric-loopback WebSocket endpoint has its own port,
listener and 32-client budget; its only path is `/v1/terminal`. Control remains at
`local-endpoint.json` → `/v1/rpc`. A browser Origin, mismatched Host, query or
cross-plane path is rejected. These guards **are not same-user authentication**;
this slice does not introduce local credentials or another cloud auth system.

The closed Rust wire codec is in `src/terminal_transport.rs`. Version 1 uses
snake_case fields and a `type` discriminator. It is a distinct data-plane
protocol, not additional `axo.*` methods. It accepts no cwd, argv, profiles,
launch, stop, work creation or chat commands.

1. The first message is `attach` with `version: 1`, `machine_id`, and an exact
   `runtime` (`host_generation`, session/pane target and `runtime_generation`).
   The server allocates the connection's internal client identity and a new
   attachment identity. The Manager validates the running/draining runtime and
   permits only one attached client. Another client receives `already_attached`;
   it does not clone work or silently take over.
2. `attached` returns the captured machine/attachment/runtime observation and
   **raw** backlog with start/next offsets and explicit truncation. Backlog is
   ordered before live output under the Manager's output lock.
3. `output` carries the exact attachment, byte offset and byte array. After
   consuming output, a client sends `acknowledge` with that attachment and an
   exact outstanding `next_offset`. It may cumulatively acknowledge earlier
   frames. Unknown/future/already-acknowledged offsets are rejected.
4. `input` carries the attachment, a connection-local sequence starting at zero,
   and 1–4096 bytes. `input_applied` reports the accepted byte count. Only an
   explicitly reported unaccepted suffix may be submitted as a new sequence.
   A duplicate sequence rejects before another PTY write. Missing delivery is
   **unknown**, not permission to replay on a new connection. Terminal input
   sequences are not durable command receipts.
5. `resize` validates both axes in 1–500 and returns `resized`. Only the current
   exact attachment owner can change input/size. Stale/cross-runtime attachment
   commands close that connection without retargeting.
6. `detach`, socket loss, failed delivery, consumer overflow and client teardown
   release only presentation. None signals or stops the host child. `exited`
   reports process wait status after output drain; it is **not** proof of durable
   completion, descendant containment, permission to resume or a stop receipt.

### Bounds and failure behavior

- Native upgrade: 8 KiB header and absolute 2-second deadline; initial attach
  must arrive within 2 seconds.
- Incoming/outgoing WebSocket messages: 48 KiB encoded; native library framing.
- Per-client producer queue: 32 frames, each live output chunk at most 1024 raw
  bytes; initial backlog at most 8 KiB. The bounded delivery queue coalesces only
  adjacent output with the same captured attachment and contiguous offsets, up to
  that 1024-byte limit. PTY read fragmentation is not frame pressure. Identity,
  offset gaps and Attached/Exited control boundaries are never merged; failed
  capacity insertion cannot mutate a queued prefix. Receiver locks are released
  before network/TTY I/O. A full queue still loses only presentation.
- Delivery credits: at most 32 outstanding data frames / 128 KiB encoded, with
  worst-case frame reservation. Clients must acknowledge only consumed data.
- Writes: 500 ms socket timeout. The server polls reads every 10 ms and limits
  commands to 1000/s. A stalled/over-limit connection is disposable.
- The Manager continues draining when the renderer cannot keep up. A full
  producer queue detaches that consumer instead of blocking a child. Control
  RPC has independent listener/client limits.
- Payload bodies, terminal bytes and input are never emitted in diagnostics.
  Parse/delivery failures have closed body-free failure classes, and teardown is owner-fenced. A WebSocket presentation close poisons the client without clearing uncertainty or replaying input; it is not malformed output or completion.

## Typed native consumer

`terminal_client::TerminalClient` uses the same closed Rust codec, a captured
machine/runtime and private terminal discovery. Its upgrade/initial attachment
has an absolute deadline; streaming reads are bounded polls. It validates every
attachment and contiguous output offset, enforces consumer delivery credits,
and returns opaque payload chunks without diagnostic formatting. A chunk can
be acknowledged only for its issuing attachment after consumption.

Only one input packet and one resize may be pending. Input receipts must match
the exact sequence and byte count; resize receipts must match the submitted
size. Missing receipts expire to unknown, poison the connection and never
reconnect/replay automatically. Dropping/detaching the consumer releases only
presentation. Initial bytes are explicitly raw backlog, not recovered VT state.

## Transport-only frontend child

The bundled helper exposes:

```text
axod terminal-attach /absolute/private/state-directory machine-id host-generation session-id pane-id runtime-generation
```

All identities are parsed into native domain types. This mode cannot create,
launch, resume or stop work. It requires a frontend TTY, captures/restores its
termios, forwards raw input without outer echo or signal-character handling,
tracks frontend geometry, and acknowledges output only after bounded TTY writes.
Only explicitly acknowledged unaccepted input suffixes may use a new sequence.
SIGTERM/INT/HUP and TTY/transport loss close the presentation lease, not the
managed process/group. An exit event is not a durable completion receipt.

This is a **basic stream attachment seam**, not screen restoration. Truncated
backlog is refused with a static recovery-unavailable error while preserving
work. Non-truncated raw bytes also do not prove restored historical geometry or
full VT state. There is no automatic reconnect/input replay. The Mac target now
uses the full pinned Ghostty surface with this transport child; truthful recovery
and actual workbench acceptance must still be implemented and validated.

## Evidence and remaining gates

Six isolated Rust tests exercise real native PTYs over both production local
listeners: input, resize, detach/reconnect, stale identities, sibling survival,
EOF ordering, private discovery, browser/cross-plane rejection, slow-reader
lease loss with continued work/control availability, closed parsing and credits.
The typed consumer additionally passes three pure state/receipt/credit tests.
Two actual-binary frontend tests wrap the helper in a separate owned native PTY
and reach the real daemon through its terminal plane: Unicode input, real inner
PTY resize, frontend termination with continued single managed runtime, and
truncated-replay refusal without stopping work. This is not a Ghostty surface.
These are **transport/PTY fixtures**, not native Ghostty, IME, images, actual
workbench, deployed-route or physical-phone acceptance.

`bash scripts/check-ghostty-vt-snapshot.sh` characterizes the public VT C API at
pinned Ghostty `7ec9e26a29399b30ef78f06985fc75045b3cecb6`. It restores unfinished
escape/UTF-8 input and alternate/hidden-primary screen content, rejects
corrupt/truncated snapshots, and enforces caller output-buffer bounds. It also
checks only the **text** result of styled VT replay. The fixture does not prove
a bounded decoder allocator, complete styled replay, graphics, native rendering
or ABI compatibility of separately built artifacts.

The public GhosttyKit surface API creates its own command; it has no direct
external-PTY/snapshot-adoption entry point. RFD0007 explicitly permits a
transport-only attachment child. The Mac `TerminalLaunch` can construct only the
captured bundled `terminal-attach` command. The surface cache is keyed by machine,
host, session, pane and runtime generation; a second simultaneous viewport is
rejected rather than silently transferring ownership or duplicating work.
`bash scripts/check-mac-terminal.sh` exercises an owned offscreen surface/cache,
modifier-only events and IME preedit, missing-discovery failure, URL parsing and
disposal. Its Rust-owned actual CLI/daemon/full-Ghostty fixture also verifies
Unicode input/output, eventual geometry and the exact unchanged running runtime
after disposal. This is **native component evidence**, not actual workbench,
real IME composition, graphics or restoration acceptance. Ghostty applies its
outer-PTY resize asynchronously; native resize dispatch is not an ordering barrier
for the following input. See [exact checkpoint evidence](../docs/implementation/evidence/native-ghostty-attachment.md).
Do not modify ignored Ghostty sources or launch another Pi to obtain a second view.

**Screen recovery remains missing.** Raw backlog, even when not truncated, is
not a complete VT snapshot (historical geometry/parser state also matters).
The VT snapshot API is a promising primitive, not a deployed recovery strategy.
GhosttyKit cannot directly adopt that binary snapshot, and styled active-screen
replay is not yet proven equivalent for hidden screens, input modes, unfinished
sequences, scrollback or Kitty graphics. A renderer must not silently label a
lossy reconstruction as restored. Snapshot/live boundary handling, native
resize/focus lifecycle, real IME, graphics, headless feature-query behavior and
actual session workbench acceptance remain open inventory gates.
