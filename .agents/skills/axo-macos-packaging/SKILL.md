---
name: axo-macos-packaging
description: Build, validate, and deliver Axo's Finder-launchable Mac app. Use after any Mac or bridge change that affects the shipped development app, and when updating dist/Axo.app.
---

# Axo macOS packaging

## Axod-only delivery

Leo explicitly requires **always repackaging `dist/Axo.app` after validated Mac changes**. A successful Xcode build under DerivedData is not delivery. The shipped Mac app is Axod-only: it bundles `axod` at `Contents/Helpers/axod` and registers that app-bundled helper as a per-user `SMAppService` LaunchAgent; it does not include the legacy Ghostty workbench/bridge path. Axo itself is registered as the login item. System Settings approval may be needed. Each app bundle is self-contained for moving to another Mac, although this development build is ad-hoc signed, not notarized. The iOS target remains a separate lane.

Keep project-specific operational guidance in `<axo-root>/.agents/skills/axo-*`, not the personal memory repository. Update this skill as the packaging workflow changes; do not turn transient build results or backup paths into permanent instructions.

## Build and validate

Resolve the Axo root from this skill's directory (`../../..`), rather than assuming the terminal's current directory is the repository root. Use:

```bash
cd <axo-root>
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --package-path protocol
swift test --package-path apple/AxoCore
cargo test --manifest-path axod/Cargo.toml --locked --offline
bash scripts/build-mac.sh
codesign --verify --deep --strict dist/Axo.app
```

Run affected layout or phone tests as appropriate. A shared AxoCore change also requires an AxoPhone build. If validation fails after packaging, fix and rebuild/repackage; never present the failed artifact as ready.

`build-mac.sh` requires XcodeGen, Rust/Cargo and the Axod build dependencies. It builds exactly one app bundle: `dist/Axo.app`, with `axod` at `Contents/Helpers/axod` and its per-user LaunchAgent plist. It validates identity, signs ad hoc, and atomically replaces that one bundle. It rejects `AXO_INSTANCE_ID` and `AXO_OUTPUT_APP`; do not produce versioned or named app bundles. It does not build or bundle the legacy Pi bridge.

`Axo.app` allows multiple app processes (`LSMultipleInstancesProhibited=false`); `open -n "$PWD/dist/Axo.app"` explicitly requests another process of the same build. All such processes share the same Axod LaunchAgent, daemon version, preferences, and state directory (`~/Library/Application Support/Axo/Axod`). Atomic replacement lets an already-running process retain its mapped executable while later launches use the new `Axo.app`, but both connect to that same daemon. Testing different daemon versions in parallel is not supported by this single-bundle workflow.

## Safe bundle replacement

- Keep Axod state private at `~/Library/Application Support/Axo/Axod`. Never import the legacy workspace registry or Pi histories during startup.
- Keep `axod` inside `Contents/Helpers` and verify its executable and code signature as part of the staged bundle.
- Stage on the same filesystem under `dist/`; verify the staged bundle before replacement.
- Use macOS `renamex_np` with `RENAME_SWAP` when an app already exists. Retain the previous bundle at the staging path for rollback.
- Never use `rm -rf dist/Axo.app` before installing its replacement. Reject a symlinked destination.
- Do not touch Application Support, conversation files, drafts, attachments, or running processes while packaging.
- `ditto` preserves the original DerivedData bundle-directory creation/modification dates even when its contents are freshly rebuilt. Stamp the staged outer `.app` directory's dates with packaging time using `xcrun SetFile` after signing; verify them on the final bundle. Do not recursively stamp signed contents or alter the retained previous package. Directory dates are delivery metadata, not proof of a running upgrade.
- Signing can change Mach-O bytes. Raw `cmp` is not a valid signed/unsigned executable comparison; use build UUIDs/code-section checks if needed, plus strict signature verification.

## Operational consent and evidence

Repackaging is authorized routinely. **It does not authorize a live app/Pi stop, restart, or relaunch**, nor physical phone installation. Ask separately before those operations; protect active work. Synthetic isolated native self-tests are not acceptance evidence for the live app.

Before retiring a working client during a cutover, verify the replacement's required operation parity; an empty catalog, successful build, or metadata connection does not prove a daily-workbench replacement.

An enabled `SMAppService` and successful `launchctl kickstart` do not prove the current bundled helper is running. Service registrations can still resolve a moved or trashed older bundle. Verify the actual running daemon version through local host diagnostics and, when needed, inspect the executable associated with the current service handle. Do not reset service registration or signal an observed historical PID as an automatic repair; preserve accepted work and obtain the applicable live-operation consent.

After packaging, report the actual `dist/Axo.app` path, validation results, and whether the live app was left running. Do not tell the user the running app has upgraded merely because the bundle was replaced.

Commit coherent tested changes frequently and push proactively. Preserve unrelated local work; do not bundle unrelated RFD drafts into a packaging commit.
