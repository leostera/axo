# RFD0079 - Axo: account-based client access

- Feature Name: `account-based-client-access`
- Status: Accepted; in implementation
- Author: leostera
- Start Date: 2026-11-19
- Document Type: Policy
- Supersedes: the remote-device enrollment and manual input-key confirmation portions of [RFD0077](RFD0077-root-of-trust-for-answers-and-secrets.md), and [RFD0078](RFD0078-sign-in-device-pairing.md)

## Summary

Axo is Leo's personal system. A verified account session authorizes human clients to use that account's linked hosts, including answering explicit requests. Hosts join the relay using the existing short code. Local operation needs neither login nor relay connectivity. There is no primary phone, device enrollment or per-host client allowlist.

## Motivation

Device enrollment made normal phone/iPad use circular and blocked Linux approvals without providing a benefit the person wants. The person explicitly chooses to trust the authenticated account service rather than a separate device-management hierarchy.

## Guide-level explanation

Sign in on iPhone, iPad or the browser: the account's hosts and pending requests are available immediately. Create a short host-linking code from a signed-in client and enter it on a computer to connect that host. Answer Yes/No or enter private values directly; no QR, fingerprint hunt or second-device approval is required. Disconnect a host or sign out through existing account controls.

## Reference-level explanation

Account authentication, account-scoped routing, host credentials, session revocation and lease checks remain authoritative. Machine credentials and agent IPC are not signed-in human clients and cannot approve their own requests. Local signed-app/daemon verification and advisory Pi versus protected-tool distinctions remain.

Remove allowed-answer-device state, device-management RPCs/events, QR/bootstrap/grant/mailbox code, and fresh-sign-in enrollment. Clients no longer generate signatures as a prerequisite to answering. For the coordinated installed-client transition, the old optional proof field may still be parsed at the wire boundary; it never grants authority and no enrollment fallback runs.

Keep private-input HPKE encryption to the host key received through the authenticated relay, including request/origin binding, input validation, secret redaction and zeroization. Remove independent fingerprint confirmation. This intentionally does not defend against an actively malicious relay substituting keys or manufacturing an approval.

Pending requests still expire, settle once and reject stale host generations; an uncertain answer is never automatically retried. Notifications and cross-client settlement cleanup are unchanged.

## Preservation and rollout

Do not delete keys, credentials, opaque Secure Enclave blobs, app data, old enrollment files or defaults. Stop consulting obsolete records; an obsolete malformed allowlist must not block startup. Preserve canonical app identities, sign-in, preferences, recordings/drafts, migration safeguards and both Watch installations.

Ship a new immutable release from tested integrated main. Update relay parsers and daemons before clients that omit proofs. Install mobile updates in place while unlocked; Mac activation still requires an idle checkpoint. Replace enrollment tests with account isolation, human-versus-machine admission, signed-in unenrolled answers, private input without comparisons, notification actions and local/short-code flows.

## Alternatives and drawbacks

Keeping the QR system or only hiding its screens leaves the daemon and input-key blockers intact. A primary-phone hierarchy introduces recovery and delegation the person does not want. Broad rollback would lose unrelated improvements. The selected clean cutover reduces setup concepts, while explicitly trusting account credentials and the relay for authorization. Compromise of either can authorize access; this is the chosen boundary, not an end-to-end authority guarantee.
