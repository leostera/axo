# RFD0087 - Axo: verified direct-download Mac releases

- Feature Name: `verified-macos-downloads`
- Status: Implemented (publication gates; native release evidence recorded per rollout)
- Author: leostera
- Start Date: 2026-11-19
- Document Type: Policy
- Amends: [RFD0063](RFD0063-apple-distribution-and-apns.md), [RFD0075](RFD0075-no-silent-downgrades-and-archive-integrity.md)

## Summary

Public Mac downloads require Developer ID Application signatures, Hardened Runtime, secure timestamps, a stapled app ticket and Gatekeeper acceptance. A same-team Apple Development signature is not equivalent. Local builds may retain development/ad-hoc fallbacks; the publisher refuses them. Existing public releases remain immutable.

## Guide-level explanation

Build through Bazel from clean, pushed main. Review `bazel/apple/macos-signing-policy.json` against the artifact's executable inventory. Use `tools/apple/sign_macos.ts` with the portable macOS signing SDK as a separately installed release-operator tool, not a runtime/build dependency on another product's checkout. Its reviewed upstream implementation comes from Cinex's `@leostera/macos-signing` package; the initial operated version is commit `12a6bebf6a13f721691e46a31ea13089f876c136`. Reuse the shared host's non-secret signing references and protected notary profile. Obtain explicit Apple-upload approval independently of publication and installation.

Sign code inside-out while preserving existing signing identifiers, particularly `axod`, which launchd records. Preserve/review entitlements rather than stripping or broadening them. The generic tool's plain re-signing does not retain every bare helper's custom identifier; the Axo operator adapter must preserve identifier metadata and verify every identifier against the original Bazel app. Never change Keychain ACLs, disable library validation, remove quarantine or register a new certificate as an incidental fix.

## Reference-level explanation

Bazel prefers an available Developer ID identity for the configured team. An operator signs/notarizes a staged copy, retains Apple's submission IDs, requires Accepted, staples the app, signs/notarizes/staples its DMG and verifies the mounted payload. Diagnostic signing runs are not publishable. Ambiguous uploads are reconciled by retained submission IDs, never automatically resubmitted.

The updater still consumes the immutable ZIP format from RFD0075. `AXO_NOTARIZED_ARCHIVE` supplies a ZIP of the verified stapled app to `bazel run //:publish`. The publisher compares its main code-directory hash with the exact Bazel build before and after repacking, deeply verifies signatures, requires Developer ID/team/runtime/timestamp evidence for the app, helpers and frameworks, validates its staple and checks Gatekeeper before any upload. The existing served-byte SHA-256/size, immutable-content check and latest-pointer-last ordering remain. The operator also validates the reviewed full nested inventory and all preserved identifiers. The generated DMG is retained as separate trust evidence; publishing a new DMG download format is not implied.

A staple is not a source-provenance substitute. The operator must bind clean primary main, published full source SHA, version/build metadata, signing policy, notary run and exact output bytes. A rejected or uncertain run is retained. A successful build, local signature, upload, Apple acceptance, installed metadata and healthy running daemon are separate evidence.

## Validation

Publisher fakes reject Development signatures, absent staples and Gatekeeper failures before CDN mutation. Existing wrong-archive, immutable-content, target, upload-failure and integrity regressions remain. Native release gates inspect every known Mach-O and framework, retained helper identifiers, accepted Apple IDs, app/image tickets, Gatekeeper and read-only mounted payload. Real installation then verifies app source/build and daemon readiness without uninstalling, resetting credentials or silently downgrading.

## Drawbacks and alternatives

Notarization requires network access and an authorized operator, and re-signing must not accidentally change helper identities or invalidate the source/archive comparison. Keeping Development-only distribution is easier but does not satisfy trusted direct downloads. Notarizing only a disk image leaves an unstapled app without its own offline ticket. The existing ZIP updater does not need a new manifest or installer format merely to distribute a stapled app.
