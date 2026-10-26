# RFD0013: what is built, what is missing, and the plan

- Audited: 2026-10-25, at `4c155f3`, against
  [RFD0013](rfds/RFD0013-cloudflare-oauth-and-host-pairing.md) (status still "Proposal").
- Evidence: source reads of `packages/axo-api-worker`, `crates/axo-relay` and
  `apple/AxoMac`. `npm run test:core` in `packages/axo-api-worker`: 46/46 pass.
  `npm run test:relay` (live axod): **fails** (see G0). No production system was inspected
  or changed.

## Summary

The browser half of RFD0013 and the daemon half of pairing are built and closely follow the
RFD: Cloudflare OAuth with PKCE at the Worker, subject-keyed accounts in per-account Durable
Objects, opaque web sessions with CSRF and Origin checks, throttled 40-bit pairing codes with
HMAC verifiers and atomic redemption, per-host Keychain credentials in axod, revocation that
closes the relay, and the Mac's typed or `axo://pair/<code>` code entry.

What is missing is everything a **native client** needs, and the RFD has no design for it:
the only client route (`/api/v1/account/hosts/:host/client`) accepts a browser cookie with
the exact web Origin, so neither the iOS app nor the Mac app (for other hosts) can
authenticate; and the relay forwards only 8 `axo.remote.*` methods, not the full protocol the
RFD promises. The one end-to-end test with a real axod predates the account model and fails.

## Decision (2026-10-26): Axo signs people in itself; Cloudflare OAuth first; no end-to-end encryption

This supersedes the 2026-10-25 decision to use Cloudflare Access for people (built in `8b0b9c2`,
replaced by the sign-in below). Access is a gate for known people; Axo is meant to be
self-serve for the public, so the Worker owns sign-in. That is what RFD0013 proposed.

- **People sign in through OAuth at the Worker** (authorization code with PKCE; Cloudflare is the
  only provider for now, and a provider is just an authorization URL and a way to read a
  verified `(issuer, subject)`). The account is derived from that pair, never from an email.
- **One kind of session for web and phone:** a random 256-bit token the Worker stores only as a
  keyed hash, with the account ID in front so the right Durable Object can answer. The browser
  holds it in an `HttpOnly` cookie, the app as `Authorization: Bearer`. A cookie may only change
  state from the app's own `Origin`; a bearer token is never ambient, so it needs no origin.
- **The phone never sees a token in a URL.** It starts sign-in with a PKCE challenge, the system
  web-auth sheet returns it a one-time code on `axo://auth/callback`, and it trades the code and
  its secret for a token. A wrong secret burns the code.
- **Hosts are bound to accounts by pairing**, as built, with a per-host credential.
- **No end-to-end encryption.** Every hop is TLS and authenticated, and the relay sees
  terminal traffic in plaintext. This is deliberate: the API Worker is meant to store logs
  and history permanently, which needs plaintext at the Worker. The trust boundary is
  therefore "the account's Cloudflare deployment", and must be documented as such.
- What open sign-up still needs before a public launch: per-account quotas, account deletion,
  terms and privacy pages, more providers, and Sign in with Apple for the App Store.

## Status

| RFD0013 requirement | Status | Where |
| --- | --- | --- |
| Landing `/`, app `/app`, API `/api/*` on one origin; logic in `packages/*`, `sites/*` thin | Built | `packages/axo-api-worker`, `packages/axo-web-app`, `sites/axo.leostera.dev` |
| OAuth Authorization Code + PKCE (S256) at the Worker; exact callback; state is sealed and bound to the browser | Built (G1b) | `src/auth/login.ts`, `src/auth/oauth-cloudflare.ts` |
| Identity = issuer + `sub` (not email) → random account ID; per-account DO | Built | `src/auth/account.ts`, `src/auth/account-manager.ts` |
| Opaque session; `Secure; HttpOnly; SameSite=Lax` cookie or bearer token; keyed digest stored; expiry, per-device revocation, 20 per account | Built (G1b) | `src/auth/session.ts`, `account-manager.ts` |
| Mutations check exact Origin when the session is a cookie (no CSRF token: a bearer token is not ambient) | Built (G1b) | `requireAccount` |
| Pairing code: Crockford Base32, `XXXX-YYYY`, 10-minute expiry, single use | Built | `src/auth/pairing.ts` |
| Pairing verifier is an HMAC; collision check; issuance, global and per-source lookup throttles; 24 h routing index for retries | Built | `pairing.ts`, `pairing-directory.ts` (`AxoPairingIndex`, `AxoPairingRateLimit`) |
| Atomic consume + host registration in the account DO; identical retry is idempotent | Built | `account-manager.ts` |
| axod: 256-bit credential created and saved in Keychain before redemption; pending credential ID and generation persisted; redeem over TLS | Built (macOS only) | `crates/axo-relay/src/pairing.rs`, `credential.rs`, `relay.rs` |
| Daemon WebSocket: credential in `Authorization`, credential ID header, no Origin | Built | `src/http/account-hosts.ts` |
| Revocation rejects the credential and closes the relay; metadata kept as offline | Built | `account-manager.ts` (`revokeHost`, `closeHostRelay`) |
| Re-linking a host in the same account keeps its identity | Built | `account-manager.ts` (upsert on `host_id`) |
| Mac: Settings → Remote Access code entry; `axo://pair/<code>` routes there; local `axo.relay.link` | Built | `RemoteAccessSettingsView`, `PairingLinkRouter`, `AxodConnection.linkHost` |
| Account routes list only owned hosts and snapshots | Built | `src/http/account-hosts.ts` |
| **Native client authentication** (iOS, Mac to other hosts) | Worker side built (G1b): PKCE code exchange for a bearer token; app side is G3/G4 | `/api/auth/token` |
| **"Full currently supported protocol" through the relay** | **Partial**: 8 `axo.remote.*` methods + `axo.host.subscribe` | `AxoHostRelay.hostRemoteMethods` (inherited by `AxoAccountManager`) |
| **End-to-end: pair → relay → client control with a real axod** | Built (G0) | `tests/axod-relay.test.ts` |
| Separate keys / rotation for session, pairing-code, pairing-source and credential HMACs | Missing (one `SESSION_SECRET` with domain-separated inputs) | `pairing.ts`, `cloudflare.ts` |
| Host credential store off macOS (axod on Linux) | Built (G0): `--host-credentials files`, default off macOS | `credential.rs` (`FileCredentialStore`) |
| Keychain access policy for the daemon's item | Unresolved (RFD open question) | `credential.rs` |
| Legacy `/v1/*` routes with synthetic principals and `private-fleet` | Still served; adoption plan unresolved (RFD open question) | `src/http/router.ts`, `src/access.ts` |
| Production: OAuth client, Worker settings, deploy | Not verified here (operator task) | — |

## Plan

Ordered so each step is shippable and green; schema first for every wire change
(`packages/axo-api` v1 schemas and fixtures, then Worker, axod, clients).

### G0. Restore the end-to-end safety net — done

`tests/axod-relay.test.ts` (part of `npm test`) now runs the account model against a real,
isolated axod: sign in, create a pairing code, redeem it through local `axo.relay.link`, check
the credential is a `0600` file and never in `relay.json`, see the host register, check that
another account sees nothing and cannot connect, stream output for remote input, create a
Session, check terminal bytes are stored on neither side, then revoke: clients are dropped,
metadata stays as offline, and axod's retry with the revoked credential gets 403. Mutants
that skip closing the relay on revoke, or accept revoked hosts, are caught.

It found and fixed:

- **Relay drops busy hosts.** Every socket had the same 30 frames/s budget, and a host sends
  one frame per PTY read, so a shell printing output was disconnected (`1008 Rate limit`).
  Hosts now get 600 frames/s, clients keep 30 (`INBOUND_FRAMES_PER_SECOND`; tested).
- **Redemption waited for EOF.** axod read the pairing response until the server closed the
  connection, so a keep-alive server turned every redemption into a 5 s timeout and retry.
  It now stops when a `Content-Length` or chunked response is complete (tested).
- **Isolated tests could not pair without TLS or the login Keychain.** Pairing and the paired
  relay now accept `ws`/`http` only to a loopback relay that opted in with
  `allowInsecureLoopback` (as the unpaired relay already did), and axod takes
  `--host-credentials files`.

Still open: before linking, an axod with `relay.json` connects to the legacy unauthenticated
`/v1` route (G6).

### G1. Identity: Access (superseded) → the Worker's own sign-in (G1b, done)

G1 first made the Worker verify Cloudflare Access assertions (`8b0b9c2`). Open sign-up made
Access the wrong tool, so G1b replaced it with Cloudflare OAuth at the Worker, written fresh
(the old Worker-run OAuth was read for ideas, not restored):

- `src/auth/oauth-cloudflare.ts`: the authorization URL (PKCE S256, scope `user-details.read`,
  the registered callback `/api/auth/cloudflare/callback`) and the code exchange; bounded
  responses, no redirects followed, failures say only which stage failed.
- `src/auth/login.ts`: `GET /api/auth/cloudflare/start`, the callback, `POST /api/auth/token`,
  `GET /api/auth/me`, `POST /api/auth/logout`. The OAuth `state` is sealed (AES-GCM, purpose
  bound) and carries a nonce that the browser's flow cookie must match, so a callback link an
  attacker started cannot sign anyone else in. Start, callback and token are rate limited per
  source and globally.
- `src/auth/session.ts` and `account-manager.ts`: `axo1.<account>.<secret>` tokens, stored as an
  HMAC, 30 days on the web and 90 on the phone, revocable one device at a time, at most 20 per
  account. `account-access.ts` (`requireAccount`) is the single seam every account route uses.
- Login codes for the phone live in the account's Durable Object: 60 seconds, single use, and
  burnt by a wrong secret.
- Tests (`tests/auth.test.ts`, 25): flow integrity, login CSRF, replayed and foreign codes,
  provider failures, PKCE for the app, origin and bearer rules, revocation and expiry, limits.
  Eleven mutants are caught; the twelfth (the account in the digest) changes nothing
  observable, because a digest is only ever looked up in its own account's object.
- Web app: "Continue with Cloudflare" starts the Worker's sign-in; sign-out is
  `POST /api/auth/logout`.
- **Deployment consequences (operator):** register the OAuth client's callback and scope (the
  existing one works), set `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET` and `SESSION_SECRET` on the
  Worker (declared in `cloudflare.config.ts`; values are never in the repo), and pair hosts
  again if the old OAuth accounts matter: sessions and accounts from before are separate.

### G2. Relay protocol parity (done, with a planned list)

`crates/axo-protocol/src/parity.rs` decides, for every method axod advertises, what it becomes
through the relay: a remote call, a host event, local-only (with the reason), or planned. Tests
fail when a method has no decision, when the Worker's v1 schemas lack a promised method or
already have a planned one (`fixtures/remote-parity.json`), or when the relay does not dispatch
a promised call. Built since: `axo.remote.workspace.list` (names only) and
`axo.remote.session.rename`. Still planned: Workspace rename and archive, and the two Pi
restarts. Remote snapshots now show a manual name over Pi's title (they did not). Terminal bytes
stay unpersisted.

### G3. AxoClient remote transport and account API (Swift) (done)

In `apple/AxoClient/Sources/AxoClient/Remote`:

- `RelayWebSocketTransport: AxoTransport` (URLSession WebSocket, bearer token, no cookies,
  every text frame acknowledged, a binary frame closes the connection), so `JSONRPCConnection` is
  reused. The connection now also delivers notifications.
- `AccountClient`: account, hosts and one run of a host's Sessions over HTTPS, refusing an answer
  for a different run. A refused session is `RelayError.signInRequired`.
- `HostConnection`: the relay's typed API (subscribe and events, workspaces, Sessions, terminals),
  shaped like `AxodConnection`, with every answer checked against the host it asked.
- `NativeSignIn` runs the phone side of sign-in (PKCE, the one-time code, the token exchange); `SessionTokenProvider` is where the token comes from. `RelayEndpoint` only accepts https
  (loopback http for tests).
- Tests: in-memory transport and socket, a stub for HTTP, and a loopback WebSocket server that
  shows the upgrade carries the token and no cookie even with a browser cookie in the jar.

### G4. iOS app on AxoClient (first slice done)

`apple/AxoPhone`: `AxoPhoneModel` (account session, hosts, one host's workbench, a plain-text
terminal; no UIKit, tested on macOS), the SwiftUI screens, and `//apple/AxoPhone:AxoPhoneApp`
(`bazel build --ios_multi_cpus=sim_arm64`). A token that cannot be kept does not
sign the phone in (found when the simulator build lacked keychain entitlements and looped).

The phone signs in through the system web-auth sheet (`NativeSignIn`) and keeps the session
token in the Keychain; a token that cannot be kept does not sign the phone in (found when the
simulator build lacked keychain entitlements and looped). Signing out ends the session at the
relay too.

Checked in the simulator against a stand-in relay (before sign-in moved off Access): the host list
with the token header present and no cookie. **Not checked:** the whole path against a real
Worker (needs the Worker deployed with its three settings), the workbench against a real relay
and axod, and anything signed for a device beyond installing it.

Next: the terminal is text only (full-screen programs will not draw); an xterm.js web view or a
native emulator replaces it. Voice (`AxoVoice` in `d885961^`) and the chat-first view are not
restored yet.

### G5. Mac app: other hosts

Sign-in in Settings (same G1 flow), and the sidebar lists the account's hosts beside "This
Mac" (reached over the socket as today). Pairing this Mac stays as built.

### G6. Hardening (RFD open questions)

- Separate HMAC keys per purpose, with key IDs so they can rotate.
- Set and test throttle thresholds under distributed guessing; per-account pending-code cap.
- Keychain access policy for axod's credential item.
- Credential store for axod off macOS (file with `0600` under the server directory, or the
  platform secret service) before "axod on Linux".
- Document the trust boundary: Cloudflare and the Worker see terminal traffic and stored logs.
- Legacy `/v1/*`: design adoption (or deletion) of `private-fleet` data, then remove the
  routes and `edgePrincipal`.

### G7. Rollout (operator, not automated)

Set `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET` and `SESSION_SECRET` on the Worker (the OAuth client
needs the callback `https://axo.leostera.dev/api/auth/cloudflare/callback` and the
`user-details.read` scope; the one the Worker used before works). Deploy to an isolated
environment first, run G0 against it, then production. Pair hosts again if the old accounts
matter. Amend RFD0013 with the decision above and mark it accepted.
