import assert from "node:assert/strict";
import { test } from "node:test";
import { harness } from "./harness";

test("/api/health answers without an account, uncached, with the build it is", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const response = await fetch(new URL("api/health", h.url));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(await response.json(), { ok: true, build: "dev" });
});
