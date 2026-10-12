# axod test boundary

Run `cargo test --manifest-path axod/Cargo.toml --locked --offline` from the repository root. Fixtures own disposable private directories and only their still-unreaped child handles. They never reset installed Axo state, adopt execution or signal historical PIDs.

- Central repository tests cover complete graph/original publication, capacity, archive/reopen intent, stable retained pane identities, no fresh draft storage and preservation of uninterpreted retired bytes, private storage fencing and supported central schema upgrades.
- Central controller/RPC tests cover source/store generation, parent-owner contention, no legacy import, immutable original lookup, backend materialization, withdrawn intent, completion-proven successors and stale configuration observations.
- The actual three-workspace/twelve-session/thirty-six-pane fixture uses twelve ambient interactive Pi processes and twenty-four shells, with an owned model peer, canonical writer/resume checks and no frontend startup calls.
- `local_sessions.rs` invokes the production `serve-user` startup policy through a copied helper in a disposable bundle-shaped fixture. It verifies automatic Pi/shell admission for home and selected-folder graphs without client start calls or model requests. This is not installed launchd/approval acceptance.
- `central-client-fixture` serves only a disposable central authority, with no Pi/cloud policy or installed-service registration. The Swift client test proves complete creation, automatic shell materialization, source/store parsing, read-only disconnect and immutable originals across an owned helper restart. Run:
  ```sh
  cargo build --manifest-path axod/Cargo.toml --locked --offline --example central-client-fixture
  AXO_CENTRAL_FIXTURE_BINARY="$PWD/axod/target/debug/examples/central-client-fixture" \
    swift test --package-path apple/AxoCore
  ```
- `interactive_pi.rs` exercises real vanilla Pi, its public extension/control channel, PTY tools and canonical history. Pi alone writes JSONL.
- `public_cli.rs` retains the native PTY/terminal frontend boundary: exact launch reconciliation, input/resize, frontend exit without stopping work, bounded recovery refusal and payload-free stale-source failures. It is not an alternate session catalog.
- Library terminal tests cover owned process-group/output completion, durable witnesses, exact attachments, transport bounds, credit/deadline fencing and slow-reader isolation. Lease tests cover fork-inherited descriptors and explicit ownership release.

Tests for the deleted JSON catalogs, legacy keep-alive and frontend-managed Pi startup have been retired, rather than kept behind compatibility adapters. Old Mac/cross-client fixtures that parsed those catalogs are not acceptance for central clients. Native UI, packaged source/signatures, installed service lifecycle, authoritative VT recovery, physical devices/input and crash survival require their own evidence.
