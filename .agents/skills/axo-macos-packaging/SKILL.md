---
name: axo-macos-packaging
description: Build, validate, and deliver Axo's Finder-launchable Mac app. Use after any Mac app, bundled helper, or Pi extension change that affects the shipped development app, and when updating dist/Axo.app.
---

# Axo macOS packaging

Resolve the Axo root from `../../..` relative to this skill. **Always repackage `dist/Axo.app` after validated Mac changes.** A DerivedData build is not delivery. Follow the sibling [native Mac](../axo-macos-native-apps/SKILL.md) skill.

## Current package

- The development artifact is one self-contained `dist/Axo.app`, signed with an existing Apple Development or Developer ID Application identity. It is not a notarized distribution. Ad-hoc signing is not supported for installed-service packages: deep/strict verification alone does not prove launchd will accept a helper.
- `scripts/mac-signing.py` selects a single valid identity, or requires its explicit fingerprint in `AXO_MAC_SIGNING_IDENTITY` when ambiguous. It never installs certificates or falls back to ad hoc. The helper and outer app must have the same actual CodeDirectory team; a development certificate’s display-name suffix is not necessarily its team.
- The app embeds `Contents/Helpers/axod`, its installed Pi extension/resources and per-user LaunchAgent plist. Ambient vanilla Pi remains an external runtime dependency.
- Explicit setup uses `SMAppService` to register the bundled daemon as a per-user LaunchAgent. System Settings approval may be required. Launchd alone starts the production helper; reconnect never registers, repairs or directly starts it. Frontend login startup is independently opt-in.
- State is `~/Library/Application Support/Axo/Axod`. Multiple processes of the same bundle share daemon, preferences and state (`LSMultipleInstancesProhibited=false`). Do not create named/versioned app variants or concurrently test different daemon versions against that shared state.
- Phone builds/routing/deployments are independent. Local packaging does not authorize changing or installing them.

## Build and verify

```bash
cd <axo-root>
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --package-path protocol
swift test --package-path apple/AxoCore
cargo test --manifest-path axod/Cargo.toml --locked --offline
bash scripts/build-mac.sh
codesign --verify --deep --strict dist/Axo.app
```

Run affected TypeScript/layout/native/Xcode UI tests. Shared AxoCore changes require an AxoPhone build. Builds and native fixture compilation must be sequential against shared DerivedData.

`build-mac.sh` requires XcodeGen, Rust/Cargo and the daemon dependencies. It builds, validates, signs and atomically replaces exactly `dist/Axo.app`; `AXO_INSTANCE_ID` and `AXO_OUTPUT_APP` are rejected. Validate the exact committed source, `AxoBuildCommit`, bundle version, executable/helper identity and strict signatures. Signing changes Mach-O bytes; compare build UUIDs/code sections when needed, not raw signed/unsigned `cmp`.

If a package fails validation, fix and repackage before reporting it ready. After committing source, rebuild for the exact commit and rerun the applicable packaged acceptance lanes.

## Atomic replacement

- Stage on the same filesystem under `dist/`; validate the staged bundle and embedded executable/signatures before replacement.
- Reject symlinked destinations. Use `renamex_np(RENAME_SWAP)` for an existing app; retain the swapped-out bundle at the staging path for rollback. Never delete `dist/Axo.app` first.
- Do not modify Application Support, histories, drafts, attachments, credentials or running processes while packaging.
- Stamp only the staged outer `.app` directory dates with packaging time (`xcrun SetFile`) after signing, then verify the final dates. `ditto` otherwise preserves DerivedData directory timestamps. Do not recursively touch signed contents or the rollback package.
- An already-running app retains mapped code while later launches use the replacement bundle. Both still share daemon/state. Bundle replacement does not upgrade the running app/helper.

## Runtime and consent

- Packaging is authorized routinely; live app/daemon/Pi stop, restart or relaunch, service reset, remote deployment and physical-device installation require applicable explicit consent or exact durable lifecycle authority.
- Never adopt or signal PIDs discovered in files or process lists. Preserve accepted work and uncertain outcomes. Normal frontend exit does not stop daemon-owned work.
- Service status and successful `launchctl` commands are not proof of the running binary or operational readiness. Verify actual host version and exact runtime capabilities through addressed diagnostics.
- Ownership repair uses validated exclusive `owner.lock`, not refused sockets, empty cached catalogs or apparent process absence. Unregister/register only under the supported ownership procedure; release the lease before starting the captured service. `scripts/check-mac-owner-lease.sh` tests private fixture contention/metadata, not normal service handoff.
- Incompatible active helpers visibly block unsupported operations. Do not replace one until the Manager supplies required durable idle/completion authority or the operator supplies scoped consent/reconciliation.
- Never bypass denied Accessibility or other permissions. Xcode UI testing must refuse if an Axo frontend is open because launch automation can terminate same-bundle applications.

## Acceptance and report

Use `scripts/check-mac-app-startup.sh` and its unavailable-Pi negative control for packaged startup; use `scripts/check-mac-ui.sh` for actual XCTest UI. Their Rust-prepared roots/helper/model are private and disposable. Match claims to evidence: isolated UI/component success does not prove normal ServiceManagement, argument-free Finder, physical IME, independent windows or notification delivery.

Commit coherent validated Conventional Commits and push proactively. Report the actual `dist/Axo.app` path, exact source/build/signature/test status and whether normal live processes were left untouched. Keep current workflow in project skills; retain test evidence and decisions in project documentation, not a skill timeline.
