import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { build } from "esbuild";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { filePageSchema, sharedFileSchema, MAX_FILE_BYTES } from "../shared/files";

let mf: Miniflare;
let directory: string;
let script: string;
function emulator() {
  return new Miniflare({ ...convertV4MiniflareOptions({ modules: true, script,
    compatibilityDate: "2026-10-08", compatibilityFlags: ["nodejs_compat"],
    durableObjects: { TEST_RELAY: { className: "Relay", useSQLite: true } }, r2Buckets: ["FILES"],
    bindings: { FILE_STORAGE_ENABLED: "true" },
  }), resourcePersistencePath: directory });
}
before(async () => {
  directory = await mkdtemp(join(tmpdir(), "axo-files-runtime-"));
  const bundled = await build({ entryPoints: ["tests/fixtures/files-worker.ts"], write: false, bundle: true, format: "esm", platform: "neutral", external: ["cloudflare:workers"] });
  script = bundled.outputFiles[0].text;
  mf = emulator();
  const response = await mf.dispatchFetch("https://files.test/host", { headers: { Upgrade: "websocket" } });
  assert.equal(response.status, 101);
  const socket = response.webSocket!;
  socket.accept();
  socket.send(JSON.stringify({ type: "snapshot", sessionId: "session", viewId: "view", state: "idle", messages: [], hasEarlierMessages: false, question: null }));
  await new Promise(resolve => setTimeout(resolve, 30));
  socket.close();
});
after(async () => { await mf?.dispose(); if (directory) await rm(directory, { recursive: true, force: true }); });
const digest = (data: string) => createHash("sha256").update(data).digest("hex");
async function request(path: string, method = "GET", body?: string) {
  return mf.dispatchFetch(`https://files.test/files/sessions/${path}`, { method, ...(body !== undefined ? { body } : {}) });
}
async function reserve(content: string, changes: Record<string, unknown> = {}) {
  const attributes = { requestId: crypto.randomUUID(), filename: "report.md", mediaType: "text/markdown", byteLength: Buffer.byteLength(content), sha256: digest(content), ...changes };
  const response = await request("session/uploads", "POST", JSON.stringify(attributes));
  return { response, attributes };
}

test("immutable session files upload, list and download with no connected Mac", async () => {
  const { response, attributes } = await reserve("# Shared report\n");
  assert.equal(response.status, 200);
  const pending = sharedFileSchema.parse(await response.json());
  assert.equal(pending.state, "pending");
  const hidden = await request(`session/files/${pending.id}/content`);
  assert.equal(hidden.status, 409);
  const put = await request(`session/uploads/${pending.id}/content`, "PUT", "# Shared report\n");
  assert.equal(put.status, 200, await put.clone().text());
  assert.equal(sharedFileSchema.parse(await put.json()).state, "ready");
  const retry = await request("session/uploads", "POST", JSON.stringify(attributes));
  assert.equal(sharedFileSchema.parse(await retry.json()).id, pending.id);
  const download = await request(`session/files/${pending.id}/content`);
  assert.equal(await download.text(), "# Shared report\n");
  assert.equal(download.headers.get("Cache-Control"), "private, no-store");
  assert.equal(download.headers.get("X-Content-Type-Options"), "nosniff");
  const page = filePageSchema.parse(await (await request("session/files")).json());
  assert.ok(page.files.some(file => file.id === pending.id));
  assert.ok(!JSON.stringify(page).includes("object_key"));
  assert.ok(!JSON.stringify(page).includes("files/"));
  const overwrite = await request(`session/uploads/${pending.id}/content`, "PUT", "changed");
  assert.equal(overwrite.status, 200);
  assert.equal(await (await request(`session/files/${pending.id}/content`)).text(), "# Shared report\n");
});

test("upload IDs reject conflicting attributes; session scope and metadata are validated", async () => {
  const { response, attributes } = await reserve("original");
  assert.equal(response.status, 200);
  const file = sharedFileSchema.parse(await response.json());
  assert.equal((await request("session/uploads", "POST", JSON.stringify({ ...attributes, filename: "different.txt" }))).status, 409);
  assert.equal((await request(`wrong-session/files/${file.id}`)).status, 404);
  for (const changes of [{ filename: "../secret" }, { filename: "a\nb" }, { mediaType: "text/html" }, { byteLength: MAX_FILE_BYTES + 1 }]) {
    assert.equal((await reserve("bad", changes)).response.status, 400);
  }
  assert.equal((await request("session/uploads", "POST", "x".repeat(4097))).status, 413);
  assert.equal((await request("session/files?cursor=nan")).status, 400);
});

test("a size or checksum mismatch is never published", async () => {
  for (const body of ["short", "wrong-but-same-size"]) {
    const { response } = await reserve("correct-same-length");
    const file = sharedFileSchema.parse(await response.json());
    assert.equal((await request(`session/uploads/${file.id}/content`, "PUT", body)).status, 422);
    assert.equal((await request(`session/files/${file.id}/content`)).status, 409);
  }
});

test("a written object survives a lost metadata commit and is recovered by maintenance", async () => {
  const { response } = await reserve("recover me");
  const file = sharedFileSchema.parse(await response.json());
  assert.equal((await mf.dispatchFetch("https://files.test/stage-without-commit", { method: "POST", body: JSON.stringify({ id: file.id, content: "recover me" }) })).status, 200);
  assert.equal(sharedFileSchema.parse(await (await request(`session/files/${file.id}`)).json()).state, "pending");
  assert.equal((await mf.dispatchFetch("https://files.test/expire-attempt", { method: "POST", body: JSON.stringify({ id: file.id }) })).status, 200);
  assert.equal(sharedFileSchema.parse(await (await request(`session/files/${file.id}`)).json()).state, "ready");
  assert.equal(await (await request(`session/files/${file.id}/content`)).text(), "recover me");
});

test("cancelled in-flight publication is cleaned up without resurrection", async () => {
  const { response } = await reserve("cancel me");
  const file = sharedFileSchema.parse(await response.json());
  await mf.dispatchFetch("https://files.test/stage-without-commit", { method: "POST", body: JSON.stringify({ id: file.id, content: "cancel me" }) });
  assert.equal(sharedFileSchema.parse(await (await request(`session/files/${file.id}`, "DELETE")).json()).state, "deleting");
  await mf.dispatchFetch("https://files.test/expire-attempt", { method: "POST", body: JSON.stringify({ id: file.id }) });
  assert.equal(sharedFileSchema.parse(await (await request(`session/files/${file.id}`)).json()).state, "deleted");
  assert.equal((await request(`session/uploads/${file.id}/content`, "PUT", "cancel me")).status, 410);
});

test("an elapsed lease and missing HEAD never release a still-outstanding writer key", async () => {
  const { response } = await reserve("late but valid");
  const file = sharedFileSchema.parse(await response.json());
  await mf.dispatchFetch("https://files.test/start-without-write", { method: "POST", body: JSON.stringify({ id: file.id }) });
  await mf.dispatchFetch("https://files.test/expire-attempt", { method: "POST", body: JSON.stringify({ id: file.id }) });
  assert.equal((await request(`session/uploads/${file.id}/content`, "PUT", "late but valid")).status, 409);
  assert.equal((await mf.dispatchFetch("https://files.test/late-write", { method: "POST", body: JSON.stringify({ id: file.id, content: "late but valid" }) })).status, 200);
  await mf.dispatchFetch("https://files.test/expire-attempt", { method: "POST", body: JSON.stringify({ id: file.id }) });
  assert.equal(sharedFileSchema.parse(await (await request(`session/files/${file.id}`)).json()).state, "ready");
  assert.equal(await (await request(`session/files/${file.id}/content`)).text(), "late but valid");
});

test("deletion tracks an outstanding absent object until a late write can be removed", async () => {
  const { response } = await reserve("late cancelled");
  const file = sharedFileSchema.parse(await response.json());
  await mf.dispatchFetch("https://files.test/start-without-write", { method: "POST", body: JSON.stringify({ id: file.id }) });
  await request(`session/files/${file.id}`, "DELETE");
  await mf.dispatchFetch("https://files.test/expire-attempt", { method: "POST", body: JSON.stringify({ id: file.id }) });
  assert.equal(sharedFileSchema.parse(await (await request(`session/files/${file.id}`)).json()).state, "deleting");
  assert.equal((await mf.dispatchFetch("https://files.test/late-write", { method: "POST", body: JSON.stringify({ id: file.id, content: "late cancelled" }) })).status, 200);
  await mf.dispatchFetch("https://files.test/expire-attempt", { method: "POST", body: JSON.stringify({ id: file.id }) });
  assert.equal(sharedFileSchema.parse(await (await request(`session/files/${file.id}`)).json()).state, "deleted");
  assert.equal((await request(`session/files/${file.id}/content`)).status, 410);
});

test("file inventory is demand-paged with stable cursors, not one unbounded list", async () => {
  for (let index = 0; index < 22; index++) assert.equal((await reserve(`file ${index}`)).response.status, 200);
  const first = filePageSchema.parse(await (await request("session/files")).json());
  assert.equal(first.files.length, 20);
  assert.ok(first.nextCursor);
  const next = filePageSchema.parse(await (await request(`session/files?cursor=${first.nextCursor}`)).json());
  const firstIds = new Set(first.files.map(file => file.id));
  assert.ok(next.files.every(file => !firstIds.has(file.id)));
});

test("deletion is idempotent, leaves a tombstone, and prevents resurrection", async () => {
  const { response } = await reserve("delete me");
  const file = sharedFileSchema.parse(await response.json());
  assert.equal((await request(`session/uploads/${file.id}/content`, "PUT", "delete me")).status, 200);
  const deleted = sharedFileSchema.parse(await (await request(`session/files/${file.id}`, "DELETE")).json());
  assert.equal(deleted.state, "deleted");
  assert.equal((await request(`session/files/${file.id}/content`)).status, 410);
  assert.equal(sharedFileSchema.parse(await (await request(`session/files/${file.id}`, "DELETE")).json()).state, "deleted");
  assert.equal((await request(`session/uploads/${file.id}/content`, "PUT", "delete me")).status, 410);
});

test("pending reservations count against the 1 GiB workbench quota", async () => {
  let admitted = 0;
  for (let index = 0; index < 42; index++) {
    const { response } = await reserve("", { byteLength: MAX_FILE_BYTES });
    if (response.status === 413) break;
    assert.equal(response.status, 200);
    admitted++;
  }
  assert.equal(admitted, 40);
});

test("registered sessions, file index and R2 bytes survive a cold runtime restart", async () => {
  const { response } = await reserve("persist across restart");
  const file = sharedFileSchema.parse(await response.json());
  assert.equal((await request(`session/uploads/${file.id}/content`, "PUT", "persist across restart")).status, 200);
  await mf.dispose();
  mf = emulator();
  const lookup = await request(`session/files/${file.id}`);
  assert.equal(lookup.status, 200, await lookup.clone().text());
  const restored = sharedFileSchema.parse(await lookup.json());
  assert.equal(restored.state, "ready");
  assert.equal(restored.sha256, digest("persist across restart"));
  assert.equal(await (await request(`session/files/${file.id}/content`)).text(), "persist across restart");

  // Rollback disables publication, not authenticated access to already ready bytes.
  const disabled = { "X-Test-Writes": "off" };
  assert.equal((await mf.dispatchFetch("https://files.test/files/sessions/session/uploads", { method: "POST", headers: disabled, body: "{}" })).status, 503);
  assert.equal(await (await mf.dispatchFetch(`https://files.test/files/sessions/session/files/${file.id}/content`, { headers: disabled })).text(), "persist across restart");
  assert.equal((await mf.dispatchFetch(`https://files.test/files/sessions/session/files/${file.id}`, { method: "DELETE", headers: disabled })).status, 200);
});
