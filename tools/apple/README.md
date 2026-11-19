# Operated Apple releases

Reusable code lives here; run state, approval receipts, profiles, device inventories, signed staging copies and artifacts stay in a private directory **outside Git**. Builds and tests still use Bazel. None of these tools creates certificates, changes provisioning, exports keys, resets apps or approves its own actions.

## Checks

```sh
bazel test //tools/apple:test
bazel build //tools/apple:typecheck
```

The tests exercise parsing, read-only defaults, scoped-approval requirements, source/version boundaries, private state directories and exclusive attempt fences. They do not prove Apple acceptance or physical-device delivery.

## Inspect the permission owner

`python3 tools/apple/inspect_permissions.py` reads the running daemon's report, verifies whether its executable matches the installed helper and reports whether it is its own responsible process. Unavailable ownership metadata stays unknown. It never reads or edits TCC databases, grants access, resets permissions or restarts a process. A GUI toggle is not proof that this running code identity is admitted.

## Prepare exact-source evidence

From clean committed main:

```sh
SOURCE=$(git rev-parse HEAD)
python3 tools/apple/release_gates.py --source "$SOURCE" --run-dir "$PRIVATE_BUILD_RUN"
```

The gate runs Mac/mobile/Watch/companion/client tests, daemon/recovery tests, web menu/elicitation/browser tests, tooling checks, the signed full-family APNs gate, phone/tablet slash-menu UI tests and Xcode generation. It records `build-evidence.json` with the source, version/builds and SHA-256 of the actual Mac ZIP and full companion IPA. It rejects dirty/changing source and missing/skipped artifacts. Retain completed evidence; use a fresh directory for a new run.

## Sign and notarize the Mac app

Use the portable `@leostera/macos-signing` SDK as a separately installed, reviewed operator tool. `--tool-root` names its package directory; this repository does not depend on a maintainer's Cinex checkout or global Bun link. The initial reviewed upstream is Cinex commit `12a6bebf6a13f721691e46a31ea13089f876c136`. Follow its shared macOS-signing skill; credentials remain host/team references outside Git. Do not put `.p8` files or private keys here.

```sh
bun tools/apple/sign_macos.ts --help
bun tools/apple/sign_macos.ts --mode local --app "$BAZEL_APP" --source "$SOURCE" \
  --tool-root "$SIGNING_SDK_PACKAGE" --run-dir "$PRIVATE_TRIAL"
# Only after clean pushed-main provenance and separate Apple-upload acceptance:
bun tools/apple/sign_macos.ts --mode release --app "$BAZEL_APP" --source "$SOURCE" \
  --tool-root "$SIGNING_SDK_PACKAGE" --run-dir "$PRIVATE_NOTARY_RUN" \
  --approval-file "$APPLE_UPLOAD_RECEIPT"
```

The adapter uses `bazel/apple/macos-signing-policy.json`, preserves identifier metadata for every signing target, makes only its fresh owned copy writable, and verifies all identifiers plus the final main code-directory hash against the exact Bazel input. Diagnostic runs cannot be promoted. `--mode resume` uses the original retained directory and source; never replay an ambiguous upload. `--mode verify` does not submit again. Preserve accepted/rejected/interrupted runs and submission IDs.

After the app **and** DMG are Accepted, stapled, Gatekeeper-verified and mounted-payload-verified, package the stapled app as a ZIP outside Git and use the existing publisher:

```sh
AXO_NOTARIZED_ARCHIVE="$VERIFIED_STAPLED_ZIP" bazel run //:publish
```

The publisher checks clean primary pushed main, embedded source, Developer ID/team/runtime/timestamps, app ticket/Gatekeeper, code-directory equivalence before/after repacking, immutable content and exact served-byte integrity. It advances `latest.json` last. The updater remains ZIP-based; the SDK's DMG is retained separately rather than silently changing the download protocol.

## Install without resetting identities

Approval receipts are **correlation records, not cryptographic authorization tokens**. The operator must obtain real fresh scoped human acceptance through the supported approval mechanism. A JSON file cannot manufacture consent. Publication, Apple uploads, restarting active Macs and a legacy Watch account cutover are separate decisions. Check draft/recording safety near cutover; respect locks and protected input.

Mobile defaults to read-only checking. Install only the signed full companion artifact whose SHA matches source-bound evidence:

```sh
python3 tools/apple/install_mobile.py --source "$SOURCE" --artifact "$COMPANION_IPA" \
  --run-dir "$PRIVATE_MOBILE_RUN" --mode check
python3 tools/apple/install_mobile.py --source "$SOURCE" --artifact "$COMPANION_IPA" \
  --build-evidence "$PRIVATE_BUILD_RUN/build-evidence.json" --run-dir "$PRIVATE_MOBILE_RUN" \
  --mode install --approval-file "$ROLLOUT_RECEIPT" --devices iPhone iPad appleWatch \
  --watch-approval-file "$WATCH_SCOPE_RECEIPT"
```

The Watch requires a verified matching phone build first. A legacy namespace cutover requires the separately approved account-based path in `apple/DISTRIBUTION.md`; matching bundle IDs alone is not credential-preservation proof. No new device signer is created by this operation. Installation/launch attempts have exclusive receipts; inspect prior outcomes instead of retrying. Per-device `status.json` distinguishes locked/held/failed, installed, launched and connected states. Reports contain only fixed push/connection health metadata, never credentials or transcripts. APNs enrollment is not visible-notification delivery.

For a Mac, stage **`install_mac.py` and `common.py` together**, unchanged, in a private host cache. Use the expected published source, configured team and actual host approval receipt:

```sh
python3 install_mac.py --source "$SOURCE" --team "$APPLE_TEAM" \
  --run-dir "$PRIVATE_HOST_RUN" --mode check
python3 install_mac.py --source "$SOURCE" --team "$APPLE_TEAM" \
  --run-dir "$PRIVATE_HOST_RUN" --mode install --approval-file "$ROLLOUT_RECEIPT"
```

It pins the manifest, retains public-installer signature/integrity checks, preserves existing app data and daemon signing identity, and uses graceful SIGTERM only. Busy/unknown Sessions hold the cutover by default. `--approved-running-sessions` is permitted only when the human explicitly accepted restarting running Sessions; `--exempt-session` is not a substitute for that approval. An existing `install.lock` requires reconciliation, not deletion or blind replay. `--delay-seconds` can defer an approved self-hosted cutover. Auxiliary `idle`/`restart` modes are lifecycle fences for the pinned installer.

See [RFD0087](../../docs/rfds/RFD0087-verified-macos-downloads.md). Reuse these tools for the next version; do not generate another release-specific copy of their logic in `/tmp`.
