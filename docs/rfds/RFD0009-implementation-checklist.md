# RFD0009 implementation ledger

Scope: implement [RFD0009](RFD0009-protocol-capability-parity.md) in dependency order, including its selected protocol domains and native integration. This ledger tracks engineering work; the RFD remains the authority for rationale and acceptance boundaries. A checked item is not permission for live cutover, startup registration, file-authority migration or live Mac/phone restart.

## 1. Work records and reconciliation — isolated implementation complete

- [x] Choose a private daemon-owned record store, opened under the existing exclusive state-directory lock. Do not write/import the live Mac registry.
- [x] Stable workspace/session/Pi-pane identities; creation commits metadata only. No canonical Pi chat is invented before admission.
- [x] Implement `axo.workspace.list/create/rename`, `axo.session.list/get/create/rename` and read-only `axo.command.get`.
- [x] Compile request/result validators and generated schemas into `@axo/protocol`; use the API's existing bounded forwarder rather than adding another execution owner.
- [x] Operator-approved `directoryId`, no caller cwd/argv. In this slice it selects a configured profile's directory only; creating a workspace neither launches that profile nor creates an initial session.
- [x] One global work-record revision; immutable normalized-intent receipts; atomic record/receipt commit; private bounded storage; fail closed on corrupt/unreceipted metadata.
- [x] Page cursors fence machine/boot source, revision, domain and workspace filter. No cached catalog or implicit fallback.
- [x] Serialize execution/work command admission; reject cross-journal identity reuse. Uncertain persistence in either store fences mutations in both domains while preserving accepted children.
- [x] Real local/Worker/daemon route tests for every new method, metadata-only creation, notifications, stale destinations/cursors, rename protection, restart durability, original receipts and historical runtime observations.

Evidence: `axod/src/work.rs`, `work_rpc.rs`, `work_lifecycle_tests.rs`; `protocol/src/work-contracts.ts` and `protocol/tests/work.test.ts`; `sites/api.axo.leostera.dev/tests/work.test.ts`. Initial record-store checkpoint: 35 Rust tests, 10 protocol/package tests and 26 API/local/fleet tests; strict Clippy, release build, schema check, API typecheck/build. All fixture daemons are owned/disposable and stopped by teardown. No real Pi, native app, physical phone or deployed Worker adoption is established by this evidence.

### Exposed-RPC coverage checkpoint

`tests/daemon-rpc.test.ts` and its owned real-daemon fixture now cover every shared exposed RPC on both routes, with a typed method-input matrix that must grow when `RemoteMethod` grows. Coverage includes malformed/extra/positional input, stale machine/source, notifications, concurrent hop/command conflicts, revision arbitration, storage failure fencing, nullable/default paging rules, explicit null request IDs and 50-record Unicode pages. RFD methods not implemented yet explicitly reject; this is not positive Pi/tool acceptance.

This caught and fixed a real route mismatch: Rust's ordinary optional deserialization accepted explicit null request fields that the shared schema rejected. Omitted fields still default, and genuinely nullable all-workspace cursor scopes remain valid. Full validation: 36 Rust tests, 10 protocol/package tests and 58 API tests (including named subtests), strict Clippy, release build, schema check and API typecheck. Run the dedicated daemon suite with `npm --prefix sites/api.axo.leostera.dev run test:axod`; see `axod/tests/README.md` for coverage boundaries.

### First bounded hardening checkpoint

- [x] Add replayable `fast-check` differential fuzz/property tests against a development-only, mutation-forbidden oracle calling production Rust codec/read admission. Retain synthetic edge regressions and metadata-only failure diagnostics.
- [x] Add Rust `proptest` receipt state machines, exact numeric/frame/reply properties, exhaustive synthetic-store truncation and commit-window faults before sync/rename and after rename.
- [x] Fix observed route/profile disagreements: UTF-16 string limits, finite/scalar/depth-bounded JSON, exact floating-point round trips, integral numeric spellings, strict case-insensitive RFC UUID text, loss of prototype-like dictionary keys and cursor-domain/revision guards. Post-dispatch response failures preserve request IDs/batch shape, including inadmissible serialized replies.
- [x] Exercise selected findings on both actual local/cloud sockets with unchanged work records and no launches. Distinguish lock contention from corrupt state in ownership tests; bounded fixture-only lock waits do not introduce command retries.

Evidence: `axod/src/{rpc,work}_property_tests.rs`, `axod/examples/rpc-oracle.rs`, `protocol/tests/property.test.ts` and the hardening corpus in `tests/daemon-rpc.test.ts`. Validation: 45 Rust tests, 14 protocol/package tests, 41 dedicated daemon tests/subtests and 59 full API tests/subtests (full run with file concurrency 1); strict Clippy, release build, schema/API typecheck/build. Three additional Rust property-suite runs passed. See `axod/tests/README.md` for replay commands and coverage boundaries.

This does **not** establish power-loss/fsync durability, abrupt-death/spawn-window recovery, escaped-descendant containment, coverage-guided fuzz completeness, production supervision/retention/rollback, native/Pi acceptance or resolution of every earlier contention stall. Injected failure and same-kernel reopen are distinct from actual crash/power-loss evidence. No live state, native ownership or deployment was changed.

## 2. Contract transition and real vanilla Pi ownership — next

### Ambient dependency discovery retained; headless detour removed

- [x] Capture ambient `pi` from operator PATH/absolute selection, ignoring npm-injected development bins; no repository/bundled runtime, installation or fallback. Bound/sanitize version probes. Version metadata is not a capability/readiness claim.
- [x] Remove the unused Pi `--mode rpc` controller and its execution/provider/transport fixtures. There is no selected product use case for a separate headless Pi mode.

Evidence retained: `axod/pi/ambient.ts`, `axod/tests/pi/ambient.test.ts`; `npm run test:pi-discovery` checks six dependency policy cases with owned probe fixtures. This is **not actual Pi execution/admission or public-RPC acceptance**. No RPC-specific minimum version is imposed by discovery; actual extension capability checks belong to admission.

Historical `c8f72f9` characterized headless Pi RPC, but bypassed the intended Rust-daemon/PTY/TUI-extension path. Its idle-steering, abort-queue and RPC-dialog observations must be revalidated against the public APIs of the interactive extension; they do not prove TUI controls or generic approval parity. The removed tests are not current product coverage. See `axod/pi/README.md` for the intended path.

### Actual interactive PTY foundation

- [x] Production Rust native PTY/manager/journal controlled launch with an owner-only anonymous fd-3 socket, unrelated descriptor closure and immutable controlled-versus-ordinary launch intent.
- [x] Pi-loaded TypeScript extension in `pi-axo/`, using public APIs inside actual ambient interactive Pi; no separate engine, terminal parsing or transcript writer.
- [x] 24 combined real TUI/native-PTY tests: readiness/TTY/PID, actual tools/history, steering/cancel/dialogs, detach/resize, exact resume, independent sessions, stale/concurrent/invalid controls, provider/input-hook failures, stop/shutdown and tool-child fd exclusion.

Evidence: `npm run test:pi-interactive`; 24-case run passed after extension relocation, with the preceding 23-case suite passing twice consecutively. Rust domain/process/relay regressions: 47 tests; dedicated daemon local/cloud regressions: 41 tests/subtests. The battery uses a test-only process adapter around the **production Manager**, not yet public WebSocket Pi controls or a product CLI. Its TypeScript orchestration and Python generic process fixtures are transitional; move daemon/CLI orchestration and child fixtures to Rust. Fixture resume policy and per-pane writer exclusion do not prove production canonical binding/writer admission. Interactive abort removes queued steering from execution, unlike the discarded headless observations; an actual consumed input-hook dispatch is conservatively fenced, never fabricated execution or replay.

- [x] Add a small actual Rust CLI using the same addressed local public Axo WebSocket RPC as native clients; no direct Pi RPC shortcut. `axo rpc DISCOVERY METHOD` reads bounded params from stdin, negotiates/ACKs, preserves destinations and never retries execution. Cloud CLI support remains separate.

Rust-only checkpoints: `src/client.rs`, `src/bin/axo.rs`, `src/ambient_pi.rs`, typed `src/pi_control{,/wire}.rs`, `tests/public_cli.rs`, `tests/interactive_pi.rs`. Owned IPC deserializes into closed request/record/response types with request-kind correlation, distinct identity types and typed operations; no `Value` key routing. Pi-owned document payloads are explicitly opaque `RawValue`, not protocol discriminators. Validation: 60 Rust tests plus 24 transitional actual-TUI tests; fmt/Clippy/typechecks. At `ad544d2` these were **separate** paths; the combined checkpoint below supersedes that limitation.
- [x] Use that CLI in owned real-`axod` integration tests: explicit session start launches ambient Pi's interactive TUI in a native PTY, with a managed Axo extension controlling **that same Pi process**. Exercise real messages/tools, steering/cancel/history/exact resume, not terminal-text parsing or a fake agent harness.

### Joined production public Pi checkpoint

`axo.session.start` plus eight `axo.chat.*` methods now use the shared Rust dispatcher on both routes (19 exposed daemon methods). Explicit private Pi policy selects the approved directory, session root and installed extension; callers never supply cwd/argv. Private `pi-state.json` stores metadata/fingerprints/original dispositions, not prompts/history. Captured identities include current host and the original runtime host generation. Startup validates receipts/bindings/work membership and cross-domain collisions; persistence uncertainty fences work/runtime/Pi mutations, not accepted work.

`tests/managed_public.rs` owns actual `axo`/`axod serve`, ambient TUI and Rust model fixture: real bash/canonical branch/history/tool detail, original command reconciliation, owned question/option answering, viewing expiry without renewal, explicit steering/cancel/late rejection, clean restart/stopped reads/exact resume, stale destinations and real input-hook consumed-dispatch uncertainty. A Rust-owned cloud peer through the actual isolated Worker/Access fixture admits an independent Pi and verifies a real tool effect; cloud/client loss preserves accepted Pi. Node hosts only Worker/workerd, with private synthetic assertions and pinned owned-process-group cleanup. The protocol matrix guards all new mutation notifications and bounded targets/cursors/tool IDs/text on both routes.

Six managed store/lease/tree/cross-domain unit tests exercise hash normalization, original dispositions, truncation/corruption, persistence fences, cooperative writer exclusion and active-branch reconstruction. Same-kernel reopen and graceful restart are not abrupt crash/power-loss proof. See `axod/MANAGED_PI.md` for setup, bounds and limitations. The remaining 24-case orchestration/Python fixtures have not yet migrated to Rust. No Mac, live registry or deployment adoption occurred. An actual running PTY is required; a Mac window is not.

Final checkpoint validation: **67 Rust tests** (59 library + 8 integration), **18 protocol tests** including replayable differential properties, **60 serial daemon local/cloud tests/subtests**, **24 transitional actual-TUI cases** and **6 discovery cases** passed. Strict all-target Clippy, fmt, release build, schema check, root/Pi/API typechecks and API source build passed. The complete service/native/device suites and live deployment are not claimed by these runs.

- [ ] Apply the `axo._.*` namespace coherently across Rust, TypeScript, Swift models/validators and isolated callers. Decide whether to delete the generic-launch helper or retain it behind explicit development policy; no old-name aliases.
- [ ] Make support advertisement distinguish adapter/route support from daemon support and actual Pi admission/readiness.
- [ ] Define managed-runtime caller provenance independently of method spelling or claimed JSON identities. A daemon-owned inherited control channel is a candidate; do not add local credential/account machinery or restore a legacy-envelope listener.
- [x] Implement approved `axo.session.start` fresh/exact-resume intents and durable spawn receipts; bind persistence only through actual public Pi session APIs. Never adopt live unmanaged sessions implicitly.
- [x] Admit a real vanilla Pi extension, with exact session/pane/runtime/host and canonical chat/file identity. Do not derive identity from PTY text or manufacture JSONL.
- [ ] Prove one managed writer per persistence binding; distinguish spawn, admission, stopped, failed and recovery-required. No automatic restart/replay.
- [x] Validate interactive Pi TUI behavior in the daemon-owned PTY with no attached Mac viewport before claiming no-window readiness; disclose unsupported public UI waits. No-window operation does not mean Pi RPC mode.
- [ ] Exercise two actual independently addressed Pi sessions, disconnect/reconnect, exact resume, stale generation, startup failure and crash windows. Controlled public providers/tools are acceptable evidence for actual Pi execution, not substitutes for the Pi harness.

## 3. Chat reads and bounded observation

- [ ] `axo.chat.get/history/getToolOutput`, using canonical public Pi entry/branch identity, compaction/tree-aware projections and demand-driven tool detail.
- [ ] Active-view epochs and source-bound bidirectional history cursors; explicit stopped-history policy; UTF-8 encoded-byte bounds and continuation/truncation fixtures.
- [ ] `axo.observe.subscribe/unsubscribe/event`, bounded producer/client state, baselines, expiry, sequence gaps and read-only resynchronization.
- [ ] Public Pi lifecycle/assistant/thinking/tool/model/provider/UI-wait observations, without claiming remotely answerable generic approvals.
- [x] `axo.chat.setViewing`: scoped expiring viewing leases, independent from subscription ownership.
- [ ] Decide opt-in bounded offline metadata replication and `axo._.catalog.publish`; any cached reads remain domain reads with explicit freshness/source policy, never public catalog-list aliases or history uploads.

## 4. Addressed chat controls

- [x] `axo.chat.sendMessage`: ready/idle normal text intent; reject busy/question-blocked state without steering conversion.
- [x] `axo.chat.sendSteeringMessage`: captured active interaction; reject ended/idle state without starting a new interaction.
- [ ] Attachments prepared under captured targets and current existing file authority; revalidate after awaits; attachment-only messages supported.
- [ ] Durable normalized message disposition/evidence, pre/post-dispatch crash drills and truthful unknown outcome; no prompt bodies in diagnostics/runtime journal, no automatic replay or competing queue.
- [ ] `axo.chat.answerQuestion`: actual Axo-owned question/options, pending recovery, stale/duplicate rejection and no cancellation-as-approval.
- [ ] `axo.chat.cancelTurn`: public Pi abort of the captured active user interaction, settlement separate from acceptance, sibling isolation.
- [ ] `axo.runtime.stop` and local explicit `axo.runtime.daemon.stop`, with observed completion and no historical-PID signaling.

## 5. Remaining work records and local terminal plane

- [ ] Workspace/session archive and duplicate: preserve originals; fresh independent work/chat identities; reject copying live writers. Decide remote exposure explicitly.
- [x] Initial local-only `axo.session.pane.add/remove` per the operator's Cmd+D / Cmd+Shift+D / Cmd+W semantics: add explicitly creates/launches a fresh approved shell PTY; remove explicitly terminates the exact captured owned runtime and records a tombstone only with durable completion evidence. No create/start aliases; geometry remains native. Actual CLI/daemon acceptance verifies TTY effects, siblings, original receipts, stale/replacement rejection, clean restart/no replay and historical stopped removal. Five store/admission tests cover proof/collision/fencing/corruption. Native attachment, public data plane, escaped job-control groups and crash/operational gates remain open; see `axod/PANES.md`.
Shell-pane checkpoint validation: **73 Rust tests** (64 library + 9 integration), **21 protocol tests** and **61 serial daemon local/cloud tests/subtests** passed, plus strict Clippy/fmt/release and root/API typechecks. An initial whole-route run stalled/timed out; the isolated 40-case matrix then passed. A subsequent full run exposed an existing invalid equality assertion between sequential live `backlog_bytes` snapshots; it now compares stable routing/process identities while the schema enforces byte bounds. The next full serial run passed. This does not establish the earlier contention stall's root cause or native/operational readiness.

- [ ] Local terminal attach/detach/resize contracts and separate bounded input/output channel. No control-frame terminal bytes or phone raw terminals.
- [ ] Pinned Ghostty attachment, feature negotiation and truthful terminal-state recovery; validate real TUI, images, IME, paste, resize and detach/reconnect during work. Raw backlog is not a screen snapshot.

## 6. Native integration, files and operations

- [ ] Shared `AxoProtocol` wire models and method validators; reuse `AxoCore` RPC client; private discovery validation and captured destinations after waits.
- [ ] Isolated native browsing first, then chat and attention/title/notification behavior; no fallback to another execution owner.
- [ ] Characterize registry handoff/import/rollback with preserved identities/manual names/archive originals; choose one writer before enabling live mutation.
- [ ] Characterize existing file namespace (Pi chat, not Axo work session), machine/chat authorization and deletion races. Preserve FileIndex/R2/direct transfer ownership until its independent gate passes.
- [ ] Source/build/unit/cross-language and signed atomic Mac packaging evidence for affected native/bridge changes.
- [ ] No-window actual Pi work, client quit/reopen, cloud outage/expiry, orphan recovery, shell descendants, retention, upgrades and rollback.
- [ ] Human/native/physical-phone acceptance drills remain explicit evidence, not fixture-test claims.
- [ ] Obtain separate consent for live registry/file ownership cutover, startup registration, deployed-route changes where needed, and live app/phone installation or restart. Do not stop unrelated accepted work.

Search/FFF/palette, new account/auth/enrollment machinery, cloud execution and offline execution queues are outside this implementation scope. Local voice, drafts and split layout remain native-local behavior, not new cloud subsystems.
