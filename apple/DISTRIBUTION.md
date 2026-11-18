# Apple distribution foundations

Bazel remains the build. Xcode is generated with `bazel run //apple:xcodeproj`.
Building or inspecting an artifact never authorizes signing-account changes, an identity
migration, a restart, notarization, TestFlight/App Store upload, or public publication.

## Current delivery path

Continue direct, identity-preserving development installs using
`//apple/ExistingPhoneUpdate:ipa`. It is the universal old-ID phone/iPad build with its
existing watch/widget graph. Do not uninstall it, replace its credential namespace, or
install the canonical identity as if it were an in-place update. Follow
[AxoMobile/AGENTS.md](AxoMobile/AGENTS.md).

The canonical graph remains `dev.leostera.axo`, `.watch`, `.watch.complications`.
Identifier preparation is not credential migration. No app submissions are required for
these foundations, and none are performed by these commands.

## Inspect signing without changing it

```sh
bazel run //bazel/apple:distribution_preflight -- \
  --channel development --existing-installation /absolute/path/Phone.ipa

# Require the signed app AND its embedded profile to have sandbox APNs enabled:
bazel run //bazel/apple:distribution_preflight -- \
  --channel development --existing-installation --require-apns /absolute/path/Phone.ipa

# Future canonical distribution artifacts; no upload occurs:
bazel run //bazel/apple:distribution_preflight -- \
  --channel app-store-connect --require-apns /absolute/path/Axo.ipa
bazel run //bazel/apple:distribution_preflight -- \
  --channel developer-id /absolute/path/Axo.app
```

Other explicit channels: `ad-hoc` (device-limited distribution profile), and canonical
`development` without `--existing-installation`. Old-ID installation is development-only.
`--migration` additionally requires the root's exact default Keychain group first and
`<actual App Identifier Prefix>.dev.leostera.axo.migration` second, authorized by its profile.
It validates signing scope, not successful data migration.

The inspector verifies Apple/team signatures, explicit app IDs, real profile prefixes,
expiry, profile distribution class, the phone/watch/widget graph, authorized certificate
membership and Keychain/APNs scope. Developer ID additionally requires its certificate OID,
hardened runtime, secure timestamps and no debugging/JIT/library-validation bypasses on
embedded executable code. Current development/ad-hoc signing fallbacks cannot pass that gate.
It does not prove notarization, App Store validation, release provenance or device coverage;
the existing archive/install/publication gates still own those checks.

Inspection uses read-only system Apple roots and OpenSSL for CMS verification. Do not replace
that with `security cms`, which can import certificates into the default Keychain. Profiles,
development IPAs, credentials, device identifiers and Enclave references stay private.

The already-shipped old watch/widget development builds use a wildcard Keychain group from
their existing profiles. Only those exact old development identities retain that scope here,
to avoid an unapproved Watch credential-namespace change. Canonical and production artifacts
must have exact groups. Changing the old companions needs its own preservation proof, not a
quiet entitlement edit.

## APNs provider, not yet delivery

`packages/axo-api-worker/src/push/apns.ts` implements a single bounded attempt with
ES256 provider JWT reuse, explicit topic/environment scope, generic private request payloads,
expiry, request-specific collapse IDs, bounded feedback parsing and injectable transport.
No live registration endpoint, dispatch path or provider secret is enabled by this module.

Cancellation before dispatch sends nothing. Transport loss after dispatch is uncertain;
there is no hidden retry. `accepted` means Apple accepted the request, not device delivery.
Invalid-token feedback must be fenced against registration generation and Apple's timestamp.
Apple's current response guidance defers 5xx retries for 15 minutes; a short-lived request will
usually expire before then. `TooManyRequests` defers at least a minute. Provider-auth errors
are not treated as a reason to mint tokens repeatedly or switch endpoints.

Still required before live push:

- Explicitly approved Push Notification capabilities, replacement development profiles and
  scoped provider credentials in a secret store, never the app or source.
- Authenticated person-owned installation/token registration, rotation, sign-out/revocation,
  cross-account ownership and late-update/feedback fencing. Push enrollment grants no approval authority.
- A durable outbox committed with authoritative pending state, bounded owned dispatch and
  pending/ownership/expiry rechecks before attempts, including crash/uncertain-receipt behavior.
- Native permission/registration callbacks, current-account inbox-only taps and best-effort
  reconciliation; no notification action may approve a request.
- Explicit deployed HTTP/2 validation and real owned-device foreground/background/locked tests.
  Local fake-transport tests cannot prove Workers-to-APNs compatibility or OS delivery.

## Preservation probes before migration

The coordinated rollout is now explicitly approved under [RFD0067](../docs/rfds/RFD0067-preserving-apple-identity-migration.md).
That is task-specific authority, not an expansion of routine-update approval.

Build/check the source family with the temporary, default-off staging switch:

```sh
bazel test //apple/ExistingPhoneUpdate:preservation_archive_test \
  --//bazel/config:identity_preservation_probe=true --test_output=errors
```

The canonical development profile names in `config.json` are **Axo canonical mobile development**,
**Axo canonical watch development** and **Axo canonical complications development**. Download
these privately from the approved team; profiles and their device lists never belong in Git.
The canonical device target is `//apple/AxoMobile:AxoMobile_ipa`. Its executable signing gate is
`//apple/AxoMobile:preservation_archive_test` with the same probe switch; use
`--watchos_cpus=device_arm64` for the owned Watch graph. The normal, non-probe signing gate is
`//apple/AxoMobile:distribution_archive_test` without that switch. A skipped target or missing
IPA is not a successful build. Inspect both signed graphs and require the source and destination
migration groups to match for each device role before installing either. Canonical Watch/widget
signatures use exact default groups, never the profile wildcard or `com.apple.token` grant;
this is not permission to narrow an already-installed Watch namespace without preservation proof.

If the Watch already has a canonical app whose signed scope/state is unresolved, do not replace
it as a side effect of a phone probe. `//apple/AxoMobile:AxoMobilePreservation_ipa` is a gated,
mobile-only probe with no Watch/widget payload. Verify it with
`//apple/AxoMobile:mobile_preservation_archive_test` and the preservation switch; direct inspection
also requires `--migration --mobile-probe-only`. It fails to build without the staging switch and
cannot pass the ordinary full-family distribution gate. It is not a shipping app or Watch migration.

The source retains its default Keychain group first, adds only the migration group, and keeps
its normal UI. The canonical probe has a separate read-only root: no account, workbench,
companion activation or new signer. Invalid probe configuration stays gated. Shared envelope
bytes remain inside the device-only Keychain; only fixed status reports may reach the harness.

Launch correlation uses non-secret UUIDs: `AXO_IDENTITY_PROBE_RUN_ID` for each app attempt,
and `AXO_IDENTITY_PROBE_SOURCE_RUN_ID` on the destination, matching the successful source
report. A stale envelope cannot satisfy another source attempt. Read only the exact
`Documents/axo-identity-preservation.json` report, never dump a container/defaults/Keychain.
The report includes no token, public key, encrypted reference, account or recording metadata.

Inspect the Watch's actual installed identity first; do not assume an old-ID Watch from the
phone build graph. Source-idle confirmation is required before an update that could terminate
dictation. A verified probe is **not** token/preferences migration and is not authority to
remove the canonical startup gate, sign out/delete the source, or claim the move complete.

## Mobile token/preferences transfer

After physical preservation checks, the separate default-off switch
`--//bazel/config:identity_mobile_transfer=true` builds the signed source exporter and isolated
mobile importer. Do not combine it with `identity_preservation_probe`. Gates:

```sh
bazel test //apple/ExistingPhoneUpdate:mobile_transfer_archive_test \
  //apple/AxoMobile:mobile_transfer_archive_test \
  --//bazel/config:identity_mobile_transfer=true --watchos_cpus=device_arm64
```

`//apple/AxoMobile:AxoMobileMigration_ipa` contains no Watch/widget update. Its canonical-root
sandbox APNs entitlement does not by itself enable enrollment or delivery. Startup remains gated
until live account verification, exact key/absence and preferences checks, and the durable journal
commit. Source/destination launch correlations are `AXO_IDENTITY_TRANSFER_RUN_ID` and destination
`AXO_IDENTITY_TRANSFER_SOURCE_RUN_ID`. Read only `Documents/axo-identity-transfer.json`; no source
snapshot, defaults or Keychain dump may cross the harness. Keep original apps installed and never
sign them out as cleanup. A source-idle checkpoint is still required before updates.

The temporary migration package deliberately fails the ordinary distribution gate. Inspect it
with `--channel development --migration --mobile-transfer --require-apns`; add
`--existing-installation` and omit `--require-apns` only for its old-ID source. A completed mobile
transfer does not authorize replacing an unresolved pre-existing canonical Watch app.

## Canonical identity migration

`PhoneDeviceKey.stored` now fails closed on an unavailable or malformed existing identity.
It never falls back to a newly generated key after restoration failure, and preserves an
existing software identity rather than silently upgrading it. New software identities are
simulator-only. Token replacement updates the existing Keychain item instead of deleting it first.

`PhoneDeviceKey.restoreForMigration` accepts only a supplied bounded opaque Enclave reference,
restores without a creation fallback, checks the exact expected public key and verifies a
fresh signing challenge. Its injected tests use synthetic references/software signers, not
personal data or real Enclave keys. This is an import primitive, **not a complete credential/preferences transfer
or physical cross-app proof**. The staged preservation probe described above shares only an
existing encrypted reference and proves its use in the other signed app; no account migration
is enabled by it.

Still required: an explicitly enabled old-ID exporter, allowlisted device-only shared-Keychain
envelope, strict importer and exclusive startup gate before any signer creation, conflict and
locked-storage handling, idempotent crash recovery, preferences and pending-recording
preservation, and physical public-key/approval validation on both devices. Leave source state
intact. Sharing a session token also shares its revocation: do not sign out the old app as
"cleanup" while the canonical app still uses that same token. Retirement is separate approval.

Apple documents storing a Secure Enclave's encrypted representation as a generic Keychain
item and restoring it on the same Enclave. That is not a promise that Axo's existing reference
works across these two signed apps. Require physical proof before claiming preservation.

See [RFD0063](../docs/rfds/RFD0063-apple-distribution-and-apns.md).
