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

## Decision (2026-10-25): Access for people, pairing for hosts, no end-to-end encryption

- **People are authenticated by Cloudflare Access**, for the browser and native apps alike.
  The Worker verifies the `Cf-Access-Jwt-Assertion` on every request (signature against the
  team's keys, audience, expiry) and derives the account from the token's issuer and subject.
  It never trusts the route path or the mere presence of a header, so a route not behind
  Access (for example `workers.dev`) cannot bypass it. Who may use Axo is the Access policy.
- **Hosts are bound to accounts by pairing**, as built. axod keeps its per-host credential;
  Access service tokens are not used for hosts (a shared secret has no per-host revocation).
- **No end-to-end encryption.** Every hop is TLS and authenticated, and the relay sees
  terminal traffic in plaintext. This is deliberate: the API Worker is meant to store logs
  and history permanently, which needs plaintext at the Worker. The trust boundary is
  therefore "the account's Cloudflare deployment", and must be documented as such.
- RFD0013 needs amending: its Worker-run Cloudflare OAuth and "Access removed from `/api/*`"
  are replaced by Access-verified identity. The account model, sessions-as-revocation (now
  per device, see G1) and pairing stay.

## Status

| RFD0013 requirement | Status | Where |
| --- | --- | --- |
| Landing `/`, app `/app`, API `/api/*` on one origin; logic in `packages/*`, `sites/*` thin | Built | `packages/axo-api-worker`, `packages/axo-web-app`, `sites/axo.leostera.dev` |
| OAuth Authorization Code + PKCE (S256) at the Worker; exact callback; state checked in constant time | Replaced by Access (G1) | `src/auth/cloudflare.ts`, `src/auth/provider.ts` |
| Identity = issuer + `sub` (not email) → random account ID; per-account DO | Built | `src/auth/account.ts`, `src/auth/account-manager.ts` |
| Opaque web session; `Secure; HttpOnly; SameSite=Lax`; digest stored; expiry and revocation; logout revokes | Replaced by Access sessions (G1) | `cloudflare.ts`, `account-manager.ts` |
| Mutations check exact Origin and an anti-CSRF token | Origin rule kept, CSRF token removed (G1) | `requireAxoSession(..., requireCsrf)` |
| Pairing code: Crockford Base32, `XXXX-YYYY`, 10-minute expiry, single use | Built | `src/auth/pairing.ts` |
| Pairing verifier is an HMAC; collision check; issuance, global and per-source lookup throttles; 24 h routing index for retries | Built | `pairing.ts`, `pairing-directory.ts` (`AxoPairingIndex`, `AxoPairingRateLimit`) |
| Atomic consume + host registration in the account DO; identical retry is idempotent | Built | `account-manager.ts` |
| axod: 256-bit credential created and saved in Keychain before redemption; pending credential ID and generation persisted; redeem over TLS | Built (macOS only) | `crates/axo-relay/src/pairing.rs`, `credential.rs`, `relay.rs` |
| Daemon WebSocket: credential in `Authorization`, credential ID header, no Origin | Built | `src/http/account-hosts.ts` |
| Revocation rejects the credential and closes the relay; metadata kept as offline | Built | `account-manager.ts` (`revokeHost`, `closeHostRelay`) |
| Re-linking a host in the same account keeps its identity | Built | `account-manager.ts` (upsert on `host_id`) |
| Mac: Settings → Remote Access code entry; `axo://pair/<code>` routes there; local `axo.relay.link` | Built | `RemoteAccessSettingsView`, `PairingLinkRouter`, `AxodConnection.linkHost` |
| Account routes list only owned hosts and snapshots | Built | `src/http/account-hosts.ts` |
| **Native client authentication** (iOS, Mac to other hosts) | Worker side built (G1): Access assertion; app side is G3 | `/client` requires cookie + web Origin |
| **"Full currently supported protocol" through the relay** | **Partial**: 8 `axo.remote.*` methods + `axo.host.subscribe` | `AxoHostRelay.hostRemoteMethods` (inherited by `AxoAccountManager`) |
| **End-to-end: pair → relay → client control with a real axod** | Built (G0) | `tests/axod-relay.test.ts` |
| Separate keys / rotation for session, pairing-code, pairing-source and credential HMACs | Missing (one `SESSION_SECRET` with domain-separated inputs) | `pairing.ts`, `cloudflare.ts` |
| Host credential store off macOS (axod on Linux) | Built (G0): `--host-credentials files`, default off macOS | `credential.rs` (`FileCredentialStore`) |
| Keychain access policy for the daemon's item | Unresolved (RFD open question) | `credential.rs` |
| Legacy `/v1/*` routes with synthetic principals and `private-fleet` | Still served; adoption plan unresolved (RFD open question) | `src/http/router.ts`, `src/access.ts` |
| Production: Access application and policy, deploy | Not verified here (operator task) | — |

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

### G1. Identity from Access, in the Worker — done

- `src/auth/access-identity.ts` verifies `Cf-Access-Jwt-Assertion` on every account request
  (RS256 against `<team>/cdn-cgi/access/certs`, issuer, audience, expiry; person tokens only,
  service tokens refused). `src/auth/account-access.ts` maps issuer + subject to the account,
  records the profile, and enforces the origin rule: state changes and relay upgrades need the
  app's `Origin`, or no `Origin` and no cookies (native clients). Missing configuration fails
  closed with 503.
- Removed: the Worker-run OAuth (`cloudflare.ts`, `provider.ts`), Axo web sessions, the CSRF
  token, `/api/auth/cloudflare/*` and `/api/auth/logout`. `/api/auth/me` now returns the
  account ID and profile. The web app signs in by loading `/app` (Access-guarded) and signs out
  through `/cdn-cgi/access/logout`.
- Tests: forged, expired, wrong-audience, wrong-issuer, service-token, non-app and oversized
  assertions; configuration parsing; the origin rule; stable account per subject; Worker
  responses for each; relay upgrade origin rule. The harness serves a JWKS through Miniflare's
  outbound service and signs assertions, so every Worker test runs the real verification.
  Seven mutants (audience, issuer, subject, type, origin check, cookie rule, team domain) are
  caught.
- **Deployment consequences (operator):** create the Access application for `/app` and
  `/api/*`, with a Bypass policy for `/api/v1/host-pairings/redeem` and
  `/api/v1/accounts/*/hosts/*/daemon` (hosts authenticate with their credential); set
  `ACCESS_TEAM_DOMAIN` and `ACCESS_AUD`; and **pair hosts again**: the old accounts were keyed
  by the OAuth subject, Access subjects differ, so the first Access sign-in creates a new
  account. Native clients must not send cookies (G3: `httpShouldHandleCookies = false`).

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

- `RelayWebSocketTransport: AxoTransport` (URLSession WebSocket, `cf-access-token`, no cookies,
  every text frame acknowledged, a binary frame closes the connection), so `JSONRPCConnection` is
  reused. The connection now also delivers notifications.
- `AccountClient`: account, hosts and one run of a host's Sessions over HTTPS, refusing an answer
  for a different run. Access refusals are `RelayError.signInRequired`.
- `HostConnection`: the relay's typed API (subscribe and events, workspaces, Sessions, terminals),
  shaped like `AxodConnection`, with every answer checked against the host it asked.
- `AccessTokenProvider` is where the iOS sign-in plugs in. `RelayEndpoint` only accepts https
  (loopback http for tests).
- Tests: in-memory transport and socket, a stub for HTTP, and a loopback WebSocket server that
  shows the upgrade carries the token and no cookie even with a browser cookie in the jar.

### G4. iOS app on AxoClient (first slice done)

`apple/AxoPhone`: `AxoPhoneModel` (account session, hosts, one host's workbench, a plain-text
terminal; no UIKit, tested on macOS), the SwiftUI screens, and `//apple/AxoPhone:AxoPhoneApp`
(`bazel build --ios_multi_cpus=sim_arm64`). Sign-in is Access's own page in a web view; the
`CF_Authorization` cookie value becomes the token the app sends in `cf-access-token`, kept in the
Keychain, and the app's own requests never use cookies. A token that cannot be kept does not
sign the phone in (found when the simulator build lacked keychain entitlements and looped).

Checked in the simulator against a stand-in relay: sign in, then the host list, with the token
header present and no cookie. **Not checked:** the workbench against a real relay and axod (needs
the Access application, G7, or a local Worker with a stand-in Access issuer), and anything on a
device (needs a provisioning profile; the entitlements file uses the bundle id as its group).

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

Configure the Access application and policy for `/app` and `/api/*` (the landing page `/`
stays public; daemon routes are authenticated by host credential, so they need an Access
bypass for that path only), deploy to an isolated environment first, run G0 against it, then
production. Amend RFD0013 with the decision above and mark it accepted.
