/**
 * `curl -fsSL https://axo.leostera.dev/install | sh` selects an immutable Mac archive from latest.json,
 * starts it, and, given `?code=ABCD-EFGH`, hands the pairing code to the app.
 *
 * The download is the signed bundle `bazel run //:publish` uploads. curl leaves no quarantine
 * attribute, so macOS runs the app from where it is installed instead of translocating it; a
 * translocated app cannot register its axod LaunchAgent.
 */

import { ARTIFACT, ARTIFACT_PREFIX, LATEST_RELEASE_KEY, macArtifact, parseRelease, type Release } from "./releases.ts";

/** Bootstrap-only archive retained for pre-latest.json releases. Never written by the new publisher. */
export const MAC_APP_KEY = "mac/Axo.app.zip";

/** Bootstrap-only manifest until the first latest.json is published. */
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

const noStore = { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" };
function methodError(request: Request): Response | undefined {
  if (request.method !== "GET" && request.method !== "HEAD") return new Response("Method not allowed", { status: 405, headers: { ...noStore, Allow: "GET, HEAD" } });
}
async function latest(bucket: R2Bucket): Promise<Release | null> {
  const object = await bucket.get(LATEST_RELEASE_KEY);
  if (!object) return null;
  if (object.size > 65536) throw new Error("oversized release pointer");
  return parseRelease(JSON.parse(await object.text()));
}
function jsonResponse(request: Request, value: unknown): Response {
  return new Response(request.method === "HEAD" ? null : JSON.stringify(value), { headers: { ...noStore, "Content-Type": "application/json; charset=utf-8" } });
}
async function archiveResponse(request: Request, bucket: R2Bucket, key: string, filename: string, immutable: boolean): Promise<Response> {
  const object = request.method === "HEAD" ? await bucket.head(key) : await bucket.get(key);
  if (!object) return new Response("Not found", { status: 404, headers: noStore });
  return new Response("body" in object ? (object as R2ObjectBody).body : null, { headers: {
    "Content-Type": filename.endsWith(".zip") ? "application/zip" : "application/gzip",
    "Content-Disposition": 'attachment; filename="' + filename + '"',
    "Content-Length": String(object.size), ETag: object.httpEtag,
    "Cache-Control": immutable ? "public, max-age=31536000, immutable" : "no-store",
    "X-Content-Type-Options": "nosniff",
  } });
}
export async function latestReleaseResponse(request: Request, bucket: R2Bucket): Promise<Response> {
  const invalid = methodError(request); if (invalid) return invalid;
  try {
    const release = await latest(bucket);
    return release ? jsonResponse(request, release) : new Response("Not found", { status: 404, headers: noStore });
  } catch { return new Response("Invalid release manifest", { status: 503, headers: noStore }); }
}
export async function releaseArtifactResponse(request: Request, bucket: R2Bucket, filename: string): Promise<Response> {
  const invalid = methodError(request); if (invalid) return invalid;
  if (!ARTIFACT.test(filename)) return new Response("Not found", { status: 404, headers: noStore });
  return archiveResponse(request, bucket, ARTIFACT_PREFIX + filename, filename, true);
}
/** Compatibility views for already-installed clients. Only bootstrap from legacy objects
 * while latest.json is absent; never mask a malformed or unsupported new release. */
export async function macAppResponse(request: Request, bucket: R2Bucket): Promise<Response> {
  const invalid = methodError(request); if (invalid) return invalid;
  try {
    const release = await latest(bucket);
    if (!release) return archiveResponse(request, bucket, MAC_APP_KEY, "Axo.app.zip", false);
    const filename = macArtifact(release);
    if (!filename) return new Response("No compatible Mac artifact", { status: 404, headers: noStore });
    return archiveResponse(request, bucket, ARTIFACT_PREFIX + filename, filename, false);
  } catch { return new Response("Invalid release manifest", { status: 503, headers: noStore }); }
}
export async function macAppManifestResponse(request: Request, bucket: R2Bucket): Promise<Response> {
  const invalid = methodError(request); if (invalid) return invalid;
  try {
    const release = await latest(bucket);
    if (release) {
      if (!macArtifact(release)) return new Response("No compatible Mac artifact", { status: 404, headers: noStore });
      const { version, build, axodBuild, commit } = release;
      return jsonResponse(request, { version, build, axodBuild, commit });
    }
    const object = await bucket.get(MAC_APP_MANIFEST_KEY);
    if (!object) return new Response("Not found", { status: 404, headers: noStore });
    return new Response(request.method === "HEAD" ? null : object.body, { headers: { ...noStore, "Content-Type": "application/json; charset=utf-8" } });
  } catch { return new Response("Invalid release manifest", { status: 503, headers: noStore }); }
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
AXO_APP_LABEL='dev.leostera.axo.app'

say() { printf '\\033[1m==>\\033[0m %s\\n' "$*"; }
warn() { printf '\\033[33mwarning:\\033[0m %s\\n' "$*" >&2; }
fail() { printf '\\033[31maxo install:\\033[0m %s\\n' "$*" >&2; exit 1; }

# One function, so sh reads the whole script before running any of it: a cut-off download runs
# nothing, and no command can read the rest of the script from the pipe as its input.
main() {
[ "$(uname -s)" = Darwin ] || fail "Axo runs on macOS only."
case "$(uname -m)" in
  arm64) target=aarch64-apple-darwin ;;
  x86_64) target=x86_64-apple-darwin ;;
  *) fail "Unsupported Mac architecture" ;;
esac
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

say "Checking the latest Axo release"
status=$(curl -sSL -o "$stage/latest.json" -w '%{http_code}' "$AXO_ORIGIN/cdn/latest.json") || fail "could not fetch latest.json"
case "$status" in
  200)
    artifact=$(/usr/bin/plutil -extract "artifacts.$target" raw -o - "$stage/latest.json" 2>/dev/null) \\
      || artifact=$(/usr/bin/plutil -extract artifacts.universal-apple-darwin raw -o - "$stage/latest.json" 2>/dev/null) \\
      || fail "This release has no artifact for $target"
    case "$artifact" in *[!a-zA-Z0-9._-]*|*..*) fail "Invalid release artifact filename" ;; esac
    case "$artifact" in axo-*.zip) ;; *) fail "Invalid Mac archive" ;; esac
    expected_build=$(/usr/bin/plutil -extract build raw -o - "$stage/latest.json") || fail "Missing release build"
    ;;
  404)
    # Bootstrap only: the Worker can deploy before the first new-format publication.
    # Pre-cutover archives were ARM-only. Never give one to an Intel Mac.
    [ "$target" = aarch64-apple-darwin ] || fail "No release for $target yet"
    artifact=Axo.app.zip
    expected_build=
    ;;
  *) fail "Could not inspect latest release (HTTP $status)" ;;
esac
say "Downloading $artifact"
curl -fL --progress-bar -o "$stage/Axo.app.zip" "$AXO_ORIGIN/cdn/$artifact" \\
  || fail "could not download $artifact"
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
[ -z "$expected_build" ] || [ "$build" = "$expected_build" ] || fail "Downloaded build does not match the selected release"
# A quarantined app is translocated to a read-only copy that cannot register axod.
xattr -dr com.apple.quarantine "$new_app" 2>/dev/null || true

# Axo only closes its windows when asked to quit, and launchd brings it back if it dies, so stop
# it as Axo replaces itself: take launchd's job away, ask each running Axo to quit for good
# (dev.leostera.axo.quitForReplacement with its pid), and force any still there after 5s.
say "Quitting the running Axo"
launchctl bootout "gui/$(id -u)/$AXO_APP_LABEL" >/dev/null 2>&1 || true
AXO_BUNDLE_ID=$AXO_BUNDLE_ID osascript -l JavaScript >/dev/null 2>&1 <<'JXA' || fail "Axo did not quit; quit it from its menu bar icon (Quit Axo) and run this again"
ObjC.import("AppKit");
const id = $.NSProcessInfo.processInfo.environment.objectForKey("AXO_BUNDLE_ID").js;
const running = () => {
  const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(id);
  const list = [];
  for (let i = 0; i < apps.count; i++) if (!apps.objectAtIndex(i).terminated) list.push(apps.objectAtIndex(i));
  return list;
};
const waitGone = (seconds) => {
  for (let i = 0; i < seconds * 10 && running().length > 0; i++) delay(0.1);
  return running().length === 0;
};
if (!waitGone(2)) {
  const pids = $.NSMutableArray.array;
  running().forEach((app) => pids.addObject($.NSNumber.numberWithInt(app.processIdentifier)));
  $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(
    "dev.leostera.axo.quitForReplacement", $(), $.NSDictionary.dictionaryWithObjectForKey(pids, "pids"), true);
  if (!waitGone(5)) {
    running().forEach((app) => app.forceTerminate);
    if (!waitGone(5)) throw new Error("Axo is still running");
  }
}
JXA

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
