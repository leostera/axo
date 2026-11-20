# Continuous delivery

Every push to `main` on GitHub (`leostera/axo`) builds, checks and deploys the sites it touches,
with Cloudflare Workers Builds. Nothing else deploys them.

## What deploys

| Service | Worker | Serves | Config | Deploys on changes to |
|---|---|---|---|---|
| Axo web, API and relay | `axo-public-app` | `axo.leostera.dev` | `sites/axo.leostera.dev/cloudflare.config.ts` | `sites/axo.leostera.dev`, `packages/axo-api-worker`, `packages/axo-api`, `packages/axo-web-app`, `packages/axo-app`, `packages/axo-apps`, `packages/pi-axo`, `assets`, the workspace files, `tools/cd` |
| AXP specification | `axp-www` | `axp.leostera.dev` | `sites/axp.leostera.dev/cloudflare.config.ts` | `sites/axp.leostera.dev`, `axp`, the workspace files, `tools/cd` |

The web app, the API and the relay are one Worker, so they deploy together, atomically: a
version serves all three or none.

Not deployed from here: the Mac app, axod and their manifest (`cdn/latest.json`, published by
`bazel run //:publish`), the phone apps, and `docs/explainers/remote-access`, which has no
deployment. `axo-public-app-preview` is declared but has no Worker.

`cloudflare.config.ts` declares each Worker: its bindings, domains, secrets (by name) and Durable
Objects. It cannot connect a repository; the Workers Builds triggers below do, and they are kept
here, since they live in Cloudflare.

## A push

1. Workers Builds clones the commit and runs `tools/cd/build.sh <service>`:
   - **Exact source.** The checkout must be the pushed commit (`WORKERS_CI_COMMIT_SHA`) on
     `main`, with no tracked file changed, before the checks and again before the build.
   - **Checks.** For Axo: the protocol's schemas and tests, every typecheck, the web app's model
     tests, the site's tests, and the Worker's core suite with Session storage.
   - **The installed clients.** It reads the release people install from `cdn/latest.json`,
     takes that commit's `packages/axo-api/src`, and runs `tests/shipped-client.test.ts`: every
     request is one those clients send, and every answer must read with their schemas (a field
     they don't know is fine; they ignore it).
   - **Build.** `cf build`; the Worker must carry the commit (`/api/health` reports it).
2. Then `tools/cd/deploy.sh <service>`:
   - Deploys only if the commit is still `main`'s tip. An older build that finishes late does not
     land over a newer one.
   - Records the version live before, and how to serve it again.
   - `cf deploy --prebuilt --no-provision`, tagged with the commit: no bucket or other resource is
     created, and the bindings, domains and secrets stay what they are. Cloudflare Access is not
     part of the deployment, so it is untouched.
   - Waits until the site is healthy and serves the commit (`/api/health` for Axo; the version tag
     for AXP). If it doesn't within 2.5 minutes, it serves the previous version again and fails.

## Rollback

The deploy log prints the command, for example:

```sh
CLOUDFLARE_API_TOKEN=… node tools/cd/cloudflare.mjs rollback axo-public-app <version-id>
```

`node tools/cd/cloudflare.mjs live axo-public-app` shows what is live and its commit tag. A
rollback serves an older Worker version; Durable Object schema steps are additive, so an older
version reads what a newer one wrote (`packages/axo-api-worker/src/schema.ts`).

## What a build can't check

The relay's end-to-end tests run a macOS axod, and Workers Builds runs Linux; run
`bazel test //packages/axo-api-worker:relay_test` on a Mac before a native release. The phone
apps have no release manifest the build can read, so their shipped protocol is assumed to be the
Mac release's.

## Triggers

Both are production triggers on `main`, in Workers Builds, made with the Cloudflare API
(`/accounts/{account}/builds/triggers`):

- `axo-public-app`: root `/`, build `tools/cd/build.sh axo`, deploy `tools/cd/deploy.sh axo`.
- `axp-www`: root `/`, build `tools/cd/build.sh axp`, deploy `tools/cd/deploy.sh axp`.
