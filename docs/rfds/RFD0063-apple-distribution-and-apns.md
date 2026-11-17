# RFD0063 - Axo: Apple distribution and request push

- Feature Name: `apple-distribution-and-apns`
- Status: Draft — namespace approved; provider, key-restoration and signing-preflight foundations implemented; live rollout pending
- Author: leostera
- Start Date: 2026-11-16
- Document Type: Proposal
- Amends: [RFD0029](RFD0029-ask-the-person.md), [RFD0060](RFD0060-global-elicitation-inbox.md)

## Summary

Use the registered Axo product identity for intentional Apple signing/distribution and add APNs attention for pending requests. Keep Bazel as the build and generate Xcode configuration from it. Registration, provider credentials, distribution and real push testing are explicit account operations, not incidental build effects.

## Namespace decision

Previously the Mac identifier was `dev.leostera.axo`, while the phone/watch used `dev.leostera.axo.phone` and its descendants. The person approved a clean namespace cutover: main Mac and phone `dev.leostera.axo`, watch `dev.leostera.axo.watch`, WidgetKit `dev.leostera.axo.watch.complications`, and phone token service `dev.leostera.axo.access`. Configuration, Keychain entitlements and runtime logging use that namespace.

This approves the identifier layout, not installation, portal mutations, key generation or uploads. The new store record does not automatically enable APNs. Named provisioning profiles must match the expected signing team and explicit application identifier, using their actual App Identifier Prefix rather than assuming it equals the Team ID.

Automatic installation additionally requires an exact `phone.install_bundle_id` pin. An old `phone.install: true` flag is not consent to install a differently identified app.

The full Mac app remains a direct-download product unless Mac App Store eligibility is separately established. Developer ID signing/notarization and iOS App Store/TestFlight signing are different release paths.

## Release the existing improvements first

The person subsequently prioritized shipping the current improvements to the existing phone,
all owned Macs and the web before making AxoMobile (iPhone and iPad). Read-only device inspection
confirmed the phone still runs `dev.leostera.axo.phone`. The explicit, manual-only
`//apple/ExistingPhoneUpdate:ipa` target therefore builds the shared current implementation with
the installed phone/watch/widget identities and existing development profiles. Token storage is
selected from the signed app's recognized identity, retaining the exact old service in that build.
This updates the existing container in place; it neither creates the canonical app nor transfers
credentials between containers. Remove this bounded release path after validated canonical
migration and approved retirement. No automatic install target uses it.

Apple-account configuration, credential creation and tested cloud/release publication have
explicit rollout approval; app installation/restart remains a separate checkpoint. A read-only
portal inspection verified the canonical explicit root App ID, its real prefix and the expected
team. That initial inspection did not mutate capabilities, create profiles/keys or notarize; later owned-device development provisioning is recorded below.

## Owned iPad development provisioning (2026-11-17)

The owned iPad was already registered on the approved team. Its identifier was absent from the existing Xcode-managed old-identity phone profile, which the portal does not expose for editing. Created the manual **Axo owned devices development** profile for the exact existing `dev.leostera.axo.phone` App ID, using existing registered development certificates (including the original signer). Verified that its device set is exactly the original profile’s coverage plus the owned iPad, then installed it locally. The manual universal update target uses this profile; the old profile and watch/widget profiles remain intact. No device registration, new signing key/certificate, App ID/capability change, canonical migration or APNs setup occurred. Development profiles remain private local artifacts, never repository/CDN contents.

## Data migration gate

The old phone's session token lives in its default Keychain group, but the approval-signing key's Secure Enclave representation is stored in its private UserDefaults container. Sharing a Keychain group alone therefore cannot preserve the trusted device. The new identifier has a different app container.

Before installing over or retiring anything, stage an explicit old-identity migration build that retains the old phone/watch identities and containers. It must transfer only allowlisted state through an entitled, device-only shared Keychain envelope; never export private key bytes, tokens or transcripts through the coding harness or network. The new app must validate/import before any new signer can be created, handle locked storage and conflicting identities without silently replacing keys, and leave the source data intact until physical-device validation and explicit cleanup approval. Watch account refresh can use the new phone's authenticated companion path; pending recordings in the old app must not be erased.

That bridge/importer is not implemented by the identifier cutover. A new-ID installation cannot be represented as preserving old sign-in, preferences or trusted-device identity until the bridge is implemented and validated. Explicit sign-in/re-enrollment is an alternative only with the person's informed choice.

## Guide

A pending request produces a private, generic native alert even when the phone's foreground socket is suspended, subject to Apple's delivery and permission policy. Tapping opens the Requests inbox and revalidates current state. A notification never approves anything. Already-resolved requests cannot turn an old banner into permission.

## Contract

- Generate bundle identifiers, entitlements, profiles and Xcode settings from the existing build configuration. Preserve simulator/development workflows; official release gates must fail closed instead of shipping an accidental ad-hoc signature.
- Enable only required capabilities and regenerate affected profiles. Keep distribution keys and APNs provider secrets outside Git and app bundles. Development and production tokens/topics are separate routing domains.
- Register native device tokens through authenticated person-owned endpoints. Host/agent credentials cannot enroll or enumerate a person's push destinations. A push destination never becomes a trusted approval device merely by registration.
- Bind registration lifetime to account/install ownership; fence late updates and deletion feedback against newer registrations. Support token rotation, sign-out and revocation. Do not assume token length or log raw tokens.
- Persist dispatch intent with the authoritative pending-request transition. Recheck ownership, pending state and expiry before attempts; bound retries and reconcile after crashes/uncertain receipts. Provider acceptance is not proof of device delivery.
- Payloads contain only validated routing identifiers and generic copy, never question/form values, secrets or approval actions. Signed answers and sealed input remain unchanged.
- Use request-specific collapse IDs for coalescing and appropriate expiration, not as exactly-once delivery or remote-deletion guarantees. APNs may reorder or deliver late.
- Reconcile OS notifications from current pending state when the app runs. Background resolution cleanup is best effort, not a guarantee while locked/offline/force-quit. This corrects RFD0029's assumption that sending a resolved push with a collapse ID automatically withdraws a delivered alert.
- Native account-wide Mac notifications require person sign-in; never repurpose host credentials. Watch-native push and companion mirroring require an explicit platform decision.

## Validation and rollout

First configure and verify the chosen identity/signing graph without installing over active clients. Build the thinnest phone-to-provider slice with injected authorization/registration/network effects, deterministic outbox/rotation/sign-out races and Feynman properties. Mock APNs locally. A workerd maintainer reports production fetch HTTP/2 behavior differs from local workerd, so an explicitly approved deployed test remains necessary.

Only after approval: enable portal capabilities, create/store keys, regenerate profiles, install an owned device build and validate foreground/background/locked behavior with real APNs. Test cross-device answers and stale alerts without promising unconditional OS withdrawal. No automatic TestFlight upload, production push or daemon restart.

## Implementation checkpoint (2026-11-17)

The person requested these foundations without app submissions and with continued direct
development installs on the owned iPhone/iPad. The account-change elicitation timed out
(`cancel`): no new capability, profile, certificate or provider key was authorized or changed
in this checkpoint. No app was submitted, no APNs packet was sent, and no canonical app was
installed.

Implemented:

- Existing approval-key restoration fails closed, including malformed stored values and
  unavailable Enclave access. It does not generate a replacement/fallback or overwrite the
  stored reference on failure. Preserve an existing software identity; new software keys are
  simulator-only. Answer admission reports storage failure without sending.
- A migration restoration primitive takes only an existing bounded opaque reference, checks
  the exact expected public key and verifies a fresh signing challenge. Hardware effects are
  injectable; tests use synthetic references and ephemeral software keys. This is not the
  shared-Keychain exporter/importer or a cross-app preservation claim.
- Keychain token replacement updates rather than deletes first; a failed update cannot
  discard a usable credential.
- The APNs provider primitive implements scoped sandbox/production topics, ES256 JWT reuse,
  generic routing-only alerts, expiry, bounded feedback and one owned attempt with cancellation.
  No registration, dispatch endpoint, live credential or native remote-notification enrollment
  is connected. Acceptance is distinct from delivery; transport failures are uncertain.
- A read-only Bazel signing preflight covers development, ad-hoc, App Store Connect and
  Developer ID evidence. It verifies real profile prefixes, certificate membership, Keychain
  scope, APNs environment, companion identities and hardened/timestamped Mac code. It does
  not submit, notarize or install, and uses OpenSSL/system Apple roots rather than importing
  profile certificates into the person's Keychain.

Inspection found the old development watch/widget signatures retain their profiles'
wildcard Keychain group. Preserve that already-installed namespace until approved Watch
migration validation. The preflight permits it only for those exact old development
companion identities; canonical/production artifacts require exact groups, with the default
group first. Do not silently narrow an existing companion's namespace and claim sign-in was
preserved.

Remaining rollout gates:

- [ ] Approved capabilities, scoped provider secret and matching development profiles.
- [ ] Authenticated person-owned registration and account/install ownership, rotation,
      sign-out and stale-feedback fencing.
- [ ] Durable authoritative outbox, bounded dispatch, crash recovery and pending/expiry checks.
- [ ] Native permission/token lifecycle, safe taps and reconciliation.
- [ ] Device-only migration envelope, explicit exporter, exclusive startup importer,
      allowlisted preferences, conflict/locked/crash behavior and physical key/approval proof.
- [ ] Preserve Watch credentials/recordings; retire source only with explicit approval.
      Signing out a source that shares the migrated session token revokes that token for
      the destination too; retirement must not do that accidentally.
- [ ] Deployed HTTP/2 and real foreground/background/locked-device APNs verification.
- [ ] Developer ID/Apple Distribution credentials and channel-specific signing builds.
      Notarization and TestFlight/App Store submissions remain separate, unperformed operations.

Commands and limits: [Apple distribution foundations](../../apple/DISTRIBUTION.md).
Apple's current response documentation recommends waiting 15 minutes before retrying 5xx
responses, often longer than a request's lifetime. There is no provider-internal retry loop.

## Alternatives and open questions

Keeping foreground-only inboxes avoids provider infrastructure but cannot supply locked-phone attention. Silent-only pushes cannot replace user-visible alerts because Apple does not guarantee background delivery. A notification broker adds another data processor; direct APNs from the Worker is preferred only after its production transport is validated.

The namespace decision is settled. The checkpoint above distinguishes implemented source foundations from the remaining migration, account configuration, channel-specific signing and physical validation. The earlier owned-device development profile remains the completed portal setup. Canonical distribution signing, new provider/distribution credentials, notarization, app submissions and push delivery remain uncompleted.

## Sources

- [Apple: add platforms](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms).
- [Apple: enable app capabilities](https://developer.apple.com/help/account/identifiers/enable-app-capabilities).
- [Apple: APNs requests](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns).
- [Apple: background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app).
- [workerd 4841: local versus production HTTP/2](https://github.com/cloudflare/workerd/issues/4841).
- [Apple: storing CryptoKit keys in the Keychain](https://developer.apple.com/documentation/cryptokit/storing-cryptokit-keys-in-the-keychain).
- [Apple: sharing Keychain items](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps).
- [Apple: handling APNs responses](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns).
