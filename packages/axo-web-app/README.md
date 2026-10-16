# Axo web application package

This package owns the React application, terminal UI, browser API/relay integration, styles, and browser acceptance test. The unified deployment shim, HTML document, and Cloudflare configuration live in `sites/axo.leostera.dev`.

## Development and validation

From the repository root:

```sh
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-web-app install
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-web-app run typecheck
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-web-app test
```

The remote-terminal client now targets `https://axo.leostera.dev` by default; set `VITE_AXO_API_BASE_URL` to target an isolated API during development. The `/app` path on the public site checks the same-origin `/api/auth/*` session and, when signed in, opens the account-scoped Workbench for linked hosts, session metadata, and live terminal panes. The app offers Mac pairing from the Workbench. Set `VITE_AXO_AUTH_API_BASE_URL` only when testing against a separate isolated API origin.

Production Cloudflare consent, callback, session verification, account-scoped host routes, and host pairing have succeeded. The retired `app.axo.leostera.dev` and `api.axo.leostera.dev` Workers and site shims are not part of the product flow. Legacy global `private-fleet` host records remain unassigned and are not shown in account Workbench.
