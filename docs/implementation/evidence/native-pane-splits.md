# Captured native shell splits — build133

## Exact checkpoint

- Implementation: `21a984ca79490e7e88abcd811cbc6c61ffda4133`.
- Delivered `dist/Axo.app`: **build133**, `AxoBuildCommit` exactly that source; bundled helper **`0.1.0 (21a984ca)`**. Deep strict signature verification passes; atomic packaging preserves the prior signed bundle.
- Ambient Pi remains `/opt/homebrew/bin/pi` **1.1.0** with the exact packaged Axo adapter. No engine fallback, installation, upgrade, RPC-mode Pi or private Pi API was added.
- No live helper/app restart, service handoff, API deployment or physical-phone installation was performed. The last read-only live-helper observation remains `23be4c99` with five recovery-required runtimes; this package does not establish a running upgrade.

## Implemented owning slice

- Pane → **Split Right** / **Split Down** supplies default Cmd+D / Shift+Cmd+D. Production actions capture the local machine/source, session, original focused pane, direction and original command ID before asynchronous work. Settings/another key window cannot dispatch those app-menu actions into the main workbench.
- Each action calls existing local-only `axo.session.pane.add` once, with the default boot-captured login shell in the committed HOME/project directory. No cwd/argv or cloud authority was added. A separately negotiated control peer avoids waiting behind the main client's Pi-admission request.
- Original shell-command and split-placement hints are saved before dispatch. Prepared, missing, corrupt, stale and unknown evidence cannot authorize a second command. Restoration is metadata/geometry only; reconciliation looks up the original `axo.command.get` receipt. Matching immutable added/rejected evidence resolves its own hint, never another command's hint.
- The pinned Ghostty `SplitTree`/`SplitView` implements geometry. Saved JSON is closed, machine/session scoped and bounded to 16 KiB, 32 identity leaves and depth32; decoded leaves contain no terminal/process constructor. Unreadable data is preserved. Missing catalog leaves stay inert, not removal authority. Divider callbacks carry a generation, rejecting stale nodes including equal-looking ABA changes.
- A retained surface can move between reflowed hosts only within its existing viewport owner. A different owner remains a competing viewport; no duplicate frontend/Pi or silent cross-window transfer is permitted. Actual first-responder callbacks validate the exact terminal identity before updating focus.
- Initial creation still selects committed metadata directly and assigns the independent right shell before Pi admission. No naming/progress modal or Open Session step was introduced.

## Failures retained and corrections

Expanding the fixture from one shell to three exposed a main control-peer disconnect during ordinary refresh/reselection. Compile-only diagnostics classified it as **Disconnected**, without printing response bodies or raw errors. A separate real-daemon read-only burst then disconnected after **14 runtime replies**, in addition to negotiation. The existing local admission window counts both calls and their credit acknowledgements and remains **30 commands/second**.

`AxoJSONRPCWebSocketConnection` now spaces actual request dispatches by at least 100 ms, leaving acknowledgement headroom. The original pending-call cap and deadlines remain; credit acknowledgements are prompt. A queued write rechecks closed/pending state and Access-cookie expiry, and observed cancellation/expiry prevents its later dispatch. Already dispatched delivery can remain unknown. This is not a retry/offline queue or increased daemon/terminal allowance. It addresses the demonstrated burst; arbitrary network stalls/notification floods and exhaustive robustness are not proven.

An additional fixture assertion incorrectly assumed the original shell remained `shellPanes.first` after more panes were added. The assertion now uses its captured pane ID; daemon array order is not identity. Initial compile failures (private typealias visibility, wrong session-record field and non-Hashable runtime set) are preserved with the passing reruns; incorrect synthetic string escaping was corrected before execution. No uncertain terminal input was resent.

## Passing owned evidence

The Rust-owned production-native fixture now has five fresh-root modes: delayed Pi, unavailable Pi, automatic empty startup, opaque pending hint and **panes**. The panes mode adds two independent shells through the production split selectors, checks right/down placement against actual focused anchors and positive native geometry, executes one intentional command in each actual Ghostty surface, verifies unchanged Pi/original shell and three distinct shell runtime generations, and compares exact saved geometry after reconnect/fresh-coordinator restoration. Presentation disposal leaves all four managed runtimes running.

The dedicated control test reads 24 runtime pages through the production Swift client, cancels a queued metadata-create request, and then observes no receipt or extra session in that owned namespace. A missing receipt is still not general replay permission.

Against the **exact build133 helper/adapter and committed production UI/Core sources**:

- **Five rounds / 25 fresh-root scenarios pass**, including all five split/control-burst scenarios. There are 60 PASS lines because component and owner-side results are reported separately, not 60 independent workflow gates.
- Exact packaged public CLI: **8 passed**, no ignored cases.
- AxoCore: **81 passed**, no skips; exact full Ghostty terminal/component fixture passes.
- Local layout/hint and existing shell client-state checks pass, including closed/corrupt parsing, captured placement, original command identity, unknown/no-replay and stale/ABA resize refusal.
- Full Rust serial lane: **104 library tests** plus interactive1/local2/managed-public1/public-CLI8/relay-config4, no failures/ignored cases. Strict all-target Clippy and fmt pass.
- Swift protocol: **41 executed, one existing relay E2E skip**; that skip remains incomplete. Pinned split suite: **50 Swift Testing cases pass** (the XCTest wrapper reports zero tests).
- Mac package/build and iOS compile pass. The iOS compile is not a device installation or new-route acceptance.

Representative commands:

```sh
bash scripts/check-mac-pane-layout.sh
bash scripts/check-mac-shell-creation.sh
AXO_LOCAL_DAEMON_BINARY="$PWD/dist/Axo.app/Contents/Helpers/axod" \
  AXO_NATIVE_WORKBENCH_REPETITIONS=5 bash scripts/check-mac-workbench.sh
AXO_LOCAL_DAEMON_BINARY="$PWD/dist/Axo.app/Contents/Helpers/axod" \
  cargo test --manifest-path axod/Cargo.toml --locked --offline --test public_cli -- --test-threads=1
AXO_LOCAL_DAEMON_BINARY="$PWD/dist/Axo.app/Contents/Helpers/axod" swift test --package-path apple/AxoCore
AXO_LOCAL_DAEMON_BINARY="$PWD/dist/Axo.app/Contents/Helpers/axod" bash scripts/check-mac-terminal.sh
codesign --verify --deep --strict dist/Axo.app
```

Logs include `/tmp/axo-pane-native-{baseline,splits,splits-rerun,classification}.log`, `/tmp/axo-pane-control-burst-before.log`, `/tmp/axo-pane-paced-native{,-final}.log`, `/tmp/axo-pane-{mac,mac-rerun,mac-final,paced-mac,ios,core,protocol,split-tree,rust,clippy,terminal,package}.log`, and `/tmp/axo-pane-133-{native,cli,core,terminal,layout,ios}.log`. Failed evidence was not removed.

## Still open

**M07/A04/A06 are not complete.** Offscreen production-source selector/input checks do not prove Finder/service launch, real OS Cmd+D/Shift+Cmd+D routing, IME/focus traversal/scale/paste/drop, keyboard divider/equalization/zoom, all-action configurable shortcuts, same-pane multiwindow policy or long-running robustness. Preferences/fresh-coordinator restoration is not crash/power-loss durability or full VT recovery. The 32-surface cache still lacks the required eviction/recovery lifecycle.

Native Cmd+W/destructive confirmation, exact shell completion/tombstones under job control/escaped descendants, and Pi-close semantics remain separate unfinished work. No Pi stop/removal behavior was invented. The live recovery/handoff, full supported-workflow gates, deployed/device routes and remaining mandatory ergonomics remain open; no scope change or completion is claimed.
