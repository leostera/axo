# RFD0090 - Axo: native headless Debian installer

- Feature Name: `linux-native-debian-installer`
- Status: Draft (candidate implementation; coordinator integration/publication required)
- Author: leostera
- Start Date: 2026-11-20
- Document Type: Implementation design
- Related: [RFD0054](RFD0054-linux-desktop.md), [RFD0074](RFD0074-retired-host-credentials-and-the-local-asset-cache.md), [RFD0087](RFD0087-verified-macos-downloads.md)

## Summary

Provide an amd64 `.deb` containing the headless Linux runtime, CLI and an opt-in
systemd user unit. Package installation never launches code, restarts users'
Sessions, changes pairing, or writes user state. The coordinator publishes an
immutable platform-specific artifact and SHA256 only after source integration;
Linux tooling never changes the shared Mac `latest.json`.

## Guide-level explanation

Verify the separately published SHA256, stop Axo before an update, and install
with `sudo apt install ./axo_0.86.0-102_amd64.deb`. Then, as the graphical/login
user, run `systemctl --user daemon-reload` and explicitly enable/start
`axod.service`. Agents must be available in the user manager's PATH. The native
terminal is optional and absent from this package. Headless Session/relay use
needs no display; desktop operations retain their existing session/lock guards.

An installation previously managed by a user-level unit or `~/.local/bin` link
keeps that override. The package does not delete or silently replace it. Inspect
and migrate such an installation deliberately before activating the package unit.
A running old daemon must be stopped before replacing its runtime resources.

## Reference contract

`linux/build_deb.py` takes Bazel's runtime archive and matching CLI, reads version
and build from config, verifies executable versions, and derives ABI dependencies
with `dpkg-shlibdeps`. Only a validated allowlist of executables and AxoPi JS files
is copied, never credentials, transcripts, model caches or developer backups.
Files live under `/usr/lib/axo`, CLI links under `/usr/bin`, and the user unit under
`/usr/lib/systemd/user`. There are no maintainer scripts or automatic activation.
User state remains `~/.axo` with daemon-owned permissions and migrations.

The packager requires the integrated transcript-retention and reopen-regression
commits as ancestors and checks that automatic transcript eviction remains off.
Release mode requires clean primary main matching a freshly fetched origin/main.
Explicit candidate mode permits local work but marks both filename and provenance
as non-release-eligible. A candidate cannot become a release by renaming it: the
coordinator must integrate and rebuild. Source SHA, ABI dependencies, binary hashes,
package SHA256 and environment are retained as machine-readable data, not a mutable
Markdown validation report. Publication is a separate operator action.

## Tests and rollout

Unit tests reject dirty/unintegrated release inputs and unsafe archive members.
A private fakeroot/dpkg sysroot exercises fresh install, idempotent reinstall and
update from an older real runtime. Daemons run directly with private HOME/XDG,
loopback relay and owned Pi fixtures, never via the live user manager. Verify
version changes and preservation of host identity, Session IDs, settings and
sentinel user files. Dependency resolution in an empty sysroot is not simulated:
smoke uses force-depends there, while actual binary execution verifies the native
host ABI. Report that distinction, the distro/kernel and source/artifact hashes.
Run the retention regression and headless conformance separately. No live install,
unlock/reboot, root service or shared latest-pointer mutation is part of this work.

## Limits and alternatives

This is a direct-download Debian/Ubuntu package, not a signed APT repository,
auto-updater, cross-distro Linux release or automatic rollback promise. Arbitrary
schema downgrades are unsupported. Hardware/compositor behavior remains outside
the headless package contract. macOS's signed-app-only pairing policy is not
implemented by adding a package; RFD0074's existing Linux exception is unchanged.

A self-extracting user installer would need a second file/service transaction
engine and its own upgrade recovery rules. Debian's package manager already owns
those file transactions, ABI dependency declarations and package database. A root
system daemon would run agents with the wrong authority and home. The previous
manual snapshot installer remains useful locally but is not a native distributable.
