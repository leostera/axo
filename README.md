# Axo

Axo is an agentic harness with a native macOS frontend and a Rust daemon.

## First macOS slice

- `apple/AxoMac/AxoMac.xcodeproj` is the native IDE project, generated from Bazel with `bazel run //apple/AxoMac:xcodeproj`.
- `apple/AxoRPC/` and `apple/AxoDaemonManager/` are small local Swift packages used by the app. The RPC package owns the JSON-RPC client/transport; the manager package owns ServiceManagement policy.
- The app is a SwiftUI menu-bar app with Settings, Check for Updates, and Quit actions.
- `crates/axod/` is the daemon CLI only. `clap` parses arguments and delegates to `crates/axo-server/`.
- `crates/axo-server/` owns the Rust JSON-RPC server and transport boundary: Unix-domain IPC today, with room for WebSockets later. Axo feature logic belongs in focused `axo-*` crates; future PTY/session management, for example, belongs in `axo-pty-ctrl`, not `axod` or the transport layer.
- The macOS app uses ChimeHQ's Swift JSONRPC package over Apple's Network framework and a Unix-domain socket. The transport is newline-framed JSON-RPC 2.0.
- `SMAppService` registers the bundled daemon as a per-user LaunchAgent, and launchd owns its process lifetime. The app compares daemon and app build numbers; on mismatch it asks ServiceManagement to restart the registered service from the current app bundle.
- The daemon continues running when the menu-bar app quits. Check for Updates is intentionally a placeholder until Axo has a release channel.
- Bazel 9.3.0 is the shared build and test graph. Rust dependencies are resolved from `Cargo.lock`; Swift package dependencies are resolved from `apple/AxoRPC/Package.resolved`. The test graph includes a live Swift-client-to-Rust-daemon Unix-socket interoperability test.

## Build and test

```sh
bazel test //...
bazel build //apple/AxoMac:AxoApp //crates/axod:axod
bazel run //apple/AxoMac:xcodeproj
xcodebuild -project apple/AxoMac/AxoMac.xcodeproj -scheme Axo -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Build, sign, verify, and atomically publish the development app bundle with:

```sh
bash scripts/build-mac.sh
```

The packaging script requires Bazel 9.3.0, Cargo for Rust lint checks, Xcode, and one valid Apple code-signing identity. It keeps the local build counter in `~/Library/Application Support/Axo/build-number`, outside the source tree, and supplies the selected number through Bazel's workspace-status stamping and Apple `--embed_label` versioning; CI should set `AXO_BUILD_NUMBER` to its run number. `BUILD_NUMBER` is the checked-in fallback for direct Bazel builds, which do not mutate or increment it. The script does not launch the app or daemon. The first slice does not yet integrate LibGhostty or session/PTY control.
