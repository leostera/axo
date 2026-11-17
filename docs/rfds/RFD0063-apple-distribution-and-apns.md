# RFD0063 - Axo: Apple distribution and request push

- Feature Name: `apple-distribution-and-apns`
- Status: Draft — main phone identifier decision pending
- Author: leostera
- Start Date: 2026-11-16
- Document Type: Proposal
- Amends: [RFD0029](RFD0029-ask-the-person.md), [RFD0060](RFD0060-global-elicitation-inbox.md)

## Summary

Use the registered Axo product identity for intentional Apple signing/distribution and add APNs attention for pending requests. Keep Bazel as the build and generate Xcode configuration from it. Registration, provider credentials, distribution and real push testing are explicit account operations, not incidental build effects.

## Current state and first decision

The Mac identifier is `dev.leostera.axo`; the phone is `dev.leostera.axo.phone`, with watch and keychain configuration beneath the phone identity. The new root store record does not automatically update those targets or enable APNs.

**Decision pending:** (a) use `dev.leostera.axo` for the main phone app too (recommended), or (b) intentionally keep a separate phone record. Confirm platform/team settings before configuring profiles. A bundle change needs a deliberate keychain/account/trusted-device migration or explicit re-enrollment; no silent credential loss, key export or app-container deletion.

The full Mac app remains a direct-download product unless Mac App Store eligibility is separately established. Developer ID signing/notarization and iOS App Store/TestFlight signing are different release paths.

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

## Alternatives and open questions

Keeping foreground-only inboxes avoids provider infrastructure but cannot supply locked-phone attention. Silent-only pushes cannot replace user-visible alerts because Apple does not guarantee background delivery. A notification broker adds another data processor; direct APNs from the Worker is preferred only after its production transport is validated.

First resolve the phone bundle identity. Then verify the actual team, capability/profile/certificate availability, migration path and desired distribution channels. This draft does not claim any portal setup, key generation, notarization, upload or push delivery has occurred.

## Sources

- [Apple: add platforms](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms).
- [Apple: enable app capabilities](https://developer.apple.com/help/account/identifiers/enable-app-capabilities).
- [Apple: APNs requests](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns).
- [Apple: background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app).
- [workerd 4841: local versus production HTTP/2](https://github.com/cloudflare/workerd/issues/4841).
