import assert from "node:assert/strict";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import { parseRelease, macArtifact } from "../src/releases.ts";
import { latestReleaseResponse, releaseArtifactResponse, macAppManifestResponse, macAppResponse, installScript, MAC_APP_KEY, MAC_APP_MANIFEST_KEY } from "../src/install.ts";

const commit = "0123456789abcdef0123456789abcdef01234567";
const arm = "axo-0.71-0123456789ab-aarch64-apple-darwin.zip";
const universal = "axo-0.71-0123456789ab-universal-apple-darwin.zip";
const release = { version: "0.71", build: 342, axodBuild: 94, commit, artifacts: { "aarch64-apple-darwin": arm } };
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
  assert.equal(macArtifact(parseRelease({ ...release, artifacts: { "x86_64-apple-darwin": intel } }), "x86_64-apple-darwin"), intel);
  assert.equal(macArtifact(parseRelease({ ...release, artifacts: { "universal-apple-darwin": universal } }), "x86_64-apple-darwin"), universal);
  for (const change of [{ build: 0 }, { commit: "short" }, { artifacts: {} }, { version: "0.72" },
    { artifacts: { "aarch64-apple-darwin": "../bad.zip" } },
    { artifacts: { "aarch64-apple-darwin": "https://evil.test/app.zip" } },
    { artifacts: { "x86_64-apple-darwin": arm } }, { ignored: true }])
    assert.throws(() => parseRelease({ ...release, ...change }));
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
