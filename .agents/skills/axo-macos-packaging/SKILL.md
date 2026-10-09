---
name: axo-macos-packaging
description: Build, validate, and deliver Axo's Finder-launchable Mac app. Use after any Mac or bridge change that affects the shipped development app, and when updating dist/Axo.app.
---

# Axo macOS packaging

## Delivery rule

Leo explicitly requires **always repackaging `dist/Axo.app` after validated Mac changes**. A successful Xcode build under DerivedData is not delivery. Build the bridge as well so the shipped native launcher and Pi extension stay compatible.

Keep project-specific operational guidance in `<axo-root>/.agents/skills/axo-*`, not the personal memory repository. Update this skill as the packaging workflow changes; do not turn transient build results or backup paths into permanent instructions.

## Build and validate

Resolve the Axo root from this skill's directory (`../../..`), rather than assuming the terminal's current directory is the repository root. Use:

```bash
cd <axo-root>
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
npm test
npm run typecheck
swift test --package-path apple/AxoCore
bash scripts/build-mac.sh
AXO_REPO="$PWD" apple/DerivedData/Build/Products/Debug/Axo.app/Contents/MacOS/Axo --axo-workspaces-self-test
codesign --verify --deep --strict dist/Axo.app
```

Run affected layout or phone tests as appropriate. A shared AxoCore change also requires an AxoPhone build. If validation fails after packaging, fix and rebuild/repackage; never present the failed artifact as ready.

`build-mac.sh` requires XcodeGen and the pinned Ghostty framework (`scripts/build-ghostty.sh` if absent). It builds the bridge, generates the Xcode project, builds AxoMac, stages the bundle, validates its Finder configuration, signs it ad hoc, and atomically replaces the packaged app.

## Safe bundle replacement

- Preserve the checkout-bound `AxoRepositoryPath` in Info.plist and check that its `scripts/run-pi.sh` exists.
- Stage on the same filesystem under `dist/`; verify the staged bundle before replacement.
- Use macOS `renamex_np` with `RENAME_SWAP` when an app already exists. Retain the previous bundle at the staging path for rollback.
- Never use `rm -rf dist/Axo.app` before installing its replacement. Reject a symlinked destination.
- Do not touch Application Support, conversation files, drafts, attachments, or running processes while packaging.
- Signing can change Mach-O bytes. Raw `cmp` is not a valid signed/unsigned executable comparison; use build UUIDs/code-section checks if needed, plus strict signature verification.

## Operational consent and evidence

Repackaging is authorized routinely. **It does not authorize a live app/Pi stop, restart, or relaunch**, nor physical phone installation. Ask separately before those operations; protect active work. Synthetic isolated native self-tests are not acceptance evidence for the live app.

After packaging, report the actual `dist/Axo.app` path, validation results, and whether the live app was left running. Do not tell the user the running app has upgraded merely because the bundle was replaced.

Commit coherent tested changes frequently and push proactively. Preserve unrelated local work; do not bundle unrelated RFD drafts into a packaging commit.
