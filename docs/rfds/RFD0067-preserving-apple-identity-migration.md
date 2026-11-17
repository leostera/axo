# RFD0067 - Axo: preserving the Apple app-family identity

- Feature Name: `preserving-apple-identity-migration`
- Status: In progress — coordinated rollout explicitly approved; preservation unproven
- Author: leostera
- Start Date: 2026-11-17
- Document Type: Implementation design
- Related: [RFD0063](RFD0063-apple-distribution-and-apns.md), [RFD0064](RFD0064-universal-axo-mobile.md)

## Summary

Move the installed mobile family to `dev.leostera.axo`, `dev.leostera.axo.watch` and
`dev.leostera.axo.watch.complications`, preserving account sign-in, approval identities,
preferences and recording ownership. The Mac already uses the canonical root and requires
no identity change or restart. The person explicitly approved shared migration Keychain access,
development provisioning and coordinated owned-device installation. No uninstall, reset,
certificate replacement, production push or app submission is authorized. APNs is scoped only
to the canonical root, never the old phone identity.

## Motivation and guide

Changing a bundle identifier creates a different installed container. It does not carry over
UserDefaults, Keychain defaults or WatchConnectivity's paired-app channel. Replacing an ID in
a build file cannot constitute migration. Keep the source usable and its data intact until the
new family has proved preservation. The old-ID build exists only as this bounded source path;
remove its product delivery role after the coordinated migration has actually succeeded.

The first vertical slice is a preservation probe, not the full transfer. The existing app places
only its already-existing encrypted Enclave reference and expected public key in a device-only,
explicitly entitled shared Keychain item. It never generates a key, exports plaintext private
key material, copies a token, or sends data through the harness/network. The canonical probe
restores that reference and proves signing possession in its own signed app context. Its root
must not create the ordinary account/workbench/companion objects or any new signer. A keyless
source is reported explicitly rather than manufactured into a successful key-restoration test.

Only after this works physically should the complete credential/preferences importer be enabled.
Both probe and later importer handle the phone/iPad and Watch independently on their own Enclaves;
a phone reference must never be restored on the Watch or vice versa.

## Contract

- Preserve the exact source bundle identities and default Keychain namespaces while staging.
  The old Watch's shipped wildcard default group is not silently replaced. Shared access is
  additional, explicit and device-only; derive its prefix from the actual signed profile.
- Source and destination roles have exact bundle-ID pairs. A mobile envelope cannot satisfy
  a Watch probe. Bound and parse the complete envelope before restoration or any effect.
  The destination must name the exact source attempt UUID acknowledged by the harness; an old
  shared record cannot satisfy a newer failed/locked preparation attempt.
- Read only an existing Enclave reference. Missing, malformed, locked or unsupported software
  key state must not invoke creation or fall back to a replacement key.
- Destination probes check exact public-key equality and a fresh signature. Never overwrite
  a pre-existing conflicting destination identity. A successful probe does not install the key
  in destination defaults and is not successful account migration.
- Probe reports contain only schema, run correlation, bundle identity, role and a fixed status.
  Never write tokens, references, public-key material, transcripts or audio into reports/logs.
- The later complete importer needs a durable staged journal, strict conflict handling and an
  exclusive startup gate before any authenticated companion/workbench or signer creation.
  Completion receipts must not retain/replay login credentials after local sign-out.
- Transfer only allowlisted preferences, including existing host input-key pins; never reset
  trust-on-first-use silently. Preserve phone companion ordering metadata and Watch account
  state/selected destination/sidebar preferences. New installation transport/client IDs remain new.
- Leave all source containers intact. Sharing a migrated session also shares its revocation;
  source sign-out is not an automatic cleanup operation.

## Watch and recording boundaries

The Watch has its own companion Keychain state and possible signing identity. Its sidebar
preferences also use an account-specific defaults suite, not only standard defaults. It requires
its own exporter/importer and physical validation, not a new phone package alone.

The widget is currently a stateless launcher. Its canonical target still needs signed-device
installation and artwork/launch validation. Existing Watch-face complication selections are
system-owned references to the old widget; do not claim a reload automatically retargets them.
If the public platform does not migrate that selection, explicitly guide/verify replacement.

An in-place source update can terminate an in-memory recording/transcription before any new
bridge code runs. Obtain an idle checkpoint before that update: no active dictation, queued
voice result or unsent recording/draft. Refuse progression when source recording files or
outstanding transfers remain; do not cancel, delete or replay them to make the gate pass.
Preserving a file is not proof that its original account/host/session ownership transferred.

## Validation and rollout

Before installation, inspect the actual installed identity and Keychain scope on each device.
An already-canonical Watch must not be treated as an old-ID source or have its existing default
Keychain group narrowed without preservation proof. A configured build graph is not an installed
app inventory. Unreachable Watch inspection blocks its rollout rather than permitting a guess.

1. Unit-test the probe parser, role binding, expiry, conflict and no-creation behavior with
   synthetic references/software signers. Test reports for secret exclusion.
2. Build signed source/canonical probe variants using existing implementation, with explicit
   development profiles and separate mode Info plists. Keep normal simulator/product paths
   unchanged. Regenerate Xcode through Bazel.
3. After source-idle confirmation, install the source in place; verify its bounded report.
   Install the gated canonical probe without deleting the source; verify cross-app restoration
   on both mobile devices and independently on Watch. Stop on any unproved preservation.
4. Implement and test the full token/preferences journal/importer, including locked storage,
   write failures, crash/retry and sign-out anti-resurrection. A preservation probe alone is
   not permission to remove the gate or call the migration complete.
5. Verify actual account/approval continuity, Watch pairing/transcription and widget launch;
   only then retire the old product delivery path. Retained source containers need separate
   cleanup approval. No Mac daemon/session restart is needed.

## Alternatives and costs

A fresh sign-in/re-enrollment is simpler but contradicts preservation and is not authorized.
Blindly granting the canonical app every old Keychain group does not transfer private defaults
or prove Enclave accessibility, and grants more access than a narrow envelope. Copying containers,
keys or credentials through the coding harness is forbidden. A large speculative importer before
physical key proof risks building on an unverified primitive, so prove the narrow slice first.

The two signed identities must coexist during staging. Provisioning, cross-app Enclave access,
Watch transport changes and complication selection are genuine physical/platform dependencies;
unit tests cannot certify them. Browser locks/login and unreachable devices are rollout blockers,
not reasons to reset identities or bypass safeguards.
