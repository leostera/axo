# Axo web application package

This package owns the React application, terminal UI, browser API/relay integration, styles, and browser acceptance test. The unified deployment shim, HTML document, and Cloudflare configuration live in `sites/axo.leostera.dev`.

## Development and validation

From the repository root:

```sh
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-web-app install
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-web-app run typecheck
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-web-app test
```

The remote-terminal client now targets `https://axo.leostera.dev` by default; set `VITE_AXO_API_BASE_URL` to target an isolated API during development. The `/app` path on the public site is currently a narrow Cloudflare sign-in/session-check screen backed by same-origin `/api/auth/*`; set `VITE_AXO_AUTH_API_BASE_URL` only when testing against a separate isolated API origin. The remote-terminal UI is available on the development test path for browser acceptance tests but is not part of the signed-in product flow yet.

Production Cloudflare consent, callback, and session verification have succeeded. The public site remains fail-closed for non-auth `/api/*` routes until account-scoped host authorization and pairing are implemented. The legacy `app.axo.leostera.dev` and `api.axo.leostera.dev` Workers, Access applications, and site-shim code have been removed. No legacy host records have been migrated; Durable Object namespaces were not explicitly tombstoned.
