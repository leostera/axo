# Public Axo site deployment shim

This site is the intended single production deployment for `axo.leostera.dev`: Workers Static Assets serves the React app from `@axo/web-app`, while one Worker entrypoint imports API/auth implementation from `@axo/api-worker`. The product code remains in `packages/*`; this directory contains only Vite/Cloudflare configuration, the HTML shell, and the Worker entrypoint.

`/` and `/app` are served from the SPA asset collection. `/api/*` is routed to the Worker first. `/api/auth/me` and the account-scoped pairing, host metadata, revocation, relay, and Pi event-history routes under `/api/v1/*` are enabled. `/api/v1/account/hosts/:hostId/sessions/:sessionId/events` reads durable full-fidelity Pi event content from a Session-specific Durable Object; in this developer-only phase content is not redacted and has no automatic expiry. Reads require the owning account (a signed-in session), and cross-account sharing is not implemented. Terminal bytes are not stored. The legacy `/v1/*` API remains fail-closed at this public origin; its global `private-fleet` directory is not account-authorized.

The unified site is deployed at `axo.leostera.dev`. The legacy `api.axo.leostera.dev` and `app.axo.leostera.dev` Workers and their Access applications have been removed, and the site-shim code is deleted. No legacy host records have been migrated, and no Durable Object namespace tombstones were issued.

## Installing the Mac app

`curl -fsSL https://axo.leostera.dev/install | sh` installs and starts Axo on a Mac; `/install?code=ABCD-EFGH` also opens the pairing code in Axo's Remote Access settings. The Worker writes the script (`src/install.ts`) with the request's origin, so a preview installs from itself. It reads `/cdn/latest.json`, selects its target triplet (or a universal Mac artifact), and pins that immutable `/cdn/axo-<version>-<12-character-sha>-<triplet>.zip` URL. The archive comes from `releases/<filename>` in the `axo-cdn` R2 binding, then checks the signature and team, installs into `/Applications` (or `~/Applications`, or `$AXO_INSTALL_DIR`), quits a running Axo, and opens the new one, which registers axod. Downloading with curl leaves no quarantine attribute, so macOS does not translocate the app; a translocated copy cannot register its LaunchAgent ("the bundled axod LaunchAgent definition is missing"). The app is signed for development and not notarized, so a copy downloaded in a browser would hit Gatekeeper.

`bazel run //:publish` derives the target from the built executable, uploads its immutable `releases/axo-<version>-<sha>-<triplet>.zip`, and writes `latest.json` last. The pointer has `{version,build,axodBuild,commit,artifacts:{[triplet]:filename}}`; commit is the full SHA and filenames use its first 12 characters. Only platforms actually built are advertised. Publication remains single-writer and versions/builds must increase; a partial retry may reuse matching signed content but cannot overwrite an immutable artifact with different content. The bucket is `publish.bucket` in `config.json`.

Old `/cdn/Axo.app.json` and `/cdn/Axo.app[.zip]` URLs are derived compatibility views, not separately published mutable copies. Before the first new-format publication, those views and the ARM shell installer can bootstrap from existing `mac/Axo.app.*` objects. Malformed new pointers fail closed. Deploy these Worker routes before the first new-format publication. New native updaters use only `latest.json` and verify captured release metadata and signatures before swapping. See [RFD0048](../../docs/rfds/RFD0048-release-artifacts.md).

## Shared-session viewer prototype

`/s/<22-character-share-id>/<slug>` is a static-asset route that loads the read-only web viewer. Its snapshot request, `GET /api/public-sessions/<share-id>`, is handled by the site Worker and reads `shares/<share-id>.json` from the separate `PUBLIC_SESSIONS` R2 binding; it does not call `@axo/api-worker` or read account/session core data. Snapshots are redacted on the Mac by Pi's `/axo-share` command and published through axod's relay link: the host relay (`axo.host.share.publish`) validates them, writes them to the same binding with the publishing account and host as object metadata, and picks the share ID (see `packages/pi-axo/README.md`). The JSON is versioned (`version: 1`) and holds `title`, ISO `publishedAt`, and plain-text `messages` (user, assistant, and tool entries; no images or reasoning); the viewer parses Markdown itself and rejects anything else. The R2 bucket must be provisioned as `axo-public-sessions` before deploying. Unpublishing is not implemented yet: delete `shares/<share-id>.json` from the bucket. Sign-in is Cloudflare OAuth at the Worker with sessions of its own, for the web and the phone (see `packages/axo-api-worker/README.md`); before deploying, set `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET` and `SESSION_SECRET` on the Worker. Account-scoped pairing and host routes are deployed; the app exposes an `axo://pair/<code>` link, and the Mac app/daemon implement code entry, Keychain credential storage, redemption, and account-scoped reconnect. The live pairing flow has not yet been exercised end to end.

## Validate locally

```sh
bazel build //sites/axo.leostera.dev:site   # bazel-bin/sites/axo.leostera.dev/.cloudflare/output
bazel test //sites/axo.leostera.dev/...      # typecheck, and the whole site under Vite
```

For `cf dev`, install the workspace's packages once with `pnpm install` at the repository root.

Use `cf dev` from this directory for the combined Worker/assets development server. For local testing, copy `.env.example` to `.dev.vars` and replace the placeholders; without a session, account routes answer 401, and `/api/auth/cloudflare/start` redirects to Cloudflare. `.dev.vars` is ignored by Git; never commit real credentials. Production values belong in the Worker’s Variables and Secrets settings.
