# RFD0069 - Axo: a root of trust for the person's answers and typed secrets

- Feature Name: `answers-root-of-trust`
- Status: Accepted
- Author: leostera
- Start Date: 2026-11-18
- Document Type: Proposal
- Amends: [RFD0029](RFD0029-ask-the-person.md)
- Related: [RFD0013](RFD0013-cloudflare-oauth-and-host-pairing.md), [RFD0067](RFD0067-preserving-apple-identity-migration.md)

## Summary

The person's answers and the secrets they type must not depend on trusting the cloud or on
trusting every program that runs as them on the Mac. Today they do, in four places. This RFD fixes
all four with one idea: **what a client trusts is fixed by the person looking at two screens
once, not by an identifier the cloud or a local program hands it.**

1. **Devices are allowed at the Mac.** axod takes a remote answer only from a device key the person
   allowed in Axo.app on that Mac, after comparing the key's fingerprint with the one the device
   shows. A key it does not know is refused and waits in Settings › Devices.
2. **Clients seal only to a Mac key the person confirmed.** A phone (or browser) seals typed values
   only to an input key the person confirmed by comparing its fingerprint with the one Axo.app
   shows in Settings › Devices. The confirmation belongs to the key, never to a host ID.
3. **A device key never silently changes kind.** On hardware with a Secure Enclave, the phone never
   makes a software key. This is already the case on `main` ([RFD0067](RFD0067-preserving-apple-identity-migration.md)'s
   `PhoneDeviceKey`). This RFD records it as an invariant.
4. **Axo.app authenticates axod.** Before it says anything on `axod.sock`, or on the attach socket,
   a signed Axo.app checks that the peer runs code signed as axod by the same certificate that
   signed Axo.app. This is the same audit-token check axod already makes in the other direction.

## Motivation

RFD0029 says a relay bug "cannot ... turn a No into a Yes", and it says that typed values are
sealed so that "nothing else ever sees them ... the cloud". The code does not deliver either
promise against a cloud that is wrong on purpose, nor against an agent on the Mac:

- **Answers are self-certifying.** axod checks an answer's signature against `proof.key`, which
  comes in the same message (`crates/axo-server/src/devices.rs`). Anyone who can deliver an
  answer can make a key, sign `accept`, and approve any computer-use gate, money and sign-in pages
  included. RFD0029 accepted this because "the person trusts their account, which Cloudflare
  Access guards", but RFD0013 makes `/app` and `/api/*` public, behind OAuth and not Access.
  The anchor named in the RFD does not exist.
- **Input keys are pinned by a cloud ID.** The phone pins a Mac's input key under the host ID in
  the `axo.elicitation.requested` notice (`InputKeyPins.check(host:key:)`). A cloud that invents a
  host ID the phone never saw gets its own key pinned, on every request. RFD0029's "at first use
  only. After that, the pins hold" is false.
- **Axo.app trusts any listener.** Axo.app connects to
  `~/Library/Application Support/Axo/run/axod.sock` and believes whatever answers. It sends the
  person's typed values there in the clear. An agent running in a Pi shell, which has the person's
  uid, can unlink the socket and listen in its place, show its own question in Axo's trusted
  Questions panel, and receive the answer.

The 0.16 release built (1) and 0.18 removed it (`d74d1995`). The reason given was that the extra
step guarded against a cloud the person already trusts. That premise is wrong: what the person
trusts is their OAuth session and the Worker's secrets, which are a much larger surface. RFD0029
already names the way back: "If that changes, the place to bind a device to a Mac is pairing,
which happens in person anyway."

## Guide-level explanation

### A new phone answers for the first time

Leo installs Axo on a new iPhone, signs in, and an agent on Studio asks *Push to main?* He taps
**Yes**. The card stays, and the phone says:

> Allow this iPhone in Axo on Studio first: Settings › Devices shows it as **6520 7919 59be e144**.
> Then answer again.

On Studio, Axo's Settings › Devices lists *Leo's iPhone* under **Waiting**, with
`6520 7919 59be e144`. The characters match, so he clicks **Allow**. He taps **Yes** on the phone
again, and the push goes ahead. From now on the phone's answers count on Studio until he removes
it there.

If the cloud had sent an answer of its own, it would show up as a waiting device Leo does not
recognise. He clicks **Not mine** and nothing is approved.

### Typing a password from the phone

An agent on Studio asks Leo to sign in to a site. The input card on the phone says:

> Before your values go to this Mac, check that Axo there (Settings › Devices) shows this key:
> **1a2b 3c4d 5e6f 7a8b**. **It matches**

**Fill in** stays disabled until he taps **It matches**. After that, the phone seals to that key
without asking again, whichever host ID a notice names. A request that carries any other key asks
again, so a key the cloud swapped in gets a fingerprint that Studio does not show.

### An agent replaces axod's socket

An agent unlinks `axod.sock` and listens there itself. On its next connection, Axo.app reads the
listener's audit token. The listener's code is not signed as axod by Axo's certificate, so Axo.app
refuses the connection. It reports *the program on axod's socket is not axod* and sends nothing.

## Reference-level explanation

### Allowed devices (axod)

- `Devices` in `crates/axo-server/src/devices.rs` keeps the allowed devices in
  `<server directory>/devices.json` (mode `0600`, written atomically). It also keeps two lists in
  memory: devices waiting for the person, at most 8, and burned signatures, at most 1,024.
- `check(answer)` does the following, in order:
  1. Refuse an answer with no proof: `BAD_SIGNATURE`.
  2. Refuse a burned signature: `UNKNOWN_DEVICE`.
  3. Refuse a signature that is not over this answer: `BAD_SIGNATURE`. A key may only ask to be
     allowed with a good signature, so nobody asks in another device's name.
  4. If the key is allowed, take the answer.
  5. Otherwise, burn the signature and add the device to the waiting list (unless it is already
     waiting or the list is full). Publish `device.requested`, and refuse with `UNKNOWN_DEVICE`
     (`-32016`). The message names the device's fingerprint and Settings › Devices.
- Burning matters. An answer given before the device was allowed never counts later, so a device
  that the cloud allowed by tricking the person cannot cash in old signatures. Signatures are
  randomized, so answering again makes a new one.
- The local methods are as follows. `decide` and `revoke` are for Axo.app alone, by code
  signature, with the same `Only` check as `axo.elicitation.resolve`:
  - `axo.device.list` returns `{ allowed, waiting, inputKey }`. `inputKey` is the fingerprint of
    this Mac's input key (made on first use, as for input requests).
  - `axo.device.decide { key, allow }` allows a waiting device, or turns it away.
  - `axo.device.revoke { key }` removes an allowed device.
  - Changes publish `devices.changed`. The relay never forwards device events.
- The fingerprint is the first 8 bytes of SHA-256 over the public key, as four hex groups
  (`axo_seal::fingerprint`). Forging a key with a given 64-bit fingerprint takes about 2^64 key
  generations.

### Confirmed input keys (clients)

- `InputKeyPins` stores a set of confirmed keys, keyed by the key itself, in the phone's defaults
  (the web uses `localStorage`). `isConfirmed(key)` and `confirm(key)` are its only operations.
  Nothing is pinned implicitly, and the host ID plays no part.
- Before sealing, a client checks `isConfirmed(input.key)`. If the key is unconfirmed, it seals
  nothing and shows the key's fingerprint, the place to compare it (Axo on the Mac, Settings ›
  Devices), and an **It matches** action that calls `confirm`.
- This is a clean cutover. Old per-host pins (`axo.inputKey.<host>`) are ignored, and each Mac's
  key is confirmed once again.

### Device keys (phone)

`PhoneDeviceKey.stored()` restores an existing key or fails. It makes a Secure Enclave key only
where there is none, and a software key only in the simulator. This is on `main` already, with
tests in `DeviceKeyTests`. An existing software key is kept, so an enrolled identity does not
change behind the person's back. RFD0067's migration refuses to carry one over
(`unsupportedSoftwareKey`).

### Axo.app authenticates axod

- `AxodPeer` in `AxoClient` derives the requirement from Axo.app's own designated requirement by
  replacing its identifier with `axod`. axod derives Axo.app's requirement from its own in the same
  way (`axo_ipc::peer::app_requirement`).
- `UnixSocketTransport` and `TerminalAttachment` connect with a BSD socket, read
  `LOCAL_PEERTOKEN`, and check it with `SecCodeCopyGuestWithAttributes` and `SecCodeCheckValidity`
  before any byte is sent. A connection that fails is closed, and the caller gets
  `AxoClientError.untrustedPeer`.
- An ad hoc build has no certificate. Its designated requirement is a cdhash, which names no
  program, so it cannot tell axod from anything else. axod already refuses Axo.app's answers in
  such a build. The client matches that: it connects unverified, and it refuses to send typed
  values on `axod.sock` (`AxodConnection.resolveElicitation(values:)` fails with
  `untrustedPeer`). Signed builds, which are the only ones published, always verify.

### Linux hosts

The rules are the same on a Linux host: every remote answer, including the computer-use gate
and [RFD0059](RFD0059-linux-sudo-input.md)'s sudo confirmation and password, goes through the
same `check`. Linux has no signed Axo.app. [RFD0053](RFD0053-linux-computer-use.md) says that a
same-uid peer gains no right to approve, so `axo.device.decide` and `axo.device.revoke` refuse
every Linux caller. Until Linux has a trusted local surface to allow devices, a Linux host
refuses every remote answer with `UNKNOWN_DEVICE`, and its devices wait. This fails closed: a
Linux host can no longer be approved from a phone. That is a known gap, not a reason to trust the
same uid.

## Invariants

- An answer counts only if it is signed for that answer by a key the person allowed at that Mac,
  and was signed after the key was allowed.
- Only Axo.app, by code signature, changes the allowed devices.
- A client seals values only to a key the person confirmed against the Mac's own display.
- A device key never changes kind or identity without the person.
- Axo.app sends nothing on axod's sockets to a peer it has not verified, when it can verify one.
  It never sends typed values to an unverified peer.

## Testing

- Rust, `devices.rs`:
  - unknown keys wait and are refused;
  - burned signatures never count;
  - allowed devices survive a reopen;
  - revoked devices are refused;
  - only Axo.app decides.
- The Feynman spec `specs/elicitations/device-trust.ts` models a cloud that forges, replays and
  flips answers. Its properties are `onlyLeosAnswers`, `onlyHisKey` and `nothingFromBeforeTrust`.
- The Worker e2e test (`elicitations-e2e.test.ts`) checks that a stranger's key is refused with
  `unknownDevice` and waits, that the allowed phone's replayed or flipped signature is refused,
  and that the test cannot call `axo.device.decide` because it is not Axo.app.
- Swift:
  - `InputKeyPins` confirms by key only;
  - the phone seals nothing to an unconfirmed key and shows the fingerprint when a Mac does not
    know it;
  - Axo.app's devices model;
  - `AxodPeer` refuses a listener that does not meet the requirement and accepts one that does,
    over a real socket.

## Drawbacks

- **A trip to the Mac.** The first answer from each new device, and the first typed values to each
  Mac, need the person to look at that Mac once. That is the cost 0.18 removed. We pay it because
  the alternative trusts the whole cloud with approvals and passwords.
- **Two comparisons, not one.** Device fingerprints are compared at the Mac, and the Mac's key is
  compared on the device. A combined short authentication string would be one comparison, but it
  needs the Mac's key on every question, and RFD0029's wire shape carries it only on input
  requests.
- **The person can click without looking.** Fingerprint comparison resists a compromised cloud
  only as well as the person checks it.
- **Ad hoc builds stay weak.** Without a certificate there is no identity to check. Development
  builds keep today's behaviour, except that typed values are never sent.

## Alternatives

- **Do nothing and correct RFD0029.** This is honest, but approvals and passwords would then rest
  on every part of the cloud, including its OAuth session handling and `SESSION_SECRET`.
- **Pin keys by host ID, but only for hosts in a listing the phone already held.** The cloud writes
  the listings, so this changes nothing.
- **axod signs its input key with a key the phone pinned at device registration.** The phone learns
  nothing trustworthy from the Mac at registration, because the person compares the phone's key
  at the Mac, not the other way round. The phone would still need a comparison of its own.
- **Have the client verify axod by asking it to prove a Keychain secret.** This needs a pinned
  public key on the app side and Keychain ACL work. The audit token already names the program.

## Prior art

- The 0.16 device-trust design (`42311978`, `3e0c8255`) and its spec. It was removed in
  `d74d1995`. This RFD restores it with a separate error code, so clients can tell "unknown
  device" from "bad signature", and moves the Mac's view into Settings.
- Bluetooth numeric comparison, and Signal safety numbers: fingerprints compared by a person
  across two screens.
- `axo_ipc::peer`: axod's audit-token check of Axo.app.
