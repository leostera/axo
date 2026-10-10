# Non-Mac work before the axod client handoff

This is the execution checklist for the user's request to complete the non-Mac foundation before handing macOS work to another agent. It does not authorize editing the application, packaging, restarting live work, importing registries, changing file authority, startup registration or deployment. RFD0009 remains the contract authority.

## Acceptance milestone

An actual Rust `axo` CLI must invoke public WebSocket RPC on an owned `axod serve` process. The daemon admits the user's ambient interactive Pi in a native PTY with the `pi-axo` public extension. Tests establish actual canonical bindings, real tool effects and history, exact resume, scoped controls, mutation reconciliation and failure isolation. Native clients use those same contracts, not the test driver's private framing. No Mac window is required.

**Handoff is not ready yet.** Do not issue a "Mac-ready" prompt until the combined public path and its failure gates pass.

## Completed checkpoints

- Production native PTY management, journal/admission, generic/work-record public RPC and local/cloud route foundations.
- `pi-axo/` owns TypeScript Pi-loaded code. Ambient TUI/PTY conformance: 24 cases through the transitional test adapter.
- Rust `axo` binary and bounded local public RPC client: numeric private discovery, negotiation/credits, absolute deadlines, captured targets, sanitized errors, no automatic retry/replay. Parameters are stdin, not prompt bodies in argv.
- Rust tests run actual `axo` -> public WebSocket -> `axod serve`: metadata-only create, one generic PTY effect, original receipt reconciliation and stale destinations. This is not Pi RPC acceptance.
- Rust ambient dependency discovery and owner-only extension transport. Rust-only actual TUI test verifies TTY/PID admission, real bash and Pi-owned canonical records against public reads. This is not yet the same test as the public CLI path.

## Remaining dependency order

1. **Durable managed Pi admission:** explicit operator policy; full machine/workspace/session/pane destinations; fresh versus exact-resume intent; admission versus process-running distinction; canonical file/ID/cwd binding from public Pi APIs; managed writer leases before resume; immutable start reconciliation independent of changed operator policy; cold recovery without historical-PID adoption.
2. **Addressed public chat controls:** ready/idle normal sends, captured-interaction steering/cancel, owned questions with typed options, blocked generic waits, bounded mutations persisted before dispatch, truthful post-dispatch uncertainty. Void API dispatch is not execution completion. No second queue, command retargeting or replay.
3. **Read/observation contracts:** bounded source/branch/epoch-aware canonical history and tool detail; live event projections separately; baselines/sequence gaps/expiry; stopped reads cannot spawn. Explicit viewing leases and any cache freshness policy.
4. **One real CLI/daemon/Pi integration path:** move the 24-case orchestration to Rust and add positive local/cloud routing, concurrent clients, reconnect/cloud loss, restart/stale generations and crash-window tests. Keep Pi-side provider/tools in TypeScript. Replace generic Python fixtures with test-only Rust children. Discovery/unsupported-method tests are not execution coverage.
5. **Remaining non-native RFD domains:** pane/archive/duplicate work-record policy, separate bounded local terminal data plane, explicit runtime/host stop, coherent private namespace/feature support and existing file-authority characterization. Preserve old service/bridge ownership and require separate live cutover consent.
6. **Validation/delivery:** Rust fmt/tests/Clippy/release, protocol/package/property/schema validation, actual local/cloud RPC matrix, repeated combined Pi tests, metadata-only diagnostics, owned teardown and operational-limit documentation. No native changes or packaging in this lane.

## Mac agent handoff, once ready

Provide the exact commit(s), methods and result schemas, public CLI smoke, disposable fixture setup, test counts with scope, supported/unsupported capabilities, source/identity capture rules, ownership/storage transition gates and rollback limits. Require reuse of `AxoCore`/`AxoProtocol` and no direct Pi path. The pinned Ghostty external-PTY adapter remains an explicit Mac feasibility gate; backlog is not a VT snapshot. Preserve concurrent native changes and accepted work. Signed atomic packaging and live restart require their own applicable workflow/consent.
