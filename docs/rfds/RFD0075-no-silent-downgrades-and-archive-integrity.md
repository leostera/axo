# RFD0075 - Axo: no silent downgrades, and archive integrity before unzipping

- Feature Name: `no-silent-downgrades-and-archive-integrity`
- Status: Implemented (unreleased)
- Author: leostera
- Start Date: 2026-11-18
- Document Type: Proposal
- Amends: [RFD0023](RFD0023-one-axo-kept-alive.md) (handover and axod restarts), [RFD0048](RFD0048-release-artifacts.md) (`latest.json` gains `integrity`)

## Summary

Two changes to how a Mac gets a different Axo. Neither one moves a Mac backwards on its own:

1. **Axo and axod only move forward on their own.** axod restarts by itself only into a newer
   build than the one running. An older Axo that finds a newer axod leaves it running and offers
   an explicit restart. An older Axo opened while no Axo runs asks before it becomes the Axo that
   opens at login. The restart offer for an installed build only appears for a newer build.
2. **Archives are checked before they are unzipped.** `latest.json` gives each artifact's
   SHA-256 and size. The Mac updater and the install script download exactly that many bytes,
   check the hash, and only then unzip and check the signature.

Requiring a Developer ID certificate stays deferred. Releases are not signed with Developer ID
today (RFD0021 lists Developer ID distribution as not done), so requiring it would refuse every
real release.

## Motivation

**Downgrades.** Before this change, any difference between the running axod's build and the
app's bundled axod build restarted axod. Anyone opening an older copy of Axo, such as one in
`~/Downloads` or `.Axo.app.previous`, restarted a newer axod into an older build. That killed every
shell and Pi turn, and left old code reading state that newer code had written. With no Axo
running, the same old copy registered itself as the login item without asking. The menu bar
already offered only newer builds (`AppUpgrade.choose` uses `>`), but the reopen offer for an
installed build used `!=`.

**Integrity.** The signature check is the authenticity boundary, and it is sound: an Apple
anchor, the bundle ID, the team, nested code, strict validation, and release metadata. But it can
only run after the archive has been downloaded and unzipped. Nothing limited the download or what
it unzipped to. Anyone who could serve `/cdn/<artifact>.zip` could fill the disk, for example
after a CDN or origin compromise or a wrong upload. The bytes are immutable and content-addressable
by construction (RFD0048), so their digest can be published once and checked before anything reads
them.

## Guide-level explanation

### Opening an older Axo

Leo quits Axo and opens an old build from Downloads by mistake:

- Nothing else runs, and the Axo that last registered the login item was build 343. This copy is
  build 340, so Axo asks: "Open an older Axo?" Cancel exits and changes nothing.
- If he opens it anyway, the newer axod (build 87) keeps running. The splash says "A newer axod
  (build 87) is running", with **Restart axod with This Axo**. Settings shows the same and offers
  **Restart axod…** behind its usual confirmation. Nothing restarts until he picks it.

A newer Axo (a `bazel build` to `dist/Axo.app`, or an update) still restarts axod into its newer
build automatically, as before.

### A release

`bazel run //:publish` writes:

```json
{
  "version": "0.72",
  "build": 344,
  "axodBuild": 88,
  "commit": "0123456789abcdef0123456789abcdef01234567",
  "artifacts": { "aarch64-apple-darwin": "axo-0.72-0123456789ab-aarch64-apple-darwin.zip" },
  "integrity": {
    "aarch64-apple-darwin": { "sha256": "<64 lowercase hex>", "size": 104857600 }
  }
}
```

The updater and `curl … /install | sh` download at most `size` bytes. They refuse a body of
any other length or digest, then unzip.

## Reference-level explanation

### Handover and axod restarts (amends RFD0023)

- `DaemonBuildChange.between(running:bundled:)` returns `none`, `upgrade` or
  `downgrade(running:)`. `DaemonController` restarts axod on its own only for `upgrade`. For
  `downgrade` it sets the status `newerDaemonRunning(running:bundled:)`, which does not count as
  running, and does nothing else. The explicit `restartDaemon()` (splash or Settings) is the only
  way to an older axod.
- When the recorded axod definition differs from this bundle's, which means another copy
  registered axod, `DaemonController` first sends one health check. If a newer axod answers, it
  is kept, as above. If none answers, or launchd reports the job failing to run, Axo registers its
  own axod definition again, as RFD0023 describes.
- `AppAgentController` records the `CFBundleVersion` of the Axo that last registered the login
  agent (`dev.leostera.axo.app.registeredBuild`). `LaunchHandover.decide(…, registeredBuild:)`
  returns `startOlderAgent(registeredBuild:)` instead of `startAgent` when the opened Axo's build
  is lower than that one. The opened Axo asks before handing over. A Mac that has no recorded
  build yet, because nothing registered since this change, decides as before.
- `InstalledUpdateCheck` offers a restart only through `AppUpgrade.choose`, so only for a newer
  installed build.

Two RFD0023 behaviours change: the handover table's "no other Axo → `startAgent`" row, and
"Restart axod if its build changed".

### `integrity` (amends RFD0048)

- `integrity` maps each target in `artifacts` to `{ sha256, size }`, with exactly the same keys
  as `artifacts`. `sha256` is 64 lowercase hex characters over the uploaded archive's bytes. `size`
  is its length in bytes, a positive safe integer.
- **Publisher.** `publish.sh` hashes the object that `/cdn/<filename>` serves. Usually that is the
  archive it uploads. When it reuses an existing immutable archive (one with the same CDHash), it
  hashes the existing object, because the two zips' bytes may differ even when their signed
  content is the same.
- **Worker.** `parseRelease` accepts a pointer with or without `integrity`, so the pointer
  published before this change keeps being served. When `integrity` is present, its keys must match
  `artifacts` exactly, and the Worker serves it unchanged. Unknown keys are still refused.
- **Mac updater.** It fails closed. `PublishedBuild.archive(origin:)` throws when the selected
  target has no integrity entry, so such a release is never offered. `install` downloads with a
  cap of exactly `size` bytes and requires that many. It then checks SHA-256 before `ditto`
  unzips anything, and only then checks the signature and metadata as before.
- **Install script.** It fails closed too. For a `latest.json` it reads the selected target's
  `sha256` and `size`, downloads with `curl --max-filesize`, and compares the length (`stat`) and
  the digest (`shasum -a 256`) before `ditto`. The legacy bootstrap path, used only while no
  pointer exists, is unchanged.

### Rollout

The Worker the site currently runs refuses unknown keys and would answer 503 to a pointer
carrying `integrity`. Deploy the Worker first, then publish the next release. Between the two, the
live pointer has no `integrity`. In that window, fresh installs fail with "This release has no
integrity for <target>" rather than install unchecked, so publish right after deploying. Mac
updaters already installed ignore the new key and upgrade as before. The first updater that
requires `integrity` is in the release that introduces it.

## Drawbacks

- The rollout has a short window in which fresh installs fail closed.
- `newerDaemonRunning` leaves the older Axo without a usable axod until the person chooses. This
  is the point of the change, but it is a new state to explain.
- The hash proves the bytes match the manifest, not who published them. The manifest comes over
  HTTPS from the same origin. Authenticity still rests on the code signature, which is checked
  after unzipping.

## Alternatives

- **Do nothing.** Silent downgrades keep killing terminals, and a hostile or wrong archive can
  fill the disk before anything checks it.
- **Objects in `artifacts` (`{ file, sha256, size }`).** Installed updaters decode `artifacts` as
  a map of strings and would stop upgrading. A separate key keeps them working.
- **A size cap only.** It bounds the damage but does not catch wrong bytes before unzipping.
  Keep it as defence in depth (1 GiB), and use the exact size when it is known.
- **Developer ID and revocation checks (`kSecCSEnforceRevocationChecks`).** These are the right
  end state, but they need Developer ID signing and notarization first (RFD0021, RFD0063).

## Unresolved questions

- When releases are Developer ID signed and notarized, add
  `certificate leaf[field.1.2.840.113635.100.6.1.13]` to the updater's requirement, and turn on
  revocation checks.
