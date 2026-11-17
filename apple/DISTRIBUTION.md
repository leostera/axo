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

## Canonical identity migration

`PhoneDeviceKey.stored` now fails closed on an unavailable or malformed existing identity.
It never falls back to a newly generated key after restoration failure, and preserves an
existing software identity rather than silently upgrading it. New software identities are
simulator-only. Token replacement updates the existing Keychain item instead of deleting it first.

`PhoneDeviceKey.restoreForMigration` accepts only a supplied bounded opaque Enclave reference,
restores without a creation fallback, checks the exact expected public key and verifies a
fresh signing challenge. Its injected tests use synthetic references/software signers, not
personal data or real Enclave keys. This is an import primitive, **not an implemented transfer
bridge or physical cross-app proof**.

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
