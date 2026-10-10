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

Evidence: `axod/src/work.rs`, `work_rpc.rs`, `work_lifecycle_tests.rs`; `protocol/src/work-contracts.ts` and `protocol/tests/work.test.ts`; `sites/api.axo.leostera.dev/tests/work.test.ts`. Current checkpoint: 35 Rust tests, 10 protocol/package tests and 26 API/local/fleet tests; strict Clippy, release build, schema check, API typecheck/build. All fixture daemons are owned/disposable and stopped by teardown. No real Pi, native app, physical phone or deployed Worker adoption is established by this evidence.

## 2. Contract transition and real vanilla Pi ownership — next

- [ ] Apply the `axo._.*` namespace coherently across Rust, TypeScript, Swift models/validators and isolated callers. Decide whether to delete the generic-launch helper or retain it behind explicit development policy; no old-name aliases.
- [ ] Make support advertisement distinguish adapter/route support from daemon support and actual Pi admission/readiness.
- [ ] Define managed-runtime caller provenance independently of method spelling or claimed JSON identities. A daemon-owned inherited control channel is a candidate; do not add local credential/account machinery or restore a legacy-envelope listener.
- [ ] Implement approved `axo.session.start` fresh/exact-resume intents and durable spawn receipts; bind persistence only through actual public Pi session APIs. Never adopt live unmanaged sessions implicitly.
- [ ] Admit a real vanilla Pi extension, with exact session/pane/runtime/host and canonical chat/file identity. Do not derive identity from PTY text or manufacture JSONL.
- [ ] Prove one managed writer per persistence binding; distinguish spawn, admission, stopped, failed and recovery-required. No automatic restart/replay.
- [ ] Validate headless UI/terminal behavior before claiming no-window readiness; disclose unsupported public UI waits.
- [ ] Exercise two actual independently addressed Pi sessions, disconnect/reconnect, exact resume, stale generation, startup failure and crash windows. Controlled public providers/tools are acceptable evidence for actual Pi execution, not substitutes for the Pi harness.

## 3. Chat reads and bounded observation

- [ ] `axo.chat.get/history/getToolOutput`, using canonical public Pi entry/branch identity, compaction/tree-aware projections and demand-driven tool detail.
- [ ] Active-view epochs and source-bound bidirectional history cursors; explicit stopped-history policy; UTF-8 encoded-byte bounds and continuation/truncation fixtures.
- [ ] `axo.observe.subscribe/unsubscribe/event`, bounded producer/client state, baselines, expiry, sequence gaps and read-only resynchronization.
- [ ] Public Pi lifecycle/assistant/thinking/tool/model/provider/UI-wait observations, without claiming remotely answerable generic approvals.
- [ ] `axo.chat.setViewing`: scoped expiring viewing leases, independent from subscription ownership.
- [ ] Decide opt-in bounded offline metadata replication and `axo._.catalog.publish`; any cached reads remain domain reads with explicit freshness/source policy, never public catalog-list aliases or history uploads.

## 4. Addressed chat controls

- [ ] `axo.chat.sendMessage`: ready/idle normal intent; reject busy/question-blocked state without steering conversion.
- [ ] `axo.chat.sendSteeringMessage`: captured active interaction; reject ended/idle state without starting a new interaction.
- [ ] Attachments prepared under captured targets and current existing file authority; revalidate after awaits; attachment-only messages supported.
- [ ] Durable normalized message disposition/evidence, pre/post-dispatch crash drills and truthful unknown outcome; no prompt bodies in diagnostics/runtime journal, no automatic replay or competing queue.
- [ ] `axo.chat.answerQuestion`: actual Axo-owned question/options, pending recovery, stale/duplicate rejection and no cancellation-as-approval.
- [ ] `axo.chat.cancelTurn`: public Pi abort of the captured active user interaction, settlement separate from acceptance, sibling isolation.
- [ ] `axo.runtime.stop` and local explicit `axo.runtime.daemon.stop`, with observed completion and no historical-PID signaling.

## 5. Remaining work records and local terminal plane

- [ ] Workspace/session archive and duplicate: preserve originals; fresh independent work/chat identities; reject copying live writers. Decide remote exposure explicitly.
- [ ] `axo.session.pane.create/start/remove` for approved shell panes; creation does not launch, removal requires stopped ownership, UI geometry remains native.
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
