import assert from "node:assert/strict";
import { test } from "node:test";
import { deployment } from "../deployment.ts";

const production = deployment({ isPreview: false });
const preview = deployment({ isPreview: true });

test("no deployment has a workers.dev URL or preview URLs", () => {
  for (const target of [production, preview]) {
    assert.equal(target.workersDev, false, target.name);
    assert.equal(target.previewUrls, false, target.name);
  }
});

test("production serves axo.leostera.dev from its own buckets", () => {
  assert.equal(production.name, "axo-public-app");
  assert.deepEqual(production.domains, ["axo.leostera.dev"]);
  assert.deepEqual(production.buckets, { publicSessions: "axo-public-sessions", cdn: "axo-cdn", assets: "axo-assets" });
});

test("a preview shares no Worker, domain or bucket with production", () => {
  assert.notEqual(preview.name, production.name);
  assert.ok(preview.domains.every((domain) => !production.domains.includes(domain)));
  const productionBuckets = new Set(Object.values(production.buckets));
  for (const bucket of Object.values(preview.buckets)) assert.ok(!productionBuckets.has(bucket), bucket);
});
