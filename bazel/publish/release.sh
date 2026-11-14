#!/usr/bin/env bash
# Pure release identity helpers shared with publication tests. No network or installers.
release_version() { [[ "$1" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]]; }
release_newer() {
  release_version "$1" && release_version "$2" || return 2
  local major=${1%%.*} minor=${1#*.} old_major=${2%%.*} old_minor=${2#*.}
  (( major > old_major || (major == old_major && minor > old_minor) ))
}
release_target() {
  case "$1" in
    arm64) printf '%s\n' aarch64-apple-darwin ;;
    x86_64) printf '%s\n' x86_64-apple-darwin ;;
    'arm64 x86_64'|'x86_64 arm64') printf '%s\n' universal-apple-darwin ;;
    *) echo "Unsupported archive architectures: $1" >&2; return 1 ;;
  esac
}
release_filename() {
  release_version "$1" && [[ "$2" =~ ^[a-f0-9]{40}$ ]] && [[ "$3" =~ ^[a-z0-9_]+(-[a-z0-9]+){2,4}$ ]] || return 1
  printf 'axo-%s-%.12s-%s.zip\n' "$1" "$2" "$3"
}
release_manifest() {
  local output=$1 version=$2 build=$3 axod=$4 commit=$5 target=$6 filename
  filename=$(release_filename "$version" "$commit" "$target") || return 1
  [[ "$build" =~ ^[1-9][0-9]{0,8}$ && "$axod" =~ ^[1-9][0-9]{0,8}$ ]] || return 1
  /usr/bin/plutil -create xml1 "$output"
  /usr/bin/plutil -insert version -string "$version" "$output"
  /usr/bin/plutil -insert build -integer "$build" "$output"
  /usr/bin/plutil -insert axodBuild -integer "$axod" "$output"
  /usr/bin/plutil -insert commit -string "$commit" "$output"
  /usr/bin/plutil -insert artifacts -json '{}' "$output"
  /usr/bin/plutil -insert "artifacts.$target" -string "$filename" "$output"
  /usr/bin/plutil -convert json "$output"
}
