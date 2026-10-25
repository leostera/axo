# Axo

Axo is an agentic harness for terminal romantics, with a native macOS frontend and a Rust daemon.

## First macOS slice

- `apple/Axo.xcodeproj` is the native IDE project for every Apple package and app, generated from Bazel with `bazel run //apple:xcodeproj` (not checked in; Bazel stays the build).
- `apple/AxoProtocol/`, `apple/AxoClient/`, `apple/AxoSearch/` and `apple/AxoDaemonManager/` are local Swift packages used by the app. `AxoClient` is the client for hosts (pluggable transport, persistent JSON-RPC connection, axod's typed API); the manager package owns ServiceManagement policy.
- The app is a SwiftUI macOS app with a menu-bar extra and a standard Axo application menu while its terminal window is active. The terminal window is the primary launch window, with Settings, Check for Updates, and Quit actions.
- `crates/axod/` is the daemon CLI only. `clap` parses arguments and delegates to `crates/axo-server/`.
- `crates/axo-server/` owns the Rust JSON-RPC server, Unix-domain transport boundary, and session lifecycle in `session.rs`; `crates/axod/` remains a CLI and PTY-attachment helper.
- The macOS app talks to axod with `AxoClient` over Apple's Network framework and a Unix-domain socket: newline-framed JSON-RPC 2.0 on one persistent connection.
- `SMAppService` registers the bundled daemon as a per-user LaunchAgent, and launchd owns its process lifetime. The app compares daemon and app build numbers; on mismatch it asks ServiceManagement to restart the registered service from the current app bundle.
- The daemon continues running when the menu-bar app quits. Check for Updates is intentionally a placeholder until Axo has a release channel.
- A session is a tab containing one or more shells. Splits create additional shells in the selected tab; each shell has its own daemon-owned PTY and pinned libghostty surface. Pane and window title bars are omitted; terminal actions are in the Terminal menu, and View → Toggle Sidebar uses Command-S. Settings has a fixed General/About sidebar; General includes a scroll-sensitivity slider from 0.1× to 3.0×, with the neutral 1.0× setting centered, while About reports the Axo/axod versions, builds, source commit, and daemon status.
- `axod terminal-attach --shell-id` bridges a Ghostty surface to a daemon-owned PTY and forwards terminal input mode and resize changes. While the daemon remains running, it keeps up to 8 MiB of each shell’s VT output in memory so a newly attached Ghostty surface can replay and restore the terminal screen; if the limit is exceeded, Axo skips replay rather than applying a partial stream. This history is not persisted across daemon restarts. The daemon restores open tabs and shells after restart and ensures at least one shell remains available.
- `ghostty_repository.bzl` pins Ghostty and Zig, builds GhosttyKit for macOS, and packages Ghostty resources and terminfo through Bazel. When the Ghostty app is installed, Axo uses its theme resources and loads the normal Ghostty config; copy-on-select writes selected terminal text to the system clipboard by default, with the Ghostty config able to override that default.
- Bazel 9.3.0 is the shared build and test graph. Rust dependencies are resolved from `Cargo.lock`; Remote Swift packages are listed in `apple/Package.swift` and pinned in `apple/Package.resolved` (`swift_deps` reads one manifest); each package's own `Package.swift` still names what it uses. The test graph includes a live Swift-client-to-Rust-daemon Unix-socket interoperability test.

## Native visual UI tests

`//apple/AxoMac:AxoVisualUITestsBazel` is the repeatable entrypoint for the native UI test. It is a Bazel `sh_test` wrapper that prepares the Xcode project and private socket/database/home/control fixture, starts its own `axod`, injects the fixture root into the Xcode scheme, and invokes Xcode's native UI-test runner. The alternate app bundle never registers or restarts the production LaunchAgent, and the wrapper stops only its own daemon and app. The underlying `//apple/AxoMac:AxoVisualUITests` `macos_ui_test` target remains tagged `manual` because `rules_apple`'s default runner cannot provide this interactive desktop workflow; the wrapper is not `manual`, so it is included in `bazel test //...` on macOS.

Run the GUI suite on an unlocked macOS 14+ desktop:

```sh
# Run only the native visual UI test and print its artifact paths.
bazel test //apple/AxoMac:AxoVisualUITestsBazel --test_output=all

# Run it together with the rest of the Bazel test suite.
bazel test //...
```

XCUITest sends keyboard shortcuts and terminal text to real libghostty surfaces. A test-bundle-only file bridge provides bounded readiness and surface-count checks; the production app has no test control endpoint. Every workflow checkpoint captures a PNG, attaches it to the XCTest result, and writes it under the XCTest runner's `NSTemporaryDirectory()/axo-ui-screenshots/<run-id>/`; the test log prints the exact directory. OCR checks on terminal markers and pane geometry, together with daemon-state assertions, detect missing output, blank panes, and misplaced splits.

The Bazel test outputs for `AxoVisualUITestsBazel` contain `xcodebuild.log`, the `.xcresult` bundle, and isolated daemon logs under `bazel-testlogs/apple/AxoMac/AxoVisualUITestsBazel/test.outputs/` for the active test configuration. The wrapper prints `AXO_UI_XCRESULT` and `AXO_UI_SCREENSHOTS` with their exact paths; open the result bundle in Xcode to inspect the attached screenshots, or open the PNG directory directly. Direct `xcodebuild test` invocation does not prepare the fixture root or start the isolated daemon; use the Bazel wrapper for repeatable runs.

macOS may require system authorization to enable Xcode UI Automation; approve it through the normal macOS authentication prompt or settings. If `testmanagerd` cannot enable Automation Mode, the test fails before the fixture starts. Do not bypass that OS authorization.

## Build and test

```sh
bazel test //...
bazel build //apple/AxoMac:AxoApp //crates/axod:axod
bazel run //apple:xcodeproj
xcodebuild -project apple/Axo.xcodeproj -scheme AxoApp -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Build, sign, verify, and atomically publish the development app bundle with:

```sh
bash scripts/build-mac.sh
```

The packaging script requires Bazel 9.3.0, Xcode, and one valid Apple code-signing identity. It packages and verifies the app without running tests or lint checks; run `bazel test //...` separately when validation is needed. It keeps the local build counter in `~/Library/Application Support/Axo/build-number`, outside the source tree, and supplies the selected number through Bazel's workspace-status stamping and Apple `--embed_label` versioning; CI should set `AXO_BUILD_NUMBER` to its run number. `BUILD_NUMBER` is the checked-in fallback for direct Bazel builds, which do not mutate or increment it. The script does not launch the app or daemon.
