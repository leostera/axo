import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { build } from "esbuild";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { mkdtemp, rm, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const sessionId = "00000000-0000-4000-8000-000000000101";
const workspaceId = "00000000-0000-4000-8000-000000000201";
const conversationId = "pi-conversation-1";
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
      const timer = setTimeout(() => reject(new Error("Timed out waiting for relay")), 3_000);
      waiters.push(value => { clearTimeout(timer); resolve(value); });
    }),
  };
}

const catalog = {
  type: "catalog",
  catalog: { revision: 1, storeRevision: 2, workspaces: [{ id: workspaceId, name: "Project", kind: "project" }],
    sessions: [{ id: sessionId, workspaceId, name: "Build", conversationId, availability: "running" }] },
};

async function nextMatching(peer: Awaited<ReturnType<typeof connect>>, predicate: (value: any) => boolean) {
  for (let count = 0; count < 10; count++) {
    const value = await peer.next();
    if (predicate(value)) return value;
  }
  throw new Error("Expected relay frame was not received");
}

test("phone reports offline and does not queue a prompt", async () => {
  const stub = await room();
  const phone = await connect(stub, "phone");
  assert.deepEqual(await phone.next(), { type: "presence", online: false });
  const page = await phone.next() as { type: string; hostOnline: boolean };
  assert.equal(page.type, "catalog_page");
  assert.equal(page.hostOnline, false);
  phone.send({ type: "prompt", id: "c", sessionId, text: "hello" });
  assert.deepEqual(await phone.next(), { type: "error", id: "c", sessionId, message: "Mac offline. Nothing was queued." });
  phone.socket.close();
});

test("relay persists the catalog and routes only to the subscribed Axo session", async () => {
  const stub = await room();
  const host = await connect(stub, "host");
  assert.deepEqual(await host.next(), { type: "catalog_request", revision: 0 });
  host.send(catalog);
  const phone = await connect(stub, "phone");
  assert.deepEqual(await phone.next(), { type: "presence", online: true });
  // The host's send is asynchronous; the phone can observe revision 0 before the updated catalog broadcast.
  const initialCatalog = await nextMatching(phone, value => {
    const page = value as { type?: string; revision?: number };
    return page.type === "catalog_page" && page.revision === 1;
  }) as { type: string; revision: number; items: unknown[]; hostOnline: boolean };
  assert.equal(initialCatalog.hostOnline, true);
  assert.equal(initialCatalog.items.length, 2);

  phone.send({ type: "subscribe", id: "sub", sessionId });
  assert.deepEqual(await phone.next(), { type: "subscription", id: "sub", sessionId, hostOnline: true });
  assert.deepEqual(await host.next(), { type: "sync", sessionId });

  const prompt = { type: "prompt", id: "c", sessionId, text: "hello" };
  phone.send(prompt);
  assert.deepEqual(await host.next(), prompt);
  const snapshot = { type: "snapshot", sessionId, conversationId, viewId: "v", state: "idle",
    messages: [{ id: "m", role: "assistant", text: "Hello back" }], hasEarlierMessages: false, question: null };
  host.send(snapshot);
  assert.deepEqual(await phone.next(), snapshot);

  const outputRequest = { type: "tool_output", id: "output", sessionId, toolCallId: "tool", offset: 0 };
  phone.send(outputRequest);
  assert.deepEqual(await host.next(), outputRequest);
  const output = { type: "tool_output", id: "output", sessionId, conversationId,
    toolCallId: "tool", offset: 0, text: "Full output", nextOffset: null };
  host.send(output);
  assert.deepEqual(await phone.next(), output);

  const historyRequest = { type: "history", id: "history", sessionId, viewId: "v", beforeId: "m" };
  phone.send(historyRequest);
  assert.deepEqual(await host.next(), historyRequest);
  const history = { ...historyRequest, conversationId, messages: snapshot.messages, hasEarlierMessages: true, hasLaterMessages: false };
  host.send(history);
  assert.deepEqual(await phone.next(), history);

  const wrongDestination = { type: "prompt", id: "wrong", sessionId: "00000000-0000-4000-8000-000000000999", text: "no" };
  phone.send(wrongDestination);
  assert.deepEqual(await phone.next(), { type: "error", id: "wrong", sessionId: wrongDestination.sessionId,
    message: "Select this session before sending a command to it." });

  const duplicate = await stub.fetch("https://internal/", { headers: { "X-Axo-Role": "host", "X-Axo-Expiry": String(Date.now() + 60_000) } });
  assert.equal(duplicate.status, 409);
  phone.send(snapshot);
  assert.deepEqual(await phone.next(), { type: "error", message: "Phone protocol mismatch. Update the iOS app, then reconnect." });
  host.socket.close();
  assert.deepEqual(await phone.next(), { type: "presence", online: false });
  const offlineCatalog = await nextMatching(phone, value => (value as { type?: string }).type === "catalog_page") as { hostOnline: boolean };
  assert.equal(offlineCatalog.hostOnline, false);
  phone.socket.close();
});

test("phone workspace creation is explicitly forwarded to the Mac and acknowledged by command ID", async () => {
  const stub = await room();
  const host = await connect(stub, "host");
  assert.deepEqual(await host.next(), { type: "catalog_request", revision: 0 });
  host.send(catalog);

  const phone = await connect(stub, "phone");
  assert.deepEqual(await phone.next(), { type: "presence", online: true });
  await nextMatching(phone, value => (value as { type?: string; revision?: number }).type === "catalog_page"
    && (value as { revision?: number }).revision === 1);

  const request = { type: "create_workspace", id: "phone-create", name: "Phone project" };
  phone.send(request);
  assert.deepEqual(await host.next(), request);

  const acknowledgement = {
    type: "ack", id: "phone-create", disposition: "created",
    workspaceId: "00000000-0000-4000-8000-000000000202",
    sessionId: "00000000-0000-4000-8000-000000000102",
  };
  host.send(acknowledgement);
  assert.deepEqual(await phone.next(), acknowledgement);
  phone.socket.close();
  host.socket.close();
});

test("private file HTTP endpoints enforce Access before exposing feature state", async () => {
  for (const method of ["GET", "POST", "PUT", "DELETE"]) {
    const response = await mf.dispatchFetch("https://example.com/files/sessions/s/files/f", { method });
    assert.equal(response.status, 401);
  }
});

test("internal upgrade also rejects expired identities", async () => {
  const stub = await room();
  const response = await stub.fetch("https://internal/", { headers: { "X-Axo-Role": "phone", "X-Axo-Expiry": "1" } });
  assert.equal(response.status, 403);
});
