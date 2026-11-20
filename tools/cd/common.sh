# Shared by tools/cd/build.sh and tools/cd/deploy.sh. Sourced, not run.

log() { printf '[cd] %s\n' "$*"; }
fail() { printf '[cd] FAILED: %s\n' "$*" >&2; exit 1; }

# Runs a named check, so the build log says which one failed.
step() {
  local name="$1"; shift
  log "check: $name"
  "$@" || fail "$name"
}

# Only the commit pushed to main, as it is in Git: no other branch, no other commit, no change.
exact_source() {
  local commit
  commit="$(git rev-parse HEAD)"
  # A push names its commit; a build started by hand names only the branch, so its checkout must
  # be that branch's tip on GitHub.
  if [[ "${WORKERS_CI_COMMIT_SHA:-}" =~ ^[0-9a-f]{40}$ ]]; then
    [ "$WORKERS_CI_COMMIT_SHA" = "$commit" ] || fail "checked out $commit, but the push was $WORKERS_CI_COMMIT_SHA"
  elif [ -n "${WORKERS_CI:-}" ]; then
    local tip
    tip="$(main_tip)"
    [ "$tip" = "$commit" ] || fail "checked out $commit, but main is $tip"
  fi
  if [ -n "${WORKERS_CI_BRANCH:-}" ] && [ "$WORKERS_CI_BRANCH" != "main" ]; then
    fail "branch $WORKERS_CI_BRANCH: only main deploys"
  fi
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    git status --short --untracked-files=no >&2
    fail "the tree differs from $commit"
  fi
}

# The commit main points at on GitHub now; a build of an older one must not deploy over it.
main_tip() {
  git ls-remote https://github.com/leostera/axo.git refs/heads/main | cut -f1
}

# The commit of the Mac release people install (cdn/latest.json). No answer is a failure: without
# it, nothing says the Worker still serves the installed clients.
shipped_commit() {
  local commit
  commit="$(curl -fsS --retry 3 https://axo.leostera.dev/cdn/latest.json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const c=JSON.parse(s).commit;if(!/^[0-9a-f]{40}$/.test(c))process.exit(1);console.log(c)})')" \
    || fail "could not read the shipped release from cdn/latest.json"
  printf '%s\n' "$commit"
}

# pnpm 10, as pnpm-lock.yaml was written with; installed outside the repository, whose
# package.json npm would otherwise read.
ensure_pnpm() {
  if pnpm --version 2>/dev/null | grep -q '^10\.'; then return; fi
  local prefix="${HOME}/.cd-pnpm"
  (cd "$HOME" && npm install --global --prefix "$prefix" pnpm@10.34.9 >/dev/null)
  export PATH="$prefix/bin:$PATH"
  pnpm --version | grep -q '^10\.' || fail "pnpm 10 is not available"
}
