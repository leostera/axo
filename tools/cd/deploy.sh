#!/usr/bin/env bash
# Continuous delivery, deploy step (tools/cd/README.md): Workers Builds runs this after
# tools/cd/build.sh succeeded. It deploys the output that build made, only if the commit is still
# the tip of main, then checks that the live Worker is that commit and healthy. If it is not, it
# serves the version that was live before again, and fails.
#
#   tools/cd/deploy.sh axo|axp
set -euo pipefail

service="${1:?usage: tools/cd/deploy.sh axo|axp}"
root="$(git rev-parse --show-toplevel)"
cd "$root"
# shellcheck source=tools/cd/common.sh
. tools/cd/common.sh

case "$service" in
  axo) worker=axo-public-app; site=sites/axo.leostera.dev; url=https://axo.leostera.dev ;;
  axp) worker=axp-www; site=sites/axp.leostera.dev; url=https://axp.leostera.dev ;;
  *) fail "unknown service $service" ;;
esac

if [ -e "$(skip_marker "$service")" ]; then
  log "$service is unchanged; nothing to deploy"
  exit 0
fi

commit="$(git rev-parse HEAD)"
tag="${commit:0:12}"
exact_source
tip="$(main_tip)"
if [ "$tip" != "$commit" ]; then
  # A later push is building; it deploys, and this one must not land after it.
  log "superseded: main is $tip, not $commit; not deploying"
  exit 0
fi

before="$(node tools/cd/cloudflare.mjs live "$worker")"
log "live before: $before"
previous="$(printf '%s' "$before" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).version))')"
log "rollback: node tools/cd/cloudflare.mjs rollback $worker $previous"

# The bindings, domains and secrets are the ones cloudflare.config.ts declares and the Worker has;
# nothing is provisioned, so a binding without its resource fails instead of creating one.
(cd "$site" && npx cf deploy --prebuilt --no-provision --tag "$tag" \
  --message "$commit by Workers Builds ${WORKERS_CI_BUILD_UUID:-local}") || fail "deploy"

healthy() {
  case "$service" in
    axo) curl -fsS --max-time 10 "$url/api/health" | grep -q "\"build\":\"$commit\"" && curl -fsS --max-time 10 -o /dev/null "$url/" ;;
    axp) curl -fsS --max-time 10 -o /dev/null "$url/" && node tools/cd/cloudflare.mjs live "$worker" | grep -q "\"tag\":\"$tag\"" ;;
  esac
}
for attempt in $(seq 1 30); do
  if healthy; then
    log "live: $worker serves $commit ($(node tools/cd/cloudflare.mjs live "$worker"))"
    exit 0
  fi
  sleep 5
done

log "not live and healthy after deploy; rolling back to $previous"
node tools/cd/cloudflare.mjs rollback "$worker" "$previous" || true
fail "$worker did not serve $commit healthily; rolled back to $previous"
