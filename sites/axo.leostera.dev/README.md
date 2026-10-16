# Public Axo site deployment shim

This site is the intended single production deployment for `axo.leostera.dev`: Workers Static Assets serves the React app from `@axo/web-app`, while one Worker entrypoint imports API/auth implementation from `@axo/api-worker`. The product code remains in `packages/*`; this directory contains only Vite/Cloudflare configuration, the HTML shell, and the Worker entrypoint.

`/` and `/app` are served from the SPA asset collection. `/api/*` is routed to the Worker first. At this stage only `/api/auth/*` reaches the OAuth/session handlers. All other `/api/*` routes deliberately return `503`: the existing API's `private-fleet` host directory and route-derived roles are not account-authorized and must not become publicly reachable just because the public domain is unified.

The unified site is deployed at `axo.leostera.dev`. The legacy `api.axo.leostera.dev` and `app.axo.leostera.dev` Workers and their Access applications have been removed, and the site-shim code is deleted. No legacy host records have been migrated, and no Durable Object namespace tombstones were issued. OAuth secrets are configured on the public Worker, and real Cloudflare consent, callback, token exchange, and authenticated app state have been verified. The OAuth client remains private. Non-auth product API routes remain fail-closed until account-scoped host authorization is implemented.

## Validate locally

```sh
npm --userconfig=/tmp/axo-npmrc --prefix sites/axo.leostera.dev install
npm --userconfig=/tmp/axo-npmrc --prefix sites/axo.leostera.dev run typecheck
npm --userconfig=/tmp/axo-npmrc --prefix sites/axo.leostera.dev run test
npm --userconfig=/tmp/axo-npmrc --prefix sites/axo.leostera.dev run build
```

Use `cf dev` from this directory for the combined Worker/assets development server. For local OAuth testing, copy `.env.example` to `.dev.vars` and replace the placeholders with a test client's values. `.dev.vars` is ignored by Git; never commit real credentials. Production values belong in the Worker’s Variables and Secrets settings.
