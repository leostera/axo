# RFD0048 - Axo: immutable release artifacts

- Feature Name: `release-artifacts`
- Status: Implemented (Axo 0.58)
- Author: leostera
- Start Date: 2026-11-14
- Updated: 2026-11-14
- Document Type: Proposal
- Amends: [RFD0021](RFD0021-bazel-only-build.md) (publication and updater contract)

## Summary

Use `/cdn/latest.json` as the single mutable release pointer. Its `artifacts` map selects immutable, version/commit/target-qualified archives. New updaters and installers pin the selected filename before downloading. Keep the old Mac URLs only as derived compatibility views so already-installed apps can upgrade.

## Motivation

A mutable `Axo.app.zip` loses the identity of what was downloaded and cannot distinguish architectures. Independent manifest/archive requests can race a publication. Immutable names make selection, diagnosis and rollback explicit without changing signature verification.

## Guide-level explanation

```json
{
  "version": "0.71",
  "build": 342,
  "axodBuild": 94,
  "commit": "0123456789abcdef0123456789abcdef01234567",
  "artifacts": {
    "aarch64-apple-darwin": "axo-0.71-0123456789ab-aarch64-apple-darwin.zip"
  }
}
```

Artifact filenames resolve relative to `latest.json`. Use the artifact's target, measured from the built executable, not the publishing machine's architecture. A universal Mac app uses `universal-apple-darwin`. Missing targets fail explicitly; an Intel build must never silently download an ARM-only archive.

## Reference-level explanation

- Store the pointer as `latest.json` and archives as `releases/<filename>` in the existing CDN bucket. Serve archives at `/cdn/<filename>` with immutable caching; the pointer is not cached.
- Version remains `major.minor`; build/daemon build retain their existing meaning. Commit is the full Git SHA resolved from the signed bundle's embedded commit. Filenames use its first 12 characters and must match the manifest version and target.
- Publish archives before the pointer. Never overwrite an existing immutable filename with different signed content. Interrupted publication leaves an unreferenced archive, not a pointer to missing data. A retry may reuse matching signed content.
- The current publisher builds one Mac app target per release. The map supports multiple targets, but parallel writers/merging independently published platforms are not introduced here: publication remains single-writer, and a new release must not inherit artifacts from older versions.
- New Swift updaters and the shell installer read `latest.json`, choose their exact target (or a universal Mac artifact), and download that immutable URL. The app verifies the signed bundle identity/team and its build/version against the captured release before swapping; it does not reselect latest after confirmation.
- `/cdn/Axo.app.json` is a compatibility projection of the pointer. `/cdn/Axo.app[.zip]` serves its ARM/universal archive for existing ARM clients. Until the first new-format publication, only those old endpoints may read the existing legacy bucket objects. New native updaters never fall back to old manifests. The shell installer may use the legacy ARM archive only on a 404 while the first pointer is absent, preserving fresh installations during the Worker-first rollout; malformed or unavailable pointers never trigger fallback. Remove these views only when pre-cutover clients no longer need an upgrade path.
- The available-update menu action is simply “Upgrade Axo”. On download, a separate visible progress window names the version/build/commit from the captured manifest passed to the installer, not a later background check or a build number presented as a version. It closes on failure or before restart. This UI amendment is implemented after 0.58 and is not yet published.
- Malformed pointers fail closed rather than selecting a different target or falling back to old data. Filenames are basenames, not paths, arbitrary URLs or traversal. Native signing remains the authenticity boundary.

## Rollout and validation

Deploy the Worker routes first: existing clients continue using legacy objects while no pointer exists. Publish the next version's immutable archive and pointer, then distribute the updated app. Do not publish or restart the active app as part of implementation testing.

Test pointer parsing, unsupported targets, universal fallback, traversal/mismatched identity rejection, immutable caching, HEAD/method behavior, compatibility projections, bootstrap behavior, and pointer/archive race avoidance. Run native updater tests, site/type checks, installer shell syntax checks and publishing-script tests without uploading production data.

## Validation evidence

All 79 standard Bazel tests pass. New tests cover strict release parsing, target identity (including x86_64 underscores), universal fallback, immutable/legacy HTTP responses, bootstrap-only fallback, malformed pointer rejection, HEAD/method handling, pinned snapshot URLs and downloaded bundle metadata. Publishing tests mock signing/Git/CDN/upload commands and exercise upload-before-pointer ordering, archive failure, server errors, reuse of matching signed content, conflicting immutable content and deriving the target from the built executable rather than the machine. Installer syntax is checked without running installation.

Axo 0.58 (Mac 329 / axod 80, commit `60bc894e2a20d877a6826eddb4e8e51861f22c1a`) was published as `axo-0.58-60bc894e2a20-aarch64-apple-darwin.zip`. The live `latest.json` advertises that immutable archive; the legacy manifest equals its compatibility projection, and the legacy archive downloads byte-for-byte identically. Immutable cache headers, downloaded signing validity and bundle metadata were checked. A probe compiled against the actual native updater source fetched the public pointer, selected the immutable URL and verified the downloaded signature/release identity without invoking installation. Seven-model codemode integration passed again using the downloaded release's helpers/resources. Worker deployment: `7a0ef22d-619e-49d6-ac54-a3e6dbdbe637`. The active app/Session was not restarted.

## Drawbacks and alternatives

- Cross-language parsing must agree, and legacy endpoints remain during the installed-client migration.
- Serving only immutable files without a pointer forces clients to know release versions; keeping mutable per-platform zips preserves the race and obscures identity.
- Concurrent multi-platform publication requires coordination beyond this single-writer publisher. Do not pretend sequential object writes are a transaction.
- Checksums and generic standalone Linux/Windows binary packaging can be added separately; this change does not claim those artifacts exist.
