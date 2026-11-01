/**
 * `curl -fsSL https://axo.leostera.dev/install | sh` installs the Mac app from `/cdn/Axo.app`,
 * starts it, and, given `?code=ABCD-EFGH`, hands the pairing code to the app.
 *
 * The download is the signed bundle `scripts/publish-mac.sh` uploads. curl leaves no quarantine
 * attribute, so macOS runs the app from where it is installed instead of translocating it; a
 * translocated app cannot register its axod LaunchAgent.
 */

/** The R2 key `scripts/publish-mac.sh` writes the latest Mac app to. */
export const MAC_APP_KEY = "mac/Axo.app.zip";

/**
 * The R2 key `//:publish` writes the served build's description to, after its zip, so it never
 * names a build that is not there yet: `{ "build": 260, "axodBuild": 23, "commit": "…" }`.
 * Axo.app reads it to offer "Upgrade to Build N" from its menu.
 */
export const MAC_APP_MANIFEST_KEY = "mac/Axo.app.json";

/** The team that signs Axo.app and its axod helper; the script refuses any other signature. */
const SIGNING_TEAM = "RGH6S9S55G";

/** A pairing code, as `HostPairingCode` parses it: two groups of four from an unambiguous alphabet. */
const PAIRING_CODE = /^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/;

type PairingCode = { readonly value: string };

/** `null` when absent, `undefined` when present but not a pairing code. */
function parsePairingCode(raw: string | null): PairingCode | null | undefined {
  if (raw === null || raw.trim() === "") return null;
  const value = raw.trim().toUpperCase();
  return PAIRING_CODE.test(value) ? { value } : undefined;
}

const SCRIPT_HEADERS = {
  "Content-Type": "text/x-shellscript; charset=utf-8",
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
};

export function installScriptResponse(request: Request): Response {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
  }
  const url = new URL(request.url);
  const code = parsePairingCode(url.searchParams.get("code"));
  // Still a script, so `curl | sh` prints the reason instead of running an HTML page.
  const body = code === undefined
    ? "#!/bin/sh\necho 'axo install: the pairing code should look like ABCD-EFGH' >&2\nexit 1\n"
    : installScript(url.origin, code);
  return new Response(request.method === "HEAD" ? null : body, {
    status: code === undefined ? 400 : 200,
    headers: SCRIPT_HEADERS,
  });
}

export async function macAppResponse(request: Request, bucket: R2Bucket): Promise<Response> {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
  }
  const object = request.method === "HEAD" ? await bucket.head(MAC_APP_KEY) : await bucket.get(MAC_APP_KEY);
  if (!object) return new Response("Not found", { status: 404, headers: { "Cache-Control": "no-store" } });
  const headers = new Headers({
    "Content-Type": "application/zip",
    "Content-Disposition": 'attachment; filename="Axo.app.zip"',
    "Content-Length": String(object.size),
    // Short, so a new build reaches installers within minutes.
    "Cache-Control": "public, max-age=60",
    ETag: object.httpEtag,
    "X-Content-Type-Options": "nosniff",
  });
  return new Response("body" in object ? (object as R2ObjectBody).body : null, { headers });
}

export async function macAppManifestResponse(request: Request, bucket: R2Bucket): Promise<Response> {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
  }
  const object = await bucket.get(MAC_APP_MANIFEST_KEY);
  if (!object) return new Response("Not found", { status: 404, headers: { "Cache-Control": "no-store" } });
  const headers = new Headers({
    "Content-Type": "application/json; charset=utf-8",
    // As short as the zip's, so the two agree within a minute.
    "Cache-Control": "public, max-age=60",
    ETag: object.httpEtag,
    "X-Content-Type-Options": "nosniff",
  });
  return new Response(request.method === "HEAD" ? null : object.body, { headers });
}

/** Single-quotes `value` for POSIX sh. The inputs are an origin and a parsed code, but be safe. */
function shellQuote(value: string): string {
  return `'${value.replaceAll("'", `'"'"'`)}'`;
}

export function installScript(origin: string, code: PairingCode | null): string {
  return `#!/bin/sh
# Installs Axo, the Mac app at ${origin}, and starts it.
#   curl -fsSL ${origin}/install | sh
#   curl -fsSL '${origin}/install?code=ABCD-EFGH' | sh   # and pair this Mac
# AXO_INSTALL_DIR picks the folder (default: /Applications, or ~/Applications when that is not writable).
set -eu

AXO_ORIGIN=${shellQuote(origin)}
AXO_PAIRING_CODE=${shellQuote(code?.value ?? "")}
AXO_TEAM_ID=${shellQuote(SIGNING_TEAM)}
AXO_BUNDLE_ID='dev.leostera.axo'
AXO_AGENT_LABEL='dev.leostera.axo.axod'

say() { printf '\\033[1m==>\\033[0m %s\\n' "$*"; }
warn() { printf '\\033[33mwarning:\\033[0m %s\\n' "$*" >&2; }
fail() { printf '\\033[31maxo install:\\033[0m %s\\n' "$*" >&2; exit 1; }

# One function, so sh reads the whole script before running any of it: a cut-off download runs
# nothing, and no command can read the rest of the script from the pipe as its input.
main() {
[ "$(uname -s)" = Darwin ] || fail "Axo runs on macOS only."
[ "$(uname -m)" = arm64 ] || fail "Axo needs a Mac with Apple silicon."
macos_major=$(sw_vers -productVersion | cut -d. -f1)
[ "$macos_major" -ge 14 ] || fail "Axo needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."
[ "$(id -u)" -ne 0 ] || fail "run this as yourself, not with sudo: axod runs as your user."

if [ -n "\${AXO_INSTALL_DIR:-}" ]; then
  install_dir=$AXO_INSTALL_DIR
elif [ -w /Applications ]; then
  install_dir=/Applications
else
  install_dir=$HOME/Applications
fi
mkdir -p "$install_dir"
app=$install_dir/Axo.app

# Stage beside the destination, so replacing the app is a rename on one volume.
stage=$(mktemp -d "$install_dir/.axo-install.XXXXXX")
# An app zipped with read-only modes stays read-only when unpacked; rm needs to write its folders.
trap 'chmod -R u+w "$stage" 2>/dev/null; rm -rf "$stage"' EXIT
trap 'exit 130' INT TERM

say "Downloading Axo from $AXO_ORIGIN"
curl -fL --progress-bar -o "$stage/Axo.app.zip" "$AXO_ORIGIN/cdn/Axo.app.zip" \\
  || fail "could not download $AXO_ORIGIN/cdn/Axo.app.zip"
ditto -x -k "$stage/Axo.app.zip" "$stage/unpacked" || fail "the download is not a readable zip"
new_app=$stage/unpacked/Axo.app
[ -d "$new_app" ] || fail "the download has no Axo.app in it"
# macOS moves a folder to another folder only if it may write the folder; modes are not signed.
chmod -R u+w "$new_app"

say "Checking its signature"
codesign --verify --deep --strict "$new_app" 2>/dev/null || fail "the downloaded Axo.app has a broken signature"
team=$(codesign -dv "$new_app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[ "$team" = "$AXO_TEAM_ID" ] || fail "the downloaded Axo.app is signed by team '$team', not Axo's ($AXO_TEAM_ID)"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$new_app/Contents/Info.plist")
[ "$bundle_id" = "$AXO_BUNDLE_ID" ] || fail "the download is $bundle_id, not Axo"
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$new_app/Contents/Info.plist")
# A quarantined app is translocated to a read-only copy that cannot register axod.
xattr -dr com.apple.quarantine "$new_app" 2>/dev/null || true

if [ "$(osascript -e "application id \\"$AXO_BUNDLE_ID\\" is running" 2>/dev/null || echo false)" = true ]; then
  say "Quitting the running Axo"
  osascript -e "tell application id \\"$AXO_BUNDLE_ID\\" to quit" >/dev/null 2>&1 || true
  waited=0
  while [ "$(osascript -e "application id \\"$AXO_BUNDLE_ID\\" is running" 2>/dev/null || echo false)" = true ]; do
    [ "$waited" -lt 30 ] || fail "Axo did not quit; quit it and run this again"
    sleep 1
    waited=$((waited + 1))
  done
fi

say "Installing Axo build $build in $install_dir"
if [ -e "$app" ]; then
  chmod -R u+w "$app" 2>/dev/null || true
  mv "$app" "$stage/previous.app"
fi
if ! mv "$new_app" "$app"; then
  [ -e "$stage/previous.app" ] && mv "$stage/previous.app" "$app"
  fail "could not move Axo.app into $install_dir"
fi
# Make axo:// links (pairing) open this copy.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" 2>/dev/null || true

if ! command -v pi >/dev/null 2>&1; then
  warn "Pi is not on your PATH. Axo's Sessions run it; install it with:"
  warn "  curl -fsSL https://pi.dev/install.sh | sh"
fi

say "Starting Axo"
if [ -n "$AXO_PAIRING_CODE" ]; then
  # The link opens Remote Access settings with the code filled in.
  open -a "$app" "axo://pair/$AXO_PAIRING_CODE"
else
  open "$app"
fi

# Axo registers axod as a login item on first launch; wait for launchd to run it.
waited=0
until launchctl print "gui/$(id -u)/$AXO_AGENT_LABEL" 2>/dev/null | grep -q 'state = running'; do
  if [ "$waited" -ge 30 ]; then
    warn "axod has not started yet. If macOS asked, allow Axo under System Settings > General > Login Items."
    break
  fi
  sleep 1
  waited=$((waited + 1))
done
if [ "$waited" -lt 30 ]; then say "axod is running"; fi

if [ -n "$AXO_PAIRING_CODE" ]; then
  say "Axo is installed. Click Link in its Remote Access settings to pair this Mac with code $AXO_PAIRING_CODE."
else
  say "Axo is installed. To use it from your phone or the web, pair this Mac in Axo > Settings > Remote Access."
fi
}

main "$@"
`;
}
