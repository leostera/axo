# Axo API Worker package

This package owns the API Worker handler, Durable Object implementations, routing/domain logic, and their tests. The unified public deployment shim and Cloudflare configuration live in `sites/axo.leostera.dev`. Shared request/result schemas live in [`@axo/protocol`](../axo-api/README.md).

Legacy `/v1/*` remote-terminal routes trust whatever sits in front of them (they are not routed on the public site) and use the unassigned global `private-fleet` directory. The new account-scoped `/api/v1/*` pairing, host metadata, revocation, and WebSocket routes use the per-account `AxoAccountManager`; its deployment export deliberately retains the existing `AxoAccountDirectory` Durable Object name so existing account rows remain in the same SQLite namespace. One account manager owns its profile, host records, pairing state, and all of that account's live host relays. A sharded pairing-code index is routing-only; it does not own account data. The Mac app now accepts pairing codes and `axo://pair/<code>` links; `axod` stores host credentials in Keychain, redeems codes over TLS, and reconnects through account-scoped relay routes. The account-scoped routes and current web assets are deployed and smoke-tested; live Mac-to-Worker pairing has not yet been exercised end to end.

## Sign-in: Cloudflare OAuth, sessions of our own

Anyone with a Cloudflare account can sign in; there is no allowlist. The Worker runs the OAuth authorization-code flow with PKCE (`src/auth/login.ts`, `oauth-cloudflare.ts`) and then issues its own session, so the same code serves the web app and the phone.

- **Start** (`GET /api/auth/cloudflare/start`): seals the PKCE verifier, a nonce and an expiry into the OAuth `state` (AES-GCM, bound to its purpose) and sets a flow cookie holding the nonce. The callback must present both, so a callback link an attacker started cannot sign anyone else in.
- **Callback** (`GET /api/auth/cloudflare/callback`): exchanges the code, reads the user's profile, maps the provider-qualified subject to a random account ID (`AxoIdentityIndex`; never by email) and answers by client. The web gets a session cookie and a redirect to `/app`. The phone (`?client=native&challenge=<S256 of a secret it keeps>`) gets a one-time code on `axo://auth/callback`; the redirect is fixed, not chosen by the caller.
- **Token** (`POST /api/auth/token`): the app trades `{code, verifier}` for a session token. The code lives 60 seconds in the account's Durable Object, works once, and a wrong verifier burns it.
- **Sessions** (`src/auth/session.ts`): `axo1.<account>.<secret>` with a 256-bit secret; only an HMAC of it is stored, per account (at most 20; the oldest make room). 30 days on the web, 90 on the phone. `POST /api/auth/logout` ends exactly that sign-in. `requireAccount` is the one place a request becomes an account: an `Authorization: Bearer` header decides alone (a bad one is refused, not replaced by a cookie), otherwise the `__Host-axo_session` cookie, which may only change state or open a relay from the app's own `Origin`.
- **Limits**: start, callback and token are rate limited per source and globally.

Bindings (declared in `sites/axo.leostera.dev/cloudflare.config.ts`; values are set on the Worker, never in the repo): `OAUTH_CLIENT_ID` and `OAUTH_CLIENT_SECRET` for the Cloudflare OAuth client (callback `https://axo.leostera.dev/api/auth/cloudflare/callback`, scope `user-details.read`), and `SESSION_SECRET` (at least 32 bytes) which keys session hashes, login codes, the sealed state, pairing codes and host credentials. Without them, sign-in answers 503.

Hosts never sign in: they pair. `/api/v1/host-pairings/redeem` and `/api/v1/accounts/:account/hosts/:host/daemon` authenticate with the pairing code and the per-host credential.

The public site at `axo.leostera.dev` serves the landing page and app from the same origin as `/api/auth/me` and the new `/api/v1/account/*` APIs. Other `/api/*` paths remain unavailable. The legacy `app.axo.leostera.dev` and `api.axo.leostera.dev` Workers and Access applications have been removed, and their site-shim code is deleted. No legacy host records have been migrated; this change did not issue Durable Object namespace tombstones.

## Development and validation

From the repository root:

```sh
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-api-worker install
npm --userconfig=/tmp/axo-npmrc --prefix sites/axo.leostera.dev run typecheck
npm --userconfig=/tmp/axo-npmrc --prefix sites/axo.leostera.dev test
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-api-worker run test:relay
```

The site typecheck generates Cloudflare binding types before checking this package. Tests run under Node's test runner with Miniflare/workerd; they do not contact a deployed API or use the production daemon or LaunchAgent.
