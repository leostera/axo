# Axo API Worker package

This package owns the API Worker handler, Durable Object implementations, routing/domain logic, and their tests. The unified public deployment shim and Cloudflare configuration live in `sites/axo.leostera.dev`. Shared request/result schemas live in [`@axo/protocol`](../axo-api/README.md).

Legacy `/v1/*` remote-terminal routes still trust the configured Cloudflare Access perimeter and use the unassigned global `private-fleet` directory. The new account-scoped `/api/v1/*` pairing, host metadata, revocation, and WebSocket routes use the per-account `AxoAccountManager`; its deployment export deliberately retains the existing `AxoAccountDirectory` Durable Object name so existing account rows remain in the same SQLite namespace. One account manager owns its profile, host records, pairing state, and all of that account's live host relays. A sharded pairing-code index is routing-only; it does not own account data. The Mac app now accepts pairing codes and `axo://pair/<code>` links; `axod` stores host credentials in Keychain, redeems codes over TLS, and reconnects through account-scoped relay routes. Accounts created by the earlier Worker-run Cloudflare OAuth were keyed by the dashboard user ID; Access subjects differ, so after the Access cutover a person gets a new account and must pair their hosts again. The account-scoped routes and current web assets are deployed and smoke-tested; live Mac-to-Worker pairing has not yet been exercised end to end.

## Sign-in: Cloudflare Access

People are authenticated by Cloudflare Access, not by the Worker. Access guards `/app` and `/api/*`; it signs every request it admits with `Cf-Access-Jwt-Assertion`, and `src/auth/access-identity.ts` verifies that assertion on every account request: RS256 signature against `<team>/cdn-cgi/access/certs`, issuer, audience and expiry. Only person tokens (`type: "app"` with a subject) are accepted; service tokens are not. Browsers get the assertion from Access's cookie and native apps by sending `cf-access-token`, so there is one verification path. A request that reaches the Worker without passing Access is anonymous; nothing is trusted from the route or hostname.

Bindings: `ACCESS_TEAM_DOMAIN` (`https://<team>.cloudflareaccess.com`) and `ACCESS_AUD` (the Access application's AUD tag, comma-separated if several) as Worker variables, and `SESSION_SECRET` (keys pairing-code and host-credential verifiers) as a secret. Without them, sign-in fails closed with 503.

Accounts are keyed by `sha256(issuer + "\0" + subject)`, never by email; `AxoIdentityIndex` maps that key to a random account ID. Requests that change state or open a relay must come from the app's Origin, or from a native client that sends neither `Origin` nor cookies (`isCrossSiteRequest`). Sign-out is Access's `/cdn-cgi/access/logout`.

Hosts never sign in: they pair. `/api/v1/host-pairings/redeem` and `/api/v1/accounts/:account/hosts/:host/daemon` authenticate with the pairing code and the per-host credential, so the Access application needs a Bypass policy for exactly those paths.

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
