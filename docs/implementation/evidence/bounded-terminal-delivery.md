# Bounded terminal-delivery checkpoint

**Component hardening, not complete native-workbench acceptance. No supported workflow gate is closed.**

## Versions

- Coalescing, bounded campaign and body-free diagnostics: `8341f4e1fa96757f614b2f5f5d8aa0d1c5540c57`.
- Precise first-loss classification: `378b2bf5c7816f26277b09d70e5e29475b6eb221`.
- Delivered **`dist/Axo.app` build131**, `AxoBuildCommit` exactly `378b2bf5c7816f26277b09d70e5e29475b6eb221`; bundled helper **`0.1.0 (378b2bf5)`**. Deep strict signature verification passes; atomic packaging retains the previous signed bundle.
- The live helper was not restarted or upgraded. Its last read-only observation remains `0.1.0 (23be4c99)`, five recovery-required runtimes and eleven not-admitted standalone sessions. No live replay, signal, deletion, preference/history mutation, API deployment or phone installation occurred.

## Reproduction and qualification

The [build128 checkpoint](native-workbench-fixture.md) retained intermittent native shell input-effect failures. Fresh-root campaigns reproduced them: frontend exit while work remained running, initially a protocol class and later a WebSocket close accompanied by the server's aggregate `QueueCapacity` label. No input was resent in those terminals.

That historical label was too broad: the old disconnected flag represented producer overflow **or output failure**. It does not prove that every historical failure had one cause. The implementation now records a closed first-loss reason: `QueueCapacity`, `InvalidFrame`, `OutputFailed` or `ReceiverReleased`; later teardown cannot overwrite it. Client protocol failures likewise have closed payload-free locations, and a presentation close is distinct from malformed protocol data. It still poisons the connection and never authorizes input replay.

An independently reproducible source flaw was found: the producer counted individual PTY reads as queue frames. Small fragments could exhaust the 32-frame queue without a correspondingly large byte backlog. The deterministic regression queues 1,500 one-byte fragments into a two-frame sink and verifies exact delivery in two bounded chunks. The old per-read queue could not satisfy this invariant.

## Corrective delivery model

`runtime/delivery.rs` replaces the raw synchronous channel at all Manager attachment consumers; no compatibility producer path remains. Its bounded queue:

- Coalesces only adjacent output with the exact same attachment and contiguous offsets, up to **1,024 raw bytes per live frame**.
- Preserves the **32-frame** maximum and **8-KiB** initial backlog, existing wire credits and ordering. It never merges identities, offset gaps or Attached/Exited control boundaries.
- Rejects an insertion atomically when capacity is exhausted; a queued prefix is not partially changed. Oversized/overflowing output fails closed.
- Releases its short in-memory lock before network/TTY I/O. Slow-reader overflow still detaches only presentation while the daemon keeps draining and control remains usable.
- Wakes readers on last-sender/receiver loss and retains the original loss reason. No process signal, work mutation, durable completion or command replay authority exists in this queue.

The native fixture can repeat **1–20** rounds with `AXO_NATIVE_WORKBENCH_REPETITIONS`; every scenario uses a new private Rust-owned daemon/HOME. Compile-only native stderr capture and the owned daemon stderr file retain body-free errors outside the rendered screen. Failure reports read bounded prefixes and emit only allowlisted classes/flags/counts, not terminal/error bodies. These seams are absent from the shipped app.

## Validation

- Full Rust serial suite: **104 library cases**, interactive Pi 1, local sessions 2, managed-public 1, public CLI 8, relay-config 4; no failures/ignored cases. Five new deterministic delivery cases cover fragments, exact bytes/offsets, all-or-nothing overflow, identity/control boundaries, closed lifetimes and invalid bounds. First-loss reason checks distinguish output failure and receiver loss from capacity.
- All-target clippy `-D warnings`, fmt and diff checks pass.
- Actual ambient Pi: **24 interactive cases** and **6 discovery cases**, all passing/no skips. Pi remains vanilla **1.1.0**, owns execution/history, and is not bundled or replaced.
- Protocol TS **25 passes/no skips**; protocol/API property suites pass. Swift protocol **41 cases/one existing relay-environment skip**, no failures. That skip is not acceptance evidence. Mac compiles; client hint checks pass.
- A post-coalescing debug-helper campaign completed **20 rounds / 80 fresh-root native scenarios**: delayed Pi, unavailable Pi with usable shell, genuinely-empty automatic creation and opaque pending-hint blocking; selection/reconnect/later-launch and disposal preserve exact work/runtime counts.
- **Exact build131 helper and packaged adapter:** another **20 rounds / 80 scenarios** pass, overlapping the packaged CLI/Core lane in separate roots. Packaged public CLI **8**, AxoCore **81/no skips**, and the full Ghostty Unicode/geometry/non-destructive-disposal component checks pass.

These bounded passing campaigns support the specific correction; they are not an exhaustive soak, proof that all historical failures had the same cause, or closure of the broader actual-surface robustness gate. Historical failed logs remain evidence.

## Remaining acceptance

Finder/ServiceManagement startup, safe live recovery and helper handoff, actual project picker, real keyboard/IME/focus/paste/drop, Pi question waiting, independent windows, full VT/graphics/scrollback recovery and current deployed/physical-phone routes remain open. The live namespace must not be reset to manufacture an empty-app test. Retained surfaces and raw bytes are not complete visible-state recovery. See the [supported inventory](../supported-workflow-inventory.md).

Logs: `/tmp/axo-workbench-128-campaign.log`, `/tmp/axo-native-{classification,exit,stderr,close,server}-campaign.log` retain pre-correction campaigns; `/tmp/axo-delivery-{unit,native-campaign,rust,loss-tests,clippy,pi,discovery,swift,mac,client,ts,protocol-properties,api-properties,package}.log`; exact package `/tmp/axo-delivery-131-{native,terminal,cli,core}.log`.
