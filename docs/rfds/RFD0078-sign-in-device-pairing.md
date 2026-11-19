# RFD0078 - Axo: the phone links devices

- Feature Name: `phone-led-device-linking`
- Status: Accepted; in implementation
- Author: leostera
- Start Date: 2026-11-18
- Document Type: Proposal
- Amends: [RFD0077](RFD0077-root-of-trust-for-answers-and-secrets.md) (physical QR bootstrap and explicit delegation of device-management authority)

## Summary

The phone is the linking hub. Another Axo signs in and displays a private QR code; on the existing phone, **Profile → Linked Axos → Link another Axo** opens the camera. Scanning leads to **Allow / Don’t allow** for that exact device and scope. The first phone is bootstrapped from a trusted Mac’s private QR code, which authenticates both the phone key and the Mac input key in one flow. Signing in alone never confers authority to approve actions or manage devices.

The person chose the WhatsApp-style direction: the phone scans the device being linked, not a tiny fingerprint comparison scattered through Settings and failed chat actions. Existing keys and sign-ins are retained.

**Terminology:** the action is **Link another Axo**, under **Linked Axos**. A linked computer is a platform-neutral host (Linux, Windows or Mac); Mac below names the initial signed native bootstrap implementation, not the domain model. Host keys and encrypted bundles use `hosts`, not `macs`.

## Motivation

The old flow starts in `AllowedDevices::check` only after the first answer fails, queues a device, and publishes `DeviceRequested`. The Mac app does not present that event; its Devices settings page polls only while open. Only local signed Axo.app can allow a device, and private input later requires a separate manual comparison of the Mac key. The trust requirement consequently looks like a broken answer followed by a hunt through Settings.

A pairing phone is a distinct capability. An existing device allowed to answer is not automatically promoted to managing other devices.

## Guide-level explanation

### A new account

The person signs in on the phone through Cloudflare. Axo creates or restores the phone’s local signing identity; it never replaces an existing key or silently falls back to software. With no linked Macs, Linked devices explains that the phone is ready to become the hub.

On the first Mac, Axo’s Devices page offers **Sign in with Cloudflare**. Native OAuth creates the account host-pairing capability and redeems it locally: the person does not copy the existing eight-character host code. The temporary native session is not persisted and is signed out after linking; axod retains its independent host credential. An already linked Mac is never silently re-linked by this flow.

The person chooses **Show linking code** on the other Axo (the signed Mac app in this initial bootstrap implementation). Its trusted native UI displays a private QR code. On the phone, **Profile → Linked Axos → Link another Axo** opens the camera. Scanning binds this phone to that Mac, grants explicit device-management authority there, and confirms that exact Mac’s input key. There is no later fingerprint hunt when entering a password.

The phone gains authority only for Macs explicitly linked this way. A Cloudflare session and an empty-looking host listing do not grant authority over some other Mac.

### Add an iPad or another client

After a fresh sign-in, a client with no saved device links and existing account hosts opens Linked devices and displays a QR code. A client can also choose **Show linking code** manually.

On the existing phone, Link a device scans this private code. The phone shows:

> **Link this iPad?**
>
> This device can approve requests and enter sign-in details on the Macs linked to this phone. It cannot link more devices.
>
> **Don’t allow** · **Allow**

Allow signs a separate, scoped responder grant for each Mac this phone can manage. The candidate receives the Mac keys through the encrypted camera-authenticated channel and continues without a second first-use comparison. Don’t allow transfers no keys and grants no rights. Restoring an existing session does not repeatedly reopen enrollment.

### Manage devices and recover

Linked Axos lists the computers and other Axos linked through the phone. Unlink removes a responder’s approval authority without deleting its sign-in, app container or conversations. A revocation is scoped to the particular linking generation, so replaying an old unlink cannot remove a later enrollment of the same key.

An existing trusted Mac can bootstrap a replacement phone through a fresh private QR. It does not automatically remove the lost phone. If all trusted devices are lost, the product needs explicit recovery; it must never reset trust merely because the person signed in again.

## Reference-level explanation

### Mac-to-phone bootstrap

`axo.device.pairing.create` and `axo.device.pairing.cancel` are local signed-Axo.app-only methods. They are excluded from the generic CLI. They are not reachable through the relay or ordinary agent confirmation UI.

A five-minute invitation binds its version, random ID, account ID, stable host ID, expiry and current Mac input public key. Its private QR capability is a fresh ephemeral P-256 signing key. It is not a persistent device identity and is never sent to the Worker. The QR is an `AXO-LINK-1:` payload, not a URL to be fetched.

The phone signs the canonical `axo-link-phone/v1` message with its existing device key and with the QR capability. The message binds every invitation field, the candidate public key, its name encoded as UTF-8/base64 and the literal `hub` role. The relay transports only the two signatures and public claim fields.

The Mac verifies both signatures and the current account, host, expiry and invitation ID before atomically saving the phone as an allowed manager. The invitation admits one recipient. Identical retries return the same receipt only while that recipient remains allowed; an uncertain retry cannot re-grant a revoked key. Restart discards outstanding invitations rather than preserving a secret that can later be replayed.

The receipt is signed under the private QR capability over the exact claim in a separate `axo-link-phone-receipt/v1` domain. The phone verifies it before writing device links or confirming the Mac input key. An HTTP success alone is not a trust anchor.

### Phone-to-client linking

The candidate creates a five-minute `AXO-CLIENT-LINK-1:` code containing its public enrollment request and a random 256-bit symmetric camera capability. The request signs its account, random ID, expiry, key and name under `axo-link-recipient/v1`, proving possession of the recipient key.

Only the public request goes to the account’s blind mailbox. The phone reads the capability physically, verifies the candidate proof, and asks the person before sending grants. Each `axo-link-grant/v1` signature binds the account, stable recipient Mac, request ID, expiry, candidate key/name, manager key and literal `responder` role. The recipient proof remains independently verified by each Mac. Neither an OAuth session nor an ordinary answer permission can create a management grant.

The Mac verifies the current manager permission at application time. A separate durable consumed-grant ledger is written before the recipient is allowed; an uncertain write can fail closed, never re-apply a revoked grant after restart. Limits bound outstanding consumed grants and allowed devices.

The phone returns an AES-GCM encrypted bundle through the blind mailbox. Its associated data binds the account, candidate ID/key and expiry. The cloud never receives the symmetric capability. The candidate rejects changed bindings, duplicate host entries, malformed Mac keys and any implicit management elevation. Only then are Mac input keys confirmed locally.

### Blind mailbox

`/api/v1/account/devices/pairings` accepts bounded native-session operations: create, poll, complete and cancel. Records are account-local, session-owned, capped at four per session and 32 per account, and expire after five minutes. A candidate cannot complete its own mailbox. Another account cannot read or settle it. Completion is terminal: an identical ciphertext retry is idempotent; a changed ciphertext is refused. The mailbox carries no signing private key or camera capability and cannot manufacture an acceptable pairing result.

`/api/v1/account/devices/link` is transport for bound bootstrap, grant and revocation proofs. Each host independently enforces the proof and its authority. The Worker is not the issuer of trust.

### Revocation

`axo-unlink-device/v1` binds the account, Mac, original link ID, expiry, recipient and current manager. Unlink cannot remove a manager, cannot apply to a different enrollment generation, and cannot be replayed to remove a subsequently re-linked device. Removing a management phone remains a protected local Mac action. A removed manager cannot issue additional responder grants.

### Persistence and UI

Allowed-device records gain an explicit management bit, default false for existing entries. Old answer permissions never silently become delegation privileges. Device keys, hardware/software kind and credential namespaces remain unchanged. Scoped grants and revocations remain distinct from agent elicitation messages, so Pi’s advisory Yes/No UI can never settle them.

Clients store verified public trust anchors under the account and exact current device key. Missing or unreadable enrolled identity storage fails instead of creating a replacement. Camera code and QR generation stay in native UI. Codes are private capabilities: never log them, put them in relay URLs, upload camera frames, or include live codes in agent screenshots. Simulator/UI tests use isolated software identities and a local fake mailbox, never real credentials or account endpoints.

## Invariants

- Login is not device-management authority; a candidate cannot authorize itself.
- The cloud cannot substitute recipient, account, host, scope, expiry or authenticated input key.
- The first trusted-phone bootstrap requires the private code from signed local Axo.app.
- Management is explicit and narrow; newly linked responders cannot link more devices.
- An answer signature, pairing proof, management grant, receipt and unlink signature have distinct signing domains.
- Consumed and revoked grants never become fresh grants after a replay or restart.
- A candidate receives no trusted input keys on denial, failed authentication, account switch or stale completion.
- No account, installation, signing identity, hardware-backed key or existing approval is silently reset.

## Testing and rollout

Keep the existing RFD0077 adversarial checks. Add protocol/crypto tests for account/key substitution, expiry, one-recipient QR use, altered receipts, domain separation and encrypted bundle tampering; durable-store tests for revocation and replay across reopen; native model tests for scan → allow/deny → candidate reconciliation without a second fingerprint check; Worker tests for session/account isolation, bounded mailbox state and terminal races; and phone/tablet UI tests for Profile → Linked devices and the private QR presentation.

The Feynman model `specs/elicitations/device-linking.ts` separates physical bootstrap, current management authority and signature-domain checks. Login-only, forged and replayed-answer traces must never link a relay-owned key.

Publish matching daemon, native apps and Worker only from tested integrated main. Existing host/user credentials and both Watch installations remain untouched. Mac activation still requires an idle checkpoint; no agent should scan a live code, approve its own enrollment or bypass an OS camera/device lock for validation.

## Drawbacks and boundaries

QRs are bearer capabilities for a short physical exchange; someone who can read a private code must be treated as having seen it. This protocol does not defend a fully compromised device OS. Signing-domain checks do not substitute for keeping the code out of logs, URLs and agent-visible artifacts.

Each Mac retains independent authority. A phone can delegate only the Macs it actually manages, not every host the cloud lists. Some offline targets may not finish linking; partial/uncertain outcomes must be shown and reconciled without blindly replaying consent.

Initial implementation targets the signed Mac app and native iPhone/iPad clients. Browser candidate UI and a trusted Windows/Linux bootstrap surface require their own platform implementation; they must not fall back to account-login trust. Full lost-all-devices recovery and ownership transfer remain separate explicit flows.

## Alternatives

- Keep failed-answer-driven enrollment: rejected as a confusing discovery mechanism.
- Enlarge the fingerprints: does not eliminate repeated Settings trips or the second key check.
- Trust every signed-in device: rejected because it lets the relay manufacture approval authority.
- One account-wide bearer key: rejected because it merges revocation boundaries and bypasses per-host authority.
- Promote existing answer devices automatically: rejected; answering and managing devices are different privileges.
