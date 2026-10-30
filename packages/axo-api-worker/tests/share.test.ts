import assert from "node:assert/strict";
import { test } from "node:test";
import { SHARE_PUBLISH_METHOD, sharePublishResultSchema, sharedSnapshotSchema, type SharedSnapshot } from "@axo/protocol";
import { buildSharedMessages, redactSnapshot } from "../../pi-axo/src/share.ts";
import { harness, Peer } from "./harness";

const snapshot: SharedSnapshot = {
  version: 1,
  title: "Fix the [redacted:name] flaky test",
  publishedAt: "2026-10-30T13:00:00.000Z",
  messages: [
    { id: "a", role: "user", text: "why is this test flaky?", timestamp: 1, tool: null, images: [] },
    {
      id: "b#0",
      role: "tool",
      text: "",
      timestamp: 2,
      tool: {
        callId: "call-1",
        name: "bash",
        kind: "shell",
        subtitle: null,
        command: "cargo test",
        status: "completed",
        output: "ok",
        outputTruncated: false,
      },
      images: [],
    },
  ],
};

async function registeredDaemon(h: Awaited<ReturnType<typeof harness>>) {
  const hostId = crypto.randomUUID();
  const hostGeneration = crypto.randomUUID();
  const daemon = await Peer.connectHost(h.url, await h.token("daemon"), hostId, "daemon");
  await daemon.negotiate();
  const registered = await daemon.call("axo.host.register", {
    protocolVersion: 2,
    hostId,
    hostGeneration,
    label: "Share fixture",
    hostKind: "macos",
    sessions: [],
  });
  assert.ok("result" in registered, "host registration should succeed");
  return { daemon, hostId, hostGeneration };
}

test("a registered host publishes a shared conversation into the public bucket", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const { daemon, hostId, hostGeneration } = await registeredDaemon(h);

  const reply = await daemon.call(SHARE_PUBLISH_METHOD, { hostId, hostGeneration, snapshot });
  assert.ok("result" in reply, JSON.stringify(reply));
  const { shareId, url } = sharePublishResultSchema.parse(reply.result);
  assert.equal(url, `https://axo.leostera.dev/s/${shareId}/fix-the-flaky-test`);

  const bucket = await h.mf.getR2Bucket("PUBLIC_SESSIONS") as unknown as R2Bucket;
  const stored = await bucket.get(`shares/${shareId}.json`);
  assert.ok(stored, "the snapshot is stored under its share ID");
  assert.deepEqual(JSON.parse(await stored.text()), snapshot);
  assert.equal(stored.httpMetadata?.contentType, "application/json; charset=utf-8");
  assert.equal(stored.customMetadata?.hostId, hostId);
  assert.ok(stored.customMetadata?.principal);

  const again = await daemon.call(SHARE_PUBLISH_METHOD, { hostId, hostGeneration, snapshot });
  assert.ok("result" in again);
  assert.notEqual(sharePublishResultSchema.parse(again.result).shareId, shareId, "every publish gets a new ID");
});

test("a share is refused for another host, a stale generation or a malformed snapshot", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const { daemon, hostId, hostGeneration } = await registeredDaemon(h);

  for (const params of [
    { hostId: crypto.randomUUID(), hostGeneration, snapshot },
    { hostId, hostGeneration: crypto.randomUUID(), snapshot },
    { hostId, hostGeneration, snapshot: { ...snapshot, messages: [] } },
    { hostId, hostGeneration, snapshot: { ...snapshot, extra: true } },
    { hostId, hostGeneration, snapshot: { ...snapshot, messages: [{ ...snapshot.messages[0], images: [{ url: "x" }] }] } },
  ]) {
    const reply = await daemon.call(SHARE_PUBLISH_METHOD, params);
    assert.ok("error" in reply, JSON.stringify(params).slice(0, 120));
  }
  const bucket = await h.mf.getR2Bucket("PUBLIC_SESSIONS") as unknown as R2Bucket;
  assert.equal((await bucket.list({ prefix: "shares/" })).objects.length, 0);
});

test("a client cannot publish a share", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const { hostId, hostGeneration } = await registeredDaemon(h);
  const client = await Peer.connectHost(h.url, await h.token("client"), hostId, "client");
  await client.negotiate();
  const reply = await client.call(SHARE_PUBLISH_METHOD, { hostId, hostGeneration, snapshot });
  assert.ok("error" in reply);
});

test("what pi-axo builds and redacts is what the cloud accepts, even at its limits", async () => {
  const huge = "y".repeat(100_000);
  const branch = [
    { type: "message", id: "u1", message: { role: "user", timestamp: 1, content: [{ type: "text", text: huge }] } },
    {
      type: "message", id: "a1", message: {
        role: "assistant", timestamp: 2, content: [
          { type: "text", text: huge },
          { type: "toolCall", id: "t1", name: "bash", arguments: { command: huge } },
          { type: "toolCall", id: "t2", name: "read", arguments: { path: huge } },
        ],
      },
    },
    { type: "message", id: "r1", message: { role: "toolResult", toolCallId: "t1", content: [{ type: "text", text: huge }] } },
  ];
  const built = { version: 1 as const, title: huge, publishedAt: new Date().toISOString(), messages: buildSharedMessages(branch) };
  await redactSnapshot(built, {
    async triage() { return 1; },
    async findSensitive() { return [{ text: "yyy", category: "a-long-category-name" }]; },
  });
  const parsed = sharedSnapshotSchema.safeParse(built);
  assert.ok(parsed.success, JSON.stringify(parsed.error?.issues.slice(0, 3)));
});
