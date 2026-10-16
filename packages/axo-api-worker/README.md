# Axo API Worker package

This package owns the API Worker handler, Durable Object implementations, routing/domain logic, and their tests. The unified public deployment shim and Cloudflare configuration live in `sites/axo.leostera.dev`. Shared request/result schemas live in [`@axo/protocol`](../axo-api/README.md).

Legacy `/v1/*` remote-terminal routes still trust the configured Cloudflare Access perimeter and use the unassigned global `private-fleet` directory. The new account-scoped `/api/v1/*` pairing, host metadata, revocation, and WebSocket routes use the per-account `AxoAccountManager`; its deployment export deliberately retains the existing `AxoAccountDirectory` Durable Object name so current account sessions/profile rows remain in the same SQLite namespace. One account manager owns its sessions, host records, pairing state, and all of that account's live host relays. A sharded pairing-code index is routing-only; it does not own account data. The Mac app now accepts pairing codes and `axo://pair/<code>` links; `axod` stores host credentials in Keychain, redeems codes over TLS, and reconnects through account-scoped relay routes. Real production OAuth consent, callback, token exchange, and authenticated app state have been verified. The account-scoped routes and current web assets are deployed and smoke-tested; live Mac-to-Worker pairing has not yet been exercised end to end.

## OAuth sign-in configuration

The OAuth routes require Worker bindings `OAUTH_CLIENT_ID` and `SESSION_SECRET`; the production confidential client also uses `OAUTH_CLIENT_SECRET`. Configure `SESSION_SECRET` and `OAUTH_CLIENT_SECRET` as Worker secrets, never as checked-in variables. The Cloudflare OAuth client is currently private and uses Authorization Code + PKCE (S256), the exact redirect URI `https://axo.leostera.dev/api/auth/cloudflare/callback`, and the minimum identity scope `user-details.read`.

The Worker uses fixed Cloudflare authorization/token/userinfo endpoints, never derives redirect URLs from request headers, does not request offline access, and does not persist OAuth access tokens. The OAuth flow and Axo session cookies are `Secure`, `HttpOnly`, `SameSite=Lax`; Axo sessions are encrypted and authenticated, and session digests/profile metadata live in the account manager. The identity index stores only a deterministic issuer/subject hash-to-random-account-ID mapping. New account-scoped host records, credentials, and relay state live in that same manager; the existing global `private-fleet` records remain unassigned and unavailable to these routes.

The public site at `axo.leostera.dev` serves the landing page and sign-in UI from the same origin as `/api/auth/*` and the new `/api/v1/account/*` APIs. Other `/api/*` paths remain unavailable. The legacy `app.axo.leostera.dev` and `api.axo.leostera.dev` Workers and Access applications have been removed, and their site-shim code is deleted. No legacy host records have been migrated; this change did not issue Durable Object namespace tombstones.

## Development and validation

From the repository root:

```sh
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-api-worker install
npm --userconfig=/tmp/axo-npmrc --prefix sites/axo.leostera.dev run typecheck
npm --userconfig=/tmp/axo-npmrc --prefix sites/axo.leostera.dev test
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-api-worker run test:relay
```

The site typecheck generates Cloudflare binding types before checking this package. Tests run under Node's test runner with Miniflare/workerd; they do not contact a deployed API or use the production daemon or LaunchAgent.
