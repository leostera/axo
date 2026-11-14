#!/usr/bin/env bash
# Exercise publication ordering with fake Git/signing/CDN/upload commands. No network.
set -euo pipefail
publisher=$1 helper=$2
root=$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/publish-test.XXXXXX")
trap 'chmod -R u+w "$root"; rm -rf "$root"' EXIT
mkdir -p "$root/bin" "$root/app/Axo.app/Contents/MacOS"
plist=$root/app/Axo.app/Contents/Info.plist
/usr/bin/plutil -create xml1 "$plist"
for pair in 'CFBundleVersion 342' 'AXODBuildNumber 94' 'AXOGitCommit aaaaaaa' 'CFBundleShortVersionString 0.71'; do
  key=${pair%% *} value=${pair#* }
  /usr/bin/plutil -insert "$key" -string "$value" "$plist"
done
printf match > "$root/app/Axo.app/Contents/identity"
printf executable > "$root/app/Axo.app/Contents/MacOS/Axo"
/usr/bin/ditto -c -k --keepParent "$root/app/Axo.app" "$root/input.zip"
mkdir -p "$root/wrong/Axo.app/Contents"
printf other > "$root/wrong/Axo.app/Contents/identity"
/usr/bin/ditto -c -k --keepParent "$root/wrong/Axo.app" "$root/wrong.zip"
cat > "$root/bin/git" <<'SH'
#!/usr/bin/env bash
case "$*" in *status*) exit 0 ;; *rev-parse*) printf '%040d\n' 0 | tr 0 a ;; *) exit 1 ;; esac
SH
cat > "$root/bin/codesign" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --verify) exit 0 ;;
  -dv) echo TeamIdentifier=TESTTEAM >&2 ;;
  -dvvv) for last; do :; done; printf 'CDHash=%s\n' "$(<"$last/Contents/identity")" >&2 ;;
  *) exit 1 ;;
esac
SH
cat > "$root/bin/lipo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_ARCH:-arm64}"
SH
cat > "$root/bin/curl" <<'SH'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in -o) output=$2; shift 2 ;; -w) shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac
done
if [[ "$url" == */latest.json ]]; then
  printf '{"version":"0.70","build":341}' > "$output"
  printf '%s' "${POINTER_STATUS:-200}"
elif [[ "${EXISTING:-}" == matching ]]; then
  cp "$FIXTURE_ROOT/input.zip" "$output"; printf 200
elif [[ "${EXISTING:-}" == wrong ]]; then
  cp "$FIXTURE_ROOT/wrong.zip" "$output"; printf 200
else
  printf '{}' > "$output"; printf 404
fi
SH
cat > "$root/bin/cf" <<'SH'
#!/usr/bin/env bash
key=$4
printf '%s\n' "$key" >> "$FIXTURE_ROOT/uploads"
if [[ "$key" == releases/* && "${FAIL_ARCHIVE:-}" == 1 ]]; then exit 1; fi
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --file ]]; then file=$2; break; fi
  shift
done
if [[ "$key" == latest.json ]]; then cp "$file" "$FIXTURE_ROOT/result.json"; fi
SH
chmod +x "$root/bin/"*
export PATH="$root/bin:$PATH" FIXTURE_ROOT=$root BUILD_WORKSPACE_DIRECTORY=$root
publish() { bash "$publisher" "$root/app/Axo.app" "$root/input.zip" "$root/bin/cf" TESTTEAM test-bucket https://axo.test/cdn/latest.json "$helper"; }
publish
expected='releases/axo-0.71-aaaaaaaaaaaa-aarch64-apple-darwin.zip
latest.json'
[[ "$(<"$root/uploads")" == "$expected" ]]
[[ "$(/usr/bin/plutil -extract artifacts.aarch64-apple-darwin raw -o - "$root/result.json")" == axo-0.71-aaaaaaaaaaaa-aarch64-apple-darwin.zip ]]
rm "$root/uploads" "$root/result.json"
EXISTING=matching publish
[[ "$(<"$root/uploads")" == latest.json ]]
rm "$root/uploads" "$root/result.json"
unset EXISTING
if FAIL_ARCHIVE=1 publish; then echo 'archive failure must stop publication' >&2; exit 1; fi
[[ "$(<"$root/uploads")" == releases/* && ! -e "$root/result.json" ]]
rm "$root/uploads"
if EXISTING=wrong publish; then echo 'different immutable content must fail' >&2; exit 1; fi
[[ ! -e "$root/uploads" ]]
if POINTER_STATUS=503 publish; then echo 'pointer errors must fail closed' >&2; exit 1; fi
[[ ! -e "$root/uploads" ]]
unset FAIL_ARCHIVE EXISTING POINTER_STATUS
MOCK_ARCH=x86_64 publish
[[ "$(/usr/bin/plutil -extract artifacts.x86_64-apple-darwin raw -o - "$root/result.json")" == axo-0.71-aaaaaaaaaaaa-x86_64-apple-darwin.zip ]]
echo 'publication ordering, failure, immutability and target tests pass'
