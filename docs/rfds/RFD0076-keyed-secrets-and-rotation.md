# RFD0076 - Axo: keyed secrets and their rotation

- Feature Name: `keyed-secrets-and-rotation`
- Status: Implemented
- Author: leostera
- Start Date: 2026-11-18
- Document Type: Proposal
- Amends: [RFD0013](RFD0013-cloudflare-oauth-and-host-pairing.md) (separate keys per purpose and their rotation, listed there as not built)

## Summary

Every hash and seal the Worker keeps or hands out now names the key it was made with, and is made
with a key derived for its purpose alone. `SESSION_SECRET` is key 0, used exactly as before, so
nothing made before this change stops working. A new secret, `SECRET_KEYS`, names a current key
and a previous one. New hashes and seals use the current key. Both keys verify and open what they
made. A key can then be rotated out with no one signed out at once and no Mac paired again.

## Motivation

One unversioned `SESSION_SECRET` keyed everything: session hashes, login and pairing codes, host
credential verifiers, rate-limit source keys, the sealed OAuth states, and every sealed app grant,
client, call log and WhatsApp device. Purposes were kept apart only by a prefix inside the HMAC's
input. Nothing said which key made a stored value, so the secret could not change: changing it
signed everyone out, unlinked every Mac, and lost every app grant at once. A leaked secret had no
remedy but that.

## Design

`src/auth/keys.ts` holds the contract: `Keyring.parse(env)` is the only place a key comes from.

- **Keys.** Key 0 is `SESSION_SECRET`. `SECRET_KEYS` is
  `{"current":{"id":n,"secret":"…"},"previous":{"id":m,"secret":"…"}|null}`. Key 0 appears in it
  as `{"id":0}`, with no secret. Every secret has at least 32 bytes, and the two IDs differ.
  Anything else is refused as a whole, and sign-in answers 503, as with no secret at all. Without
  `SECRET_KEYS`, key 0 is the only key.
- **Hashes.** Key 0's are `HMAC(SESSION_SECRET, "<purpose>\0<value>")`, bare, as before. Key
  n ≥ 1's are `k<n>.` followed by `HMAC(HKDF(key n, "axo-hash-v2", purpose), value)`.
  `verify(purpose, value, stored)` reads the key from the stored hash and says whether the current
  or the previous key made it.
- **Seals.** Key 0's are `v1.<iv>.<ciphertext>`, as before. Key n's are
  `v2.<n>.<iv>.<ciphertext>`, AES-GCM under `HKDF(key n, "axo-seal-v2", purpose)`. `unseal` opens
  either while its key is configured.
- **Lookups.** A session token carries no key ID, and changing its format would sign out every
  phone. So a token is looked up by its hash with each configured key, current first (`hashes`).
  The match is the session's digest, which is what logout, push and sign-in leases (RFD0071) use.
  Login codes and pairing codes are looked up the same way, so a code issued just before a
  rotation still works.
- **Re-keying.** A Mac's credential verifier made with the previous key is rewritten with the
  current one when the Mac next signs in (`authorizeHost`). Sessions are not re-keyed: their digest
  names their sockets' leases. They end within 90 days anyway. Sealed values are rewritten
  with the current key whenever they are written again (a renewed grant, a new client).
- **Rate-limit source keys** use the current key alone: a rotation only restarts their counts.

### Rotating a key

1. Set `SECRET_KEYS` with the new key current and the old one previous, then deploy.
2. Wait until what only the old key opens has ended or been rewritten: sessions within 90 days,
   each Mac's verifier at its next sign-in. App grants and clients that are never written again
   still need the old key.
3. Drop the old key: `"previous": null`. What only it made stops working, as a signed-out session
   or a grant needing sign-in does.

### Invariants

1. What one key and purpose made never verifies or opens under another key or purpose.
2. A value made with a configured key verifies and opens. One made with a dropped key never does.
3. Adding a key signs no one out, unlinks no Mac, and loses no grant.

## Alternatives

- **Re-key everything at once.** A job would rewrite every stored hash and seal on rotation. A
  session's hash cannot be computed without its token, so sessions cannot be re-keyed this way.
- **A key ID in the session token.** This would save one lookup per request. But it changes a
  format the phone stores, and only during a rotation is there a second key to try.

## Testing

`tests/keys.test.ts` (`//packages/axo-api-worker:sign_in_test`) covers four things:

- key 0 is the legacy derivation;
- malformed `SECRET_KEYS` are refused;
- hashes and seals verify and open while their key is configured, and only under their purpose;
- a Worker restarted with `SECRET_KEYS` keeps an earlier session signed in. It moves a Mac's
  credential to key 1 and then to key 2 without pairing it again, and signs out a session once its
  key is dropped.
