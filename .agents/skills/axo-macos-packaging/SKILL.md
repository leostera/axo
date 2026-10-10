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

`build-mac.sh` requires XcodeGen, Rust/Cargo and the Axod build dependencies. It builds `axod`, generates the Xcode project, builds the Axod-only AxoMac target, stages the app plus `Contents/Helpers/axod` and the user LaunchAgent plist, validates their identity, signs ad hoc, and atomically replaces the selected app bundle. It does not build or bundle the legacy Pi bridge.

`Axo.app` allows multiple app processes (`LSMultipleInstancesProhibited=false`); `open -n <path-to-Axo.app>` explicitly requests a separate process, and clients from the same bundle connect to that bundle's one Axod service. To build and test two app/daemon versions side by side without sharing daemon state or LaunchAgent identity, build a named variant and distinct output:

```bash
AXO_INSTANCE_ID=2 AXO_OUTPUT_APP="$PWD/dist/Axo-2.app" bash scripts/build-mac.sh
```

The variant receives a distinct bundle identifier, LaunchAgent label, and private state directory under `~/Library/Application Support/Axo/Instances/2/Axod`. Its app bundle still includes its own `axod`. Give each concurrently tested daemon build a fresh instance ID/output path: named app bundles are intentionally not replaced, avoiding accidental reuse of an older registered daemon. Launch a variant with `open -n "$PWD/dist/Axo-2.app"`. The default bundle keeps the existing `~/Library/Application Support/Axo/Axod` location.

## Safe bundle replacement

- Keep each Axod state directory private. The default uses `~/Library/Application Support/Axo/Axod`; named test variants use `~/Library/Application Support/Axo/Instances/<id>/Axod`. Never import the legacy workspace registry or Pi histories during startup.
- Keep `axod` inside `Contents/Helpers` and verify its executable and code signature as part of the staged bundle.
- Stage on the same filesystem under `dist/`; verify the staged bundle before replacement.
- Use macOS `renamex_np` with `RENAME_SWAP` when an app already exists. Retain the previous bundle at the staging path for rollback.
- Never use `rm -rf dist/Axo.app` before installing its replacement. Reject a symlinked destination.
- Do not touch Application Support, conversation files, drafts, attachments, or running processes while packaging.
- Signing can change Mach-O bytes. Raw `cmp` is not a valid signed/unsigned executable comparison; use build UUIDs/code-section checks if needed, plus strict signature verification.

## Operational consent and evidence

Repackaging is authorized routinely. **It does not authorize a live app/Pi stop, restart, or relaunch**, nor physical phone installation. Ask separately before those operations; protect active work. Synthetic isolated native self-tests are not acceptance evidence for the live app.

After packaging, report the actual `dist/Axo.app` path, validation results, and whether the live app was left running. Do not tell the user the running app has upgraded merely because the bundle was replaced.

Commit coherent tested changes frequently and push proactively. Preserve unrelated local work; do not bundle unrelated RFD drafts into a packaging commit.
