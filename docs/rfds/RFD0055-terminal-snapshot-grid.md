# RFD0055 - Axo: terminal snapshot grid metadata

- Feature Name: `terminal-snapshot-grid`
- Status: Implemented (experimental candidate; paired runtime not deployed)
- Author: leostera
- Start Date: 2026-11-14
- Updated: 2026-11-15
- Document Type: Proposal
- Amends: [RFD0054](RFD0054-linux-desktop.md) (replay bootstrap contract)

## Summary

Add opt-in attach protocol v3, shared by all clients, carrying the exact grid used to create the replay. Keep the shipped v2 byte stream unchanged for existing Mac/peer clients. A new prepared-replay client requires v3 and never silently guesses a grid or falls back to a standalone shell.

## Motivation

Protocol v2 sends a replay length and PTY descriptor, not snapshot dimensions. Reading TIOCGWINSZ afterwards is not a proof of the replay's grid: another client can resize the PTY between server snapshot capture and descriptor receipt. Even checking twice cannot detect a change before the first read. Parsing a wide snapshot into a narrow initial viewport can wrap and overwrite characters irreversibly. This is a transport metadata gap, not a Linux renderer policy.

## Guide-level explanation

A v3 client writes `3:105\n`. The daemon requests the current PTY grid, then captures the actual VT grid and replay together through `TerminalOutput::subscribe_captured`. A successful reply contains:

1. Replay length: eight-byte big-endian u64, excluding the metadata below.
2. Snapshot rows and columns: two positive big-endian u16 values, in that order.
3. Existing one-byte `1` plus exactly one SCM_RIGHTS PTY master.
4. Exactly the announced replay bytes, then live bytes until EOF.

The client reads/bounds the initial replay off the GUI thread. Ghostty initializes at the supplied grid and parses the replay before live I/O or a viewport resize can change it. Only then does the GTK view apply its actual viewport. The client never reads output from the PTY master.

A v2 client still writes `105\n` and receives the original length/descriptor/replay sequence with no new bytes. Rejections retain the existing u64::MAX plus one-byte code in both versions. Unknown/malformed requests fail before attaching.

## Reference-level explanation

- `axo-pty::attach` owns versioned request parsing, bounded descriptor receipt, grid parsing and prepared replay ownership. `axo-server::attachments` chooses the reply version from the request, not an environment variable or OS.
- The v3 grid comes from the VT that actually serialized the replay, under the same output-state lock. It is not a second ioctl after subscription, nor an assumption that the requested VT resize succeeded. An unavailable/failed empty snapshot has no grid: reject v3 rather than fabricate one. Legacy v2 keeps its existing empty-stream degradation.
- The prepared type owns the output socket, master, immutable replay and captured grid. Bound allocation by `MAX_TERMINAL_REPLAY_BYTES`; use an absolute read deadline for initial replay; preserve EOF and descriptor cleanup semantics. Native widget ownership retains this value until native finalization.
- v3 requires a matching candidate/newer daemon. An older daemon's refusal is shown explicitly. Do not interpret metadata as terminal output, probe by consuming a v2 stream ambiguously, or retry as v2 with guessed dimensions.
- This does not define a multiple-client viewport arbitration policy or make concurrent live resizes transactional. It establishes the original snapshot grid independently of later PTY changes.
- No privileged identity, question resolution or secure-input authority changes. No paired-runtime restart or deployment accompanies the implementation.

## Tests and rollout

Keep legacy acceptance/rejection tests. Add versioned parser/malformed-frame tests, v3 grid validation and replay/live boundary tests, and a deterministic race: capture a replay at one grid, change the kernel PTY size before the client receives the reply, and prove the prepared grid remains the captured value. Exercise the new renderer against an isolated real daemon; close/reopen the frontend without stopping its child. Run shared PTY tests on both Linux and Mac. The GTK spike requires v3; upgrade/deployment of the paired daemon remains a separate approved action.

## Drawbacks and alternatives

A second explicit protocol version adds a small maintenance surface, but v2 compatibility is required by shipped clients. Reading the current PTY size twice is simpler but cannot eliminate the capture/receipt race. Hiding proprietary metadata inside VT escape sequences avoids a version marker but conflates transport metadata with untrusted terminal content and relies on parser side effects; reject that approach. Replacing v2 in place would corrupt existing clients. Doing nothing leaves initial replay alignment best-effort and does not satisfy the new renderer's ownership/replay contract.
