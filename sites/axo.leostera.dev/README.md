# Public Axo site deployment shim

This site is the intended single production deployment for `axo.leostera.dev`: Workers Static Assets serves the React app from `@axo/web-app`, while one Worker entrypoint imports API/auth implementation from `@axo/api-worker`. The product code remains in `packages/*`; this directory contains only Vite/Cloudflare configuration, the HTML shell, and the Worker entrypoint.

`/` and `/app` are served from the SPA asset collection. `/api/*` is routed to the Worker first. `/api/auth/me` and the account-scoped pairing, host metadata, revocation, relay, and Pi event-history routes under `/api/v1/*` are enabled. `/api/v1/account/hosts/:hostId/sessions/:sessionId/events` reads durable full-fidelity Pi event content from a Session-specific Durable Object; in this developer-only phase content is not redacted and has no automatic expiry. Reads require the owning account (a signed-in session), and cross-account sharing is not implemented. Terminal bytes are not stored. The legacy `/v1/*` API remains fail-closed at this public origin; its global `private-fleet` directory is not account-authorized.

The unified site is deployed at `axo.leostera.dev`. The legacy `api.axo.leostera.dev` and `app.axo.leostera.dev` Workers and their Access applications have been removed, and the site-shim code is deleted. No legacy host records have been migrated, and no Durable Object namespace tombstones were issued.

## Shared-session viewer prototype

`/s/<22-character-share-id>/<slug>` is a static-asset route that loads the read-only web viewer. Its snapshot request, `GET /api/public-sessions/<share-id>`, is handled by the site Worker and reads `shares/<share-id>.json` from the separate `PUBLIC_SESSIONS` R2 binding; it does not call `@axo/api-worker` or read account/session core data. Snapshots are written, already redacted, by Pi's `/axo-share` command on the Mac (see `packages/pi-axo/README.md`). The JSON is versioned (`version: 1`) and holds `title`, ISO `publishedAt`, and plain-text `messages` (user, assistant, and tool entries; no images or reasoning); the viewer parses Markdown itself and rejects anything else. The R2 bucket must be provisioned as `axo-public-sessions` before deploying. Unpublishing is not implemented yet: delete `shares/<share-id>.json` from the bucket. Sign-in is Cloudflare OAuth at the Worker with sessions of its own, for the web and the phone (see `packages/axo-api-worker/README.md`); before deploying, set `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET` and `SESSION_SECRET` on the Worker. Account-scoped pairing and host routes are deployed; the app exposes an `axo://pair/<code>` link, and the Mac app/daemon implement code entry, Keychain credential storage, redemption, and account-scoped reconnect. The live pairing flow has not yet been exercised end to end.

## Validate locally

```sh
npm --userconfig=/tmp/axo-npmrc --prefix sites/axo.leostera.dev install
npm --userconfig=/tmp/axo-npmrc --prefix sites/axo.leostera.dev run typecheck
npm --userconfig=/tmp/axo-npmrc --prefix sites/axo.leostera.dev run test
npm --userconfig=/tmp/axo-npmrc --prefix sites/axo.leostera.dev run build
```

Use `cf dev` from this directory for the combined Worker/assets development server. For local testing, copy `.env.example` to `.dev.vars` and replace the placeholders; without a session, account routes answer 401, and `/api/auth/cloudflare/start` redirects to Cloudflare. `.dev.vars` is ignored by Git; never commit real credentials. Production values belong in the Worker’s Variables and Secrets settings.
