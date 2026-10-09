import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { build } from "esbuild";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { signFileUpload } from "../service/src/file-signing";
import { sharedFileSchema, uploadAuthorizationSchema } from "../shared/files";

const config = { R2_ACCOUNT_ID: "a".repeat(32), R2_BUCKET_NAME: "test-files", R2_ACCESS_KEY_ID: "synthetic-key", R2_SECRET_ACCESS_KEY: "synthetic-secret" };
const content = "Synthetic direct bytes";
const attributes = { requestId: crypto.randomUUID(), filename: "direct.txt", mediaType: "text/plain" as const, byteLength: Buffer.byteLength(content), sha256: createHash("sha256").update(content).digest("hex") };

test("R2 grants sign immutable condition, exact size, type, checksum and bounded expiry", async () => {
  const file = sharedFileSchema.parse({ ...attributes, id: crypto.randomUUID(), sessionId: "session", origin: "phone", createdAt: 0, state: "pending" });
  const grant = await signFileUpload({ file, key: `files/${file.id}/attempt`, expiresAt: Date.now() + 300_000 }, Date.now() + 60_000, config);
  uploadAuthorizationSchema.parse(grant);
  const url = new URL(grant.upload.url);
  assert.equal(url.searchParams.get("X-Amz-SignedHeaders"), "content-length;content-type;host;if-none-match;x-amz-checksum-sha256");
  assert.ok(Number(url.searchParams.get("X-Amz-Expires")) <= 60);
  assert.equal(grant.upload.headers["If-None-Match"], "*");
  assert.ok(!JSON.stringify(grant).includes(config.R2_SECRET_ACCESS_KEY));
  assert.throws(() => uploadAuthorizationSchema.parse({ ...grant, upload: { ...grant.upload, headers: { ...grant.upload.headers, Cookie: "must-not-leak" } } }));
  assert.throws(() => uploadAuthorizationSchema.parse({ ...grant, upload: { ...grant.upload, url: "https://untrusted.invalid/" } }));
});

test("direct completion verifies R2 metadata, tombstones remain unavailable and late bytes stay tracked", async () => {
  const bundled = await build({ entryPoints: ["tests/fixtures/files-worker.ts"], write: false, bundle: true, format: "esm", platform: "neutral", external: ["cloudflare:workers"] });
  const mf = new Miniflare(convertV4MiniflareOptions({ modules: true, script: bundled.outputFiles[0].text, compatibilityDate: "2026-10-08", compatibilityFlags: ["nodejs_compat"], durableObjects: { TEST_RELAY: { className: "Relay", useSQLite: true } }, r2Buckets: ["FILES"], bindings: { FILE_STORAGE_ENABLED: "true" } }));
  try {
    const host = await mf.dispatchFetch("https://files.test/host", { headers: { Upgrade: "websocket" } });
    host.webSocket!.accept();
    host.webSocket!.send(JSON.stringify({ type: "snapshot", sessionId: "session", viewId: "view", state: "idle", messages: [], hasEarlierMessages: false, question: null }));
    await new Promise(resolve => setTimeout(resolve, 30));
    const request = (path: string, method = "GET", body?: unknown) => mf.dispatchFetch(`https://files.test/${path}`, { method, ...(body ? { body: JSON.stringify(body) } : {}) });
    const reserved = sharedFileSchema.parse(await (await request("files/sessions/session/uploads", "POST", attributes)).json());
    const base = `files/sessions/session/uploads/${reserved.id}`;
    const grant = uploadAuthorizationSchema.parse(await (await request(`${base}/authorize`, "POST")).json());
    assert.ok(grant.upload);
    assert.equal((await request(`${base}/complete`, "POST")).status, 422);
    await request("late-write", "POST", { id: reserved.id, content });
    assert.equal(sharedFileSchema.parse(await (await request(`${base}/complete`, "POST")).json()).state, "ready");
    assert.equal(await (await request(`files/sessions/session/files/${reserved.id}/content`)).text(), content);
    assert.equal(sharedFileSchema.parse(await (await request(`files/sessions/session/files/${reserved.id}`, "DELETE")).json()).state, "deleted");
    const late = await request("late-write", "POST", { id: reserved.id, content });
    assert.deepEqual(await late.json(), { written: false }, "The empty sentinel must fence even a still-valid signed PUT");
    assert.equal((await request(`files/sessions/session/files/${reserved.id}/content`)).status, 410);
    assert.equal((await request(`${base}/complete`, "POST")).status, 409);
    assert.equal((await request(`${base}/authorize`, "POST")).status, 410);
    host.webSocket!.close();
  } finally { await mf.dispose(); }
});
