# Terminal-plane component checkpoint — a6765aa

## Versions and scope

- Implementation source: `a6765aaf92eb2626866bc6afa0ed9092035b25d2`, committed and pushed to `origin/main`.
- Packaged app: `dist/Axo.app`, build **114**, `AxoBuildCommit` equal to that implementation revision.
- Bundled helper: **`0.1.0 (a6765aaf)`**; `--version` was read without starting its service.
- Environment: macOS **26.6.2**, Rust **1.99.0**, Apple Clang **21.0.0**, Swift **6.4** toolchain (app language/target baselines unchanged).
- Ghostty source: **`7ec9e26a29399b30ef78f06985fc75045b3cecb6`**, clean tracked checkout.
- Characterized local VT dylib SHA-256: `3a05e36d0fe8c70ca2ea22b4ba3a93e63601376f9fe32ad57e769e045a8b4810`. This is an isolated characterization artifact, **not bundled in build 114**; source pin/artifact hash do not independently prove reproducible build or ABI compatibility.

This is a **component/fixture/package checkpoint**, not A03/A04/A15 actual-surface acceptance. No supported workflow gate or goal task was closed by it. No live app/helper restart, uncertain-command replay, deployment, credential change or physical-phone installation occurred. All processes launched by these tests used disposable, owner-private fixture roots; cleanup was limited to their owned handles/groups.

## Passing validation

| Command / surface | Result and limit |
| --- | --- |
| `cargo test --manifest-path axod/Cargo.toml --locked --offline -- --test-threads=1` | **88 library tests**, interactive Pi **1**, local sessions **2**, managed public **1**, public CLI **4**, relay config **4**; no ignored/skipped Rust cases. Ran on the exact source content subsequently committed as a6765aa; these were pre-commit development binaries, not the release packaged helper. Actual ambient Pi fixture lanes remain distinct from native workbench acceptance. |
| Five `terminal_transport::tests` within that library suite | Production local control/terminal listeners with real synthetic PTYs: input/resize, one-client lease, detach/reconnect, stale identities, sibling survival, final-output/EOF ordering, private discovery, browser/cross-plane denial, slow-reader detach with continued process/control availability, closed codec and credit bounds. No fake Pi or terminal-content diagnostics. |
| `cargo clippy --manifest-path axod/Cargo.toml --locked --offline --all-targets -- -D warnings` / `cargo fmt` / `git diff --check` | Passed. |
| `bash scripts/check-ghostty-vt-snapshot.sh` | Passed against the pinned public VT C API and identified dylib: unfinished escape/UTF-8 continuation, alternate/hidden-primary text restoration, corrupt/truncated snapshot rejection and caller output-buffer bounds. Styled replay was checked **only for text**, not full state, styles or graphics. |
| `npm --prefix protocol run test:properties` | **4** property/differential cases passed. Codec/admission models, not native/device acceptance. |
| `npm --prefix sites/api.axo.leostera.dev run test:properties` | **2** seeded framing/durable-group cases passed. No deployment or live API acceptance. |
| `swift test --package-path protocol` | **33** cases, **1 skipped**, no failures. `AxoProtocolE2ETests.testSwiftProtocolContractsAgainstRealAxod` still needs its owned/deployed relay fixture environment; its skip is **not passing route evidence**. |
| `AXO_LOCAL_DAEMON_BINARY="$PWD/dist/Axo.app/Contents/Helpers/axod" swift test --package-path apple/AxoCore` | **81** cases, **zero skips**, no failures. The actual **packaged a6765aaf helper** ran under an isolated private root for `LocalDaemonIntegrationTests.testLocalDaemonDiscoveryDisconnectAndRestartDoNotReplayFixture`; the installed service/live state was not used. This upgrades the former environment skip to actual isolated local-client/daemon evidence, not UI acceptance. |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build-mac.sh` | Passed; atomically packaged build114 and retained prior bundle for rollback. No launch. |
| `codesign --verify --deep --strict dist/Axo.app` | Passed after packaging; source/build/helper values read from the delivered bundle. Signature verification does not establish running-service upgrade, notarization or working terminals. |

Temporary log pointers (not acceptance archives): `/tmp/axo-terminal-plane-rust.log`, `-package.log`, `-swift-protocol.log`, `-core-real-daemon.log`, `-protocol-properties.log`, `-api-properties.log` under the same prefix. The scenario/version/results above are the durable record; do not depend on those temporary files remaining available.

## Open integration work

The local plane is separate from control RPC and not cloud-routed. Its [contract and bounds](../../../axod/TERMINALS.md) explicitly disclose raw backlog rather than VT state and volatile input sequences rather than durable receipts.

The shipped Mac target still has **no native terminal renderer or independent default shell**, and its immediate Pi-left/shell-right flow is unaccepted. GhosttyKit has no public direct external-PTY/binary-snapshot adoption hook. RFD0007 permits a transport-only attachment child; that child must never become the Pi/shell owner. Next: implement and validate that seam, preserve headless work, resolve truthful snapshot/live recovery, then connect direct New Session and automatic genuinely-empty startup. IME, Kitty images, real surface resize/focus/detach/reconnect, native creation, active/uncertain safe handoff, deployed API/device workflows and the other inventory gates remain open.
