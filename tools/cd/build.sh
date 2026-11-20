#!/usr/bin/env bash
# Continuous delivery, build step (tools/cd/README.md): Cloudflare Workers Builds runs this on
# every push to main. It refuses anything but the exact commit pushed, stops if nothing the service
# is built from changed since the live commit, checks it, checks the Worker against the clients
# people have installed, then builds.
# Nothing here deploys; tools/cd/deploy.sh does, after this succeeds.
#
#   tools/cd/build.sh axo   # axo.leostera.dev: the web app, the API and the relay, one Worker
#   tools/cd/build.sh axp   # axp.leostera.dev: the AXP specification site
set -euo pipefail

service="${1:?usage: tools/cd/build.sh axo|axp}"
root="$(git rev-parse --show-toplevel)"
cd "$root"
# shellcheck source=tools/cd/common.sh
. tools/cd/common.sh

log "build service=$service commit=$(git rev-parse HEAD) host=$(uname -srm) node=$(node --version) build=${WORKERS_CI_BUILD_UUID:-local}"
exact_source
rm -f "$(skip_marker "$service")"
if ! affected "$service"; then
  touch "$(skip_marker "$service")"
  log "nothing to build for $service"
  exit 0
fi
ensure_pnpm
pnpm install --frozen-lockfile

case "$service" in
  axo)
    site=sites/axo.leostera.dev
    step "protocol schemas" pnpm --dir packages/axo-api run schema:check
    step "protocol tests" bash -c "cd packages/axo-api && node --test tests/*.test.ts"
    step "runtime types" bash -c "cd $site && npx cf workers types"
    step "worker typecheck" pnpm --dir packages/axo-api-worker run typecheck
    step "site typecheck" bash -c "cd $site && npx tsc --noEmit"
    step "web typecheck" pnpm --dir packages/axo-web-app run typecheck
    step "web model tests" pnpm --dir packages/axo-web-app run test:model
    step "site tests" bash -c "cd $site && node --import tsx --test tests/*.test.mjs"

    # The clients people have installed: the release cdn/latest.json names. Its protocol package
    # is what the Mac and the apps of that release read and send (tests/shipped-client.test.ts).
    shipped="$(shipped_commit)"
    log "shipped client commit=$shipped"
    git cat-file -e "$shipped^{commit}" 2>/dev/null || git fetch --quiet --depth=1 https://github.com/leostera/axo.git "$shipped"
    rm -rf packages/axo-api/.shipped && mkdir -p packages/axo-api/.shipped
    git archive "$shipped" packages/axo-api/src | tar -x -C packages/axo-api/.shipped --strip-components=3
    export SHIPPED_PROTOCOL="$root/packages/axo-api/.shipped"

    # The Worker's own core suite (packages/axo-api-worker/package.json test:core), the Session
    # storage it keeps, and the shipped clients. The relay end-to-end tests need a macOS axod and
    # run on a Mac before a release, not here.
    core="$(node -e 'const s=require("./packages/axo-api-worker/package.json").scripts["test:core"]; console.log([...new Set(s.match(/tests\/[a-z0-9-]+\.test\.ts/g))].join(" "))')"
    step "worker tests" bash -c "cd packages/axo-api-worker && npx tsx --test --test-concurrency=1 $core tests/session-storage.test.ts tests/session-atxf.test.ts tests/health.test.ts tests/shipped-client.test.ts"

    # The tree must still be the commit: nothing above may have changed a tracked file.
    exact_source
    step "build" bash -c "cd $site && npx cf build"
    grep -q "$(git rev-parse HEAD)" "$site"/.cloudflare/output/v0/workers/default/bundle/assets/worker-entry-*.js \
      || fail "the built Worker does not carry commit $(git rev-parse HEAD)"
    ;;
  axp)
    site=sites/axp.leostera.dev
    exact_source
    step "build" pnpm --dir "$site" run build
    # Every schema is served at its $id, every example at /examples/, and every link resolves.
    step "site tests" bash -c "cd $site && node --test tests/site.test.mjs"
    ;;
  *)
    fail "unknown service $service"
    ;;
esac
log "built $service at $(git rev-parse HEAD)"
