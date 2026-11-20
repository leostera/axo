import assert from "node:assert/strict";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import { parseRelease, macArtifact } from "../src/releases.ts";
import { latestReleaseResponse, releaseArtifactResponse, macAppManifestResponse, macAppResponse, installScript, archiveCheckScript, MAC_APP_KEY, MAC_APP_MANIFEST_KEY } from "../src/install.ts";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";

const commit = "0123456789abcdef0123456789abcdef01234567";
const arm = "axo-0.71-0123456789ab-aarch64-apple-darwin.zip";
const universal = "axo-0.71-0123456789ab-universal-apple-darwin.zip";
const digest = "a".repeat(64);
const release = { version: "0.71", build: 342, axodBuild: 94, commit, artifacts: { "aarch64-apple-darwin": arm }, integrity: { "aarch64-apple-darwin": { sha256: digest, size: 1024 } } };
function bucket(entries) {
  const reads = [];
  const objects = new Map(Object.entries(entries));
  const metadata = value => ({ size: new TextEncoder().encode(value).length, httpEtag: '"fixture"' });
  return { reads, objects,
    async get(key) { reads.push(key); const value = objects.get(key); return value === undefined ? null : { ...metadata(value), text: async () => value, body: new Blob([value]).stream() }; },
    async head(key) { reads.push(key); const value = objects.get(key); return value === undefined ? null : metadata(value); },
  };
}
const request = (path, method = "GET") => new Request("https://axo.test/cdn/" + path, { method });
test("release parsing binds every basename to version, full commit and target", () => {
  const parsed = parseRelease(release);
  assert.equal(macArtifact(parsed), arm);
  assert.equal(macArtifact(parsed, "x86_64-apple-darwin"), undefined);
  const intel = arm.replace("aarch64", "x86_64");
  const intelIntegrity = { "x86_64-apple-darwin": { sha256: digest, size: 1024 } };
  const universalIntegrity = { "universal-apple-darwin": { sha256: digest, size: 1024 } };
  assert.equal(macArtifact(parseRelease({ ...release, artifacts: { "x86_64-apple-darwin": intel }, integrity: intelIntegrity }), "x86_64-apple-darwin"), intel);
  assert.equal(macArtifact(parseRelease({ ...release, artifacts: { "universal-apple-darwin": universal }, integrity: universalIntegrity }), "x86_64-apple-darwin"), universal);
  for (const change of [{ build: 0 }, { commit: "short" }, { artifacts: {} }, { version: "0.72" },
    { artifacts: { "aarch64-apple-darwin": "../bad.zip" } },
    { artifacts: { "aarch64-apple-darwin": "https://evil.test/app.zip" } },
    { artifacts: { "x86_64-apple-darwin": arm } }, { ignored: true }])
    assert.throws(() => parseRelease({ ...release, ...change }));
});
test("integrity names every artifact's exact bytes, and only pointers from before it may lack it", () => {
  assert.deepEqual(JSON.parse(JSON.stringify(parseRelease(release).integrity)), release.integrity);
  const { integrity: _, ...older } = release;
  assert.equal(parseRelease(older).integrity, undefined);
  const entry = release.integrity["aarch64-apple-darwin"];
  for (const integrity of [{}, [], { "x86_64-apple-darwin": entry },
    { ...release.integrity, "x86_64-apple-darwin": entry },
    { "aarch64-apple-darwin": { ...entry, sha256: "A".repeat(64) } },
    { "aarch64-apple-darwin": { ...entry, sha256: "short" } },
    { "aarch64-apple-darwin": { ...entry, size: 0 } },
    { "aarch64-apple-darwin": { ...entry, size: "1024" } },
    { "aarch64-apple-darwin": { ...entry, extra: true } }])
    assert.throws(() => parseRelease({ ...release, integrity }), JSON.stringify(integrity));
});
// The check runs macOS's stat and shasum, as the installer does on the Mac it installs on.
test("the installer reads nothing it downloaded until its size and SHA-256 match", { skip: process.platform !== "darwin" && "the installer's archive check runs on macOS" }, () => {
  const root = mkdtempSync(join(tmpdir(), "axo-archive-check-"));
  try {
    const file = join(root, "Axo.app.zip");
    writeFileSync(file, "archive bytes");
    const sha = createHash("sha256").update("archive bytes").digest("hex");
    const check = (size, sha256) => spawnSync("sh", ["-c",
      `set -eu\nfail() { printf '%s\\n' "$*" >&2; exit 1; }\n${archiveCheckScript()}\nverify_archive "$1" "$2" "$3"\nprintf ok`,
      "sh", file, String(size), sha256], { encoding: "utf8" });
    assert.equal(check(13, sha).stdout, "ok");
    assert.match(check(14, sha).stderr, /size/);
    assert.match(check(13, "b".repeat(64)).stderr, /SHA-256/);
  } finally { rmSync(root, { recursive: true, force: true }); }
  const script = installScript("https://axo.test", null);
  assert.ok(script.indexOf('verify_archive "$stage/Axo.app.zip"') < script.indexOf('ditto -x -k "$stage/Axo.app.zip"'));
  assert.ok(script.includes('--max-filesize "$expected_size"'));
  assert.ok(script.includes('fail "This release has no integrity for $selected"'));
});
test("latest pointer is uncached and old manifest/archive views derive from it", async () => {
  const store = bucket({ "latest.json": JSON.stringify(release), ["releases/" + arm]: "archive", [MAC_APP_KEY]: "stale" });
  const latest = await latestReleaseResponse(request("latest.json"), store);
  assert.equal(latest.headers.get("Cache-Control"), "no-store");
  assert.deepEqual(await latest.json(), release);
  assert.deepEqual(await (await macAppManifestResponse(request("Axo.app.json"), store)).json(), { version: "0.71", build: 342, axodBuild: 94, commit });
  assert.equal(await (await macAppResponse(request("Axo.app.zip"), store)).text(), "archive");
  assert.ok(!store.reads.includes(MAC_APP_KEY));
  assert.equal((await latestReleaseResponse(request("latest.json", "POST"), store)).status, 405);
  assert.equal(await (await latestReleaseResponse(request("latest.json", "HEAD"), store)).text(), "");
});
test("immutable downloads do not reread latest, support HEAD and never accept paths", async () => {
  const store = bucket({ ["releases/" + arm]: "old pinned archive", "latest.json": JSON.stringify({ ...release, version: "0.72" }) });
  const response = await releaseArtifactResponse(request(arm), store, arm);
  assert.equal(await response.text(), "old pinned archive");
  assert.match(response.headers.get("Cache-Control"), /immutable/);
  assert.deepEqual(store.reads, ["releases/" + arm]);
  const head = await releaseArtifactResponse(request(arm, "HEAD"), store, arm);
  assert.equal(head.headers.get("Content-Length"), "18");
  assert.equal(await head.text(), "");
  assert.equal((await releaseArtifactResponse(request("bad"), store, "../" + arm)).status, 404);
  assert.equal((await releaseArtifactResponse(request(arm, "POST"), store, arm)).status, 405);
});
test("legacy bootstrap only applies to missing pointers, never malformed new releases", async () => {
  const store = bucket({ [MAC_APP_KEY]: "bootstrap", [MAC_APP_MANIFEST_KEY]: '{"build":328}' });
  assert.equal((await latestReleaseResponse(request("latest.json"), store)).status, 404);
  assert.equal(await (await macAppResponse(request("Axo.app.zip"), store)).text(), "bootstrap");
  assert.deepEqual(await (await macAppManifestResponse(request("Axo.app.json"), store)).json(), { build: 328 });
  store.objects.set("latest.json", '{"artifacts":{}}');
  assert.equal((await macAppResponse(request("Axo.app.zip"), store)).status, 503);
  assert.equal((await macAppManifestResponse(request("Axo.app.json"), store)).status, 503);
});
test("installer parses and selects an immutable target without executing installation", () => {
  const script = installScript("https://axo.test", null);
  assert.equal(spawnSync("sh", ["-n"], { input: script }).status, 0);
  assert.ok(script.includes("/cdn/latest.json"));
  assert.ok(script.includes('"$AXO_ORIGIN/cdn/$artifact"'));
  assert.ok(script.includes('"$build" = "$expected_build"'));
});
