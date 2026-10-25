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

## Decision needed first: how native apps authenticate

RFD0013 makes Axo's own sign-in (Cloudflare OAuth at the Worker, then an Axo session) the
product identity and removes Cloudflare Access from the product routes. The architecture
section of `docs/axo-refactor-plan.md` and the iOS brief say apps reach hosts "through the
Cloudflare API behind Access". These disagree.

| Option | What the app holds | Fits RFD0013 | Notes |
| --- | --- | --- | --- |
| **A. Axo app session (recommended)** | An Axo session token from a native sign-in (`ASWebAuthenticationSession` → the Worker's existing Cloudflare OAuth → app callback), in Keychain | Yes: same accounts, same revocation, same Worker checks | One identity system. The Worker already does OAuth, PKCE, sessions and revocation; native adds a bearer form of the session. |
| B. Cloudflare Access | An Access token (Access login in a web view; Managed OAuth for non-browser clients) | No: RFD0013 rejects Access as product identity | Two identity systems if account ownership stays in Axo; Access does not know which hosts an account owns. |
| A + Access in front | Both | Partly | Only if Access is kept as an outer perimeter; RFD0013's rollout removes it from `/api/*`. |

Recommendation: **A**. Access can remain an optional outer gate later, but it cannot replace
account and host ownership, which only the Worker knows. If you choose B, G1 changes and the
RFD needs amending.

## Status

| RFD0013 requirement | Status | Where |
| --- | --- | --- |
| Landing `/`, app `/app`, API `/api/*` on one origin; logic in `packages/*`, `sites/*` thin | Built | `packages/axo-api-worker`, `packages/axo-web-app`, `sites/axo.leostera.dev` |
| OAuth Authorization Code + PKCE (S256) at the Worker; exact callback; state checked in constant time | Built | `src/auth/cloudflare.ts`, `src/auth/provider.ts` |
| Identity = issuer + `sub` (not email) → random account ID; per-account DO | Built | `src/auth/account.ts`, `src/auth/account-manager.ts` |
| Opaque web session; `Secure; HttpOnly; SameSite=Lax`; digest stored; expiry and revocation; logout revokes | Built | `cloudflare.ts`, `account-manager.ts` |
| Mutations check exact Origin and an anti-CSRF token | Built | `requireAxoSession(..., requireCsrf)` |
| Pairing code: Crockford Base32, `XXXX-YYYY`, 10-minute expiry, single use | Built | `src/auth/pairing.ts` |
| Pairing verifier is an HMAC; collision check; issuance, global and per-source lookup throttles; 24 h routing index for retries | Built | `pairing.ts`, `pairing-directory.ts` (`AxoPairingIndex`, `AxoPairingRateLimit`) |
| Atomic consume + host registration in the account DO; identical retry is idempotent | Built | `account-manager.ts` |
| axod: 256-bit credential created and saved in Keychain before redemption; pending credential ID and generation persisted; redeem over TLS | Built (macOS only) | `crates/axo-relay/src/pairing.rs`, `credential.rs`, `relay.rs` |
| Daemon WebSocket: credential in `Authorization`, credential ID header, no Origin | Built | `src/http/account-hosts.ts` |
| Revocation rejects the credential and closes the relay; metadata kept as offline | Built | `account-manager.ts` (`revokeHost`, `closeHostRelay`) |
| Re-linking a host in the same account keeps its identity | Built | `account-manager.ts` (upsert on `host_id`) |
| Mac: Settings → Remote Access code entry; `axo://pair/<code>` routes there; local `axo.relay.link` | Built | `RemoteAccessSettingsView`, `PairingLinkRouter`, `AxodConnection.linkHost` |
| Account routes list only owned hosts and snapshots | Built | `src/http/account-hosts.ts` |
| **Native client authentication** (iOS, Mac to other hosts) | **Missing**, not designed | `/client` requires cookie + web Origin |
| **"Full currently supported protocol" through the relay** | **Partial**: 8 `axo.remote.*` methods + `axo.host.subscribe` | `AxoHostRelay.hostRemoteMethods` (inherited by `AxoAccountManager`) |
| **End-to-end: pair → relay → client control with a real axod** | **Broken test** (401: lists hosts without a session, expects pairing-free registration) | `tests/axod-relay.test.ts` |
| Separate keys / rotation for session, pairing-code, pairing-source and credential HMACs | Missing (one `SESSION_SECRET` with domain-separated inputs) | `pairing.ts`, `cloudflare.ts` |
| Host credential store off macOS (axod on Linux) | Missing (stub refuses) | `credential.rs` |
| Keychain access policy for the daemon's item | Unresolved (RFD open question) | `credential.rs` |
| OAuth token revoked after userinfo | Unresolved (RFD open question) | `provider.ts` |
| Legacy `/v1/*` routes with synthetic principals and `private-fleet` | Still served; adoption plan unresolved (RFD open question) | `src/http/router.ts`, `src/access.ts` |
| Production: public OAuth client, Access removed from `/api/*`, deploy | Not verified here (operator task) | — |

## Plan

Ordered so each step is shippable and green; schema first for every wire change
(`packages/axo-api` v1 schemas and fixtures, then Worker, axod, clients).

### G0. Restore the end-to-end safety net

Rewrite `tests/axod-relay.test.ts` for the account model: create an account session in the
test Worker, create a pairing code, have the isolated axod redeem it through local
`axo.relay.link`, then drive the host through the `/client` socket (create a Session, send
input, see output), revoke it and see the relay close. Without this, nothing below is
provable. Add it to the default `npm test`.

### G1. Native client sessions (option A)

- **Flow**: the app opens `ASWebAuthenticationSession` at `/api/auth/native/start` with its
  own PKCE challenge and an allowlisted callback (`axo://auth`). The Worker runs the existing
  Cloudflare OAuth, then redirects to the callback with a one-time code; the app exchanges it
  (with its verifier) at `/api/auth/native/token` for an Axo **app session**.
- **App session**: opaque, high-entropy bearer; only its digest stored in the account DO, next
  to web sessions; expiring with refresh by rotation; listed and revocable from the web app;
  never a Cloudflare token.
- **Use**: `Authorization: Bearer` on account HTTP routes and the `/client` WebSocket upgrade.
  Bearer requests need no Origin and no CSRF token (not ambient credentials); cookie requests
  keep both checks. A bearer is never accepted on daemon routes, a host credential never on
  client routes.
- **Tests**: Miniflare: code replay, wrong verifier, wrong callback, expired and revoked
  sessions, cross-account host IDs, bearer on daemon routes rejected.

### G2. Relay protocol parity

Forward the axod local API through the relay as the RFD's v1 promises, from one typed table
generated from (or checked against) `AxodMethodName` and the v1 schemas, so a method added to
axod cannot silently be missing remotely. Decide explicitly which host-local methods stay
local (`axo.relay.*` pairing and remote-access control, LaunchAgent concerns). Terminal output
already streams through `axo.host.subscribe` events; keep terminal bytes unpersisted.

### G3. AxoClient remote transport and account API (Swift)

- `RelayWebSocketTransport: AxoTransport` (URLSession WebSocket with the bearer header; text
  frames; no `fatalError` on unknown frames), so `JSONRPCConnection` is reused unchanged.
- `AccountClient`: sign-in, session refresh, host list and snapshots (HTTP).
- `HostConnection`: the relay's typed API on `JSONRPCConnection`, shaped like `AxodConnection`
  so clients treat "This Mac" and remote hosts alike.
- Tests: in-memory transport for the connection; a Worker fixture for the account API.

### G4. iOS app on AxoClient

Restore the useful views from `d885961^` (chat-first workbench, Sessions drawer, voice) onto
G1–G3. The old `AxoCore` control-plane model is not reused. Sign-in is G1's native flow; hosts
come only from the account; nothing reaches a host except through the relay.

### G5. Mac app: other hosts

Sign-in in Settings (same G1 flow), and the sidebar lists the account's hosts beside "This
Mac" (reached over the socket as today). Pairing this Mac stays as built.

### G6. Hardening (RFD open questions)

- Separate HMAC keys per purpose, with key IDs so they can rotate.
- Set and test throttle thresholds under distributed guessing; per-account pending-code cap.
- Keychain access policy for axod's credential item.
- Credential store for axod off macOS (file with `0600` under the server directory, or the
  platform secret service) before "axod on Linux".
- Revoke the Cloudflare OAuth token right after userinfo (it is never needed again).
- Legacy `/v1/*`: design adoption (or deletion) of `private-fleet` data, then remove the
  routes and `edgePrincipal`.

### G7. Rollout (operator, not automated)

Register the public OAuth client, remove Access from `/`, `/app` and `/api/*` (or keep it per
the decision above), deploy to an isolated environment first, run G0 against it, then
production. Mark RFD0013 accepted and amend it with G1's native sessions.
