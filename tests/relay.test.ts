import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { build } from "esbuild";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { mkdtemp, rm, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

let mf: Miniflare;
let directory: string;
before(async () => {
  directory = await mkdtemp(join(tmpdir(), "axo-test-"));
  const bundle = join(directory, "worker.mjs");
  await build({ entryPoints: ["service/src/index.ts"], outfile: bundle, bundle: true, format: "esm", platform: "neutral", external: ["cloudflare:workers"] });
  mf = new Miniflare(convertV4MiniflareOptions({
    modules: true, script: await readFile(bundle, "utf8"), compatibilityDate: "2026-10-08", compatibilityFlags: ["nodejs_compat"],
    durableObjects: { TEST_RELAY: { className: "Relay", useSQLite: true } },
    bindings: { ACCESS_TEAM_URL: "https://example.cloudflareaccess.com", ACCESS_AUD: "test", ACCESS_USER_EMAIL: "me@example.com", ACCESS_HOST_CLIENT_ID: "host.access" },
  }));
});
after(async () => { await mf?.dispose(); if (directory) await rm(directory, { recursive: true, force: true }); });

test("public entrypoint rejects missing or forged Access tokens", async () => {
  for (const headers of [{}, { "Cf-Access-Jwt-Assertion": "forged" }]) {
    const response = await mf.dispatchFetch("https://example.com/connect/phone", { headers });
    assert.equal(response.status, 401);
  }
});

async function room() {
  const namespace = await mf.getDurableObjectNamespace("TEST_RELAY");
  return namespace.get(namespace.idFromName(crypto.randomUUID()));
}

// Direct DO calls are test-only. The public entrypoint always verifies Access first.
async function connect(stub: Awaited<ReturnType<typeof room>>, role: "phone" | "host") {
  const response = await stub.fetch("https://internal/", { headers: { Upgrade: "websocket", "X-Axo-Role": role, "X-Axo-Expiry": String(Date.now() + 60_000) } });
  assert.equal(response.status, 101);
  const socket = response.webSocket!;
  const pending: unknown[] = [];
  const waiters: Array<(value: unknown) => void> = [];
  socket.addEventListener("message", event => {
    const value: unknown = JSON.parse(String(event.data));
    const waiter = waiters.shift();
    if (waiter) waiter(value); else pending.push(value);
  });
  socket.accept();
  return {
    socket,
    send: (frame: unknown) => socket.send(JSON.stringify(frame)),
    next: () => pending.length ? Promise.resolve(pending.shift()) : new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("Timed out waiting for relay")), 3000);
      waiters.push(value => { clearTimeout(timer); resolve(value); });
    }),
  };
}

test("phone reports offline and does not queue a prompt", async () => {
  const stub = await room();
  const phone = await connect(stub, "phone");
  assert.deepEqual(await phone.next(), { type: "presence", online: false });
  phone.send({ type: "prompt", id: "c", sessionId: "s", text: "hello" });
  assert.deepEqual(await phone.next(), { type: "error", id: "c", message: "Mac offline. Nothing was queued." });
  phone.socket.close();
});

test("relay carries prompts and snapshots bidirectionally and rejects a second host", async () => {
  const stub = await room();
  const host = await connect(stub, "host");
  assert.deepEqual(await host.next(), { type: "sync" });
  const phone = await connect(stub, "phone");
  assert.deepEqual(await phone.next(), { type: "presence", online: true });
  assert.deepEqual(await host.next(), { type: "sync" });
  const prompt = { type: "prompt", id: "c", sessionId: "s", text: "hello" };
  phone.send(prompt);
  assert.deepEqual(await host.next(), prompt);
  const snapshot = { type: "snapshot", sessionId: "s", state: "idle", messages: [{ id: "m", role: "assistant", text: "Hello back" }], hasEarlierMessages: false, question: null };
  host.send(snapshot);
  assert.deepEqual(await phone.next(), snapshot);
  const outputRequest = { type: "tool_output", id: "output", sessionId: "s", toolCallId: "tool", offset: 0 };
  phone.send(outputRequest);
  assert.deepEqual(await host.next(), outputRequest);
  const output = { ...outputRequest, text: "Full output", nextOffset: null };
  host.send(output);
  assert.deepEqual(await phone.next(), output);
  const historyRequest = { type: "history", id: "history", sessionId: "s", beforeId: "m" };
  phone.send(historyRequest);
  assert.deepEqual(await host.next(), historyRequest);
  const history = { ...historyRequest, messages: snapshot.messages, hasEarlierMessages: true };
  host.send(history);
  assert.deepEqual(await phone.next(), history);
  const duplicate = await stub.fetch("https://internal/", { headers: { "X-Axo-Role": "host", "X-Axo-Expiry": String(Date.now() + 60_000) } });
  assert.equal(duplicate.status, 409);
  phone.send(snapshot);
  assert.deepEqual(await phone.next(), { type: "error", message: "Invalid or oversized message" });
  host.socket.close();
  assert.deepEqual(await phone.next(), { type: "presence", online: false });
  phone.socket.close();
});

test("internal upgrade also rejects expired identities", async () => {
  const stub = await room();
  const response = await stub.fetch("https://internal/", { headers: { "X-Axo-Role": "phone", "X-Axo-Expiry": "1" } });
  assert.equal(response.status, 403);
});
