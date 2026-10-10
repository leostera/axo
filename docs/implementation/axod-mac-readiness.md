# Non-Mac work before the axod client handoff

This is the execution checklist for the user's request to complete the non-Mac foundation before handing macOS work to another agent. It does not authorize editing the application, packaging, restarting live work, importing registries, changing file authority, startup registration or deployment. RFD0009 remains the contract authority.

## Acceptance milestone

An actual Rust `axo` CLI must invoke public WebSocket RPC on an owned `axod serve` process. The daemon admits the user's ambient interactive Pi in a native PTY with the `pi-axo` public extension. Tests establish actual canonical bindings, real tool effects and history, exact resume, scoped controls, mutation reconciliation and failure isolation. Native clients use those same contracts, not the test driver's private framing. No Mac window is required.

**Handoff is not ready yet.** The combined local/cloud Pi path now passes isolated acceptance, but the remaining non-Mac failure, observation, ownership and domain gates below are not complete.

## Completed checkpoints

- Production native PTY management, journal/admission, generic/work-record public RPC and local/cloud route foundations.
- `pi-axo/` owns TypeScript Pi-loaded code. Ambient TUI/PTY conformance: 24 cases through the transitional test adapter.
- Rust `axo` binary and bounded local public RPC client: numeric private discovery, negotiation/credits, absolute deadlines, captured targets, sanitized errors, no automatic retry/replay. Parameters are stdin, not prompt bodies in argv.
- Rust ambient dependency discovery and closed owner-only extension transport, plus the earlier independently verified CLI/generic-PTY and Manager/Pi paths.
- **Joined public path:** `tests/managed_public.rs` now exercises actual `axo` -> public WebSocket -> `axod serve` -> ambient TUI, with approved policy, actual canonical bindings, real bash/history/tool pages, steering/cancel, Axo-owned questions, viewing leases, original dispositions, clean restart/stopped reads/exact resume and consumed-input uncertainty.
- Rust owns daemon/Pi/model/process orchestration; the new Node child only hosts the actual isolated Worker/Access fixture. Cloud RPC admits an independent actual Pi and runs a real tool; Worker/client loss preserves accepted Pi. Synthetic assertions stay in bounded private files, and owned Worker/compiler groups retain their original leader until cleanup.
- Private `pi-state.json` stores normalized intent fingerprints/dispositions/bindings, never prompts/history. Work/runtime/Pi domains share command collision and persistence fencing. Six store/lease/tree/cross-domain regressions and the public-path storage fault exercise fail-closed behavior. See `axod/MANAGED_PI.md` for exact current contracts/limits.

- Initial **local-only shell panes** now support `axo.session.pane.add/remove`, matching explicit create-and-launch and Cmd+W terminate-and-remove. Actual CLI acceptance proves independent real TTY effects, sibling isolation, tombstones/original reconciliation and clean restart/no replay. A typed Manager completion witness gates final removal. `session.get/list` expose bounded shell views; shared protocol separates local (21) from remote (19) methods. Geometry/terminal bytes remain outside RPC. See `axod/PANES.md`; native shortcuts/attachment are not yet wired.

- Completion hardening now uses the exact durable Manager proof for managed resume/stopped reads/admission, and explicitly releases cooperative writer locks despite transient FD copies. Bounded fixed-seed campaigns passed 1,536 synthetic completion sequences and 12,000 relay framing cases. Oversized reply groups preserve correlation IDs as unknown outcomes; isolated Worker deadline/late-success tests verify no resurrection/replay. These are model/source/isolated tests, not crash, escaped-descendant, power-loss, soak or native handoff acceptance. See `axod/tests/README.md`.

## Remaining dependency order

1. **Harden managed Pi admission:** the explicit fresh/exact-resume policy, actual public bindings, durable intents and cooperative leases are implemented. Still prove crash/spawn/fsync windows, interrupted admission, arbitrary unmanaged writer exclusion/operational policy, lazy missing canonical-file behavior, bounded retention and orphan recovery. Never adopt or signal historical PIDs.
2. **Harden addressed chat controls:** initial text/steering/cancel/owned-question/viewing APIs and durable dispositions are implemented. Complete public-path sibling/cancellation/late-answer/crash campaigns and attachment preparation under existing file authority. Void API dispatch is not execution completion; no second queue, retargeting or replay.
3. **Read/observation contracts:** bounded source/branch/epoch-aware canonical history and tool detail; live event projections separately; baselines/sequence gaps/expiry; stopped reads cannot spawn. Explicit viewing leases and any cache freshness policy.
4. **Expand the joined CLI/daemon/Pi integration path:** positive local/cloud admission/tool execution, cloud loss and clean restart now pass. Move the remaining 24-case orchestration to Rust and expand simultaneous clients, sibling isolation, reconnect and crash-window evidence. Keep Pi-side provider/tools in TypeScript. Replace generic Python fixtures with test-only Rust children. Discovery/unsupported-method tests are not execution coverage.
5. **Remaining non-native RFD domains:** pane lifecycle hardening/archive/duplicate work-record policy, separate bounded local terminal data plane, explicit runtime/host stop, coherent private namespace/feature support and existing file-authority characterization. Preserve old service/bridge ownership and require separate live cutover consent.
6. **Validation/delivery:** Rust fmt/tests/Clippy/release, protocol/package/property/schema validation, actual local/cloud RPC matrix, repeated combined Pi tests, metadata-only diagnostics, owned teardown and operational-limit documentation. No native changes or packaging in this lane.

## Mac agent handoff, once ready

Provide the exact commit(s), methods and result schemas, public CLI smoke, disposable fixture setup, test counts with scope, supported/unsupported capabilities, source/identity capture rules, ownership/storage transition gates and rollback limits. Require reuse of `AxoCore`/`AxoProtocol` and no direct Pi path. The pinned Ghostty external-PTY adapter remains an explicit Mac feasibility gate; backlog is not a VT snapshot. Preserve concurrent native changes and accepted work. Signed atomic packaging and live restart require their own applicable workflow/consent.
