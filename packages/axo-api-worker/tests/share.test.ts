import assert from "node:assert/strict";
import { test } from "node:test";
import { SHARE_LIMITS, SHARE_PUBLISH_METHOD, accountShareListSchema, sharePublishResultSchema, sharedSnapshotSchema, type SharedSnapshot } from "@axo/protocol";
import { buildSharedMessages, redactSnapshot } from "@axo/pi-axo/share";
import { harness, signIn, type Harness } from "./harness";
import { connectHost, pairHost } from "./account-support";

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

/** A paired Mac's registered socket, as axod opens it. */
async function registeredDaemon(h: Harness) {
  const session = await signIn(h);
  const host = await pairHost(h, session, "Share fixture");
  const daemon = await connectHost(h, session, host);
  return { daemon, session, hostId: host.hostId, hostGeneration: host.hostGeneration };
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

test("a snapshot larger than a share may be is refused, and nothing is stored", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const { daemon, hostId, hostGeneration } = await registeredDaemon(h);
  const text = "z".repeat(40_000);
  const big: SharedSnapshot = {
    ...snapshot,
    messages: Array.from({ length: Math.ceil(SHARE_LIMITS.snapshotBytes / text.length) + 1 }, (_, i) =>
      ({ id: `m${i}`, role: "user" as const, text, timestamp: i, tool: null, images: [] })),
  };
  assert.ok(sharedSnapshotSchema.safeParse(big).success, "the snapshot is otherwise valid");
  const reply = await daemon.call(SHARE_PUBLISH_METHOD, { hostId, hostGeneration, snapshot: big });
  assert.ok("error" in reply, "refused");
  const bucket = await h.mf.getR2Bucket("PUBLIC_SESSIONS") as unknown as R2Bucket;
  assert.equal((await bucket.list({ prefix: "shares/" })).objects.length, 0);
});

test("an account publishes at most SHARE_LIMITS.perHour shares an hour", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const { daemon, hostId, hostGeneration } = await registeredDaemon(h);
  for (let i = 0; i < SHARE_LIMITS.perHour; i++) {
    const reply = await daemon.call(SHARE_PUBLISH_METHOD, { hostId, hostGeneration, snapshot });
    assert.ok("result" in reply, `share ${i}: ${JSON.stringify(reply)}`);
  }
  const refused = await daemon.call(SHARE_PUBLISH_METHOD, { hostId, hostGeneration, snapshot });
  assert.ok("error" in refused, "one more is refused");
  const bucket = await h.mf.getR2Bucket("PUBLIC_SESSIONS") as unknown as R2Bucket;
  assert.equal((await bucket.list({ prefix: "shares/" })).objects.length, SHARE_LIMITS.perHour);
});

test("an account lists its shares and unpublishes one; another account cannot", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const { daemon, session, hostId, hostGeneration } = await registeredDaemon(h);
  const reply = await daemon.call(SHARE_PUBLISH_METHOD, { hostId, hostGeneration, snapshot });
  assert.ok("result" in reply);
  const { shareId } = sharePublishResultSchema.parse(reply.result);

  const listed = accountShareListSchema.parse(await (await fetch(new URL("api/v1/account/shares", h.url), { headers: session.headers })).json());
  assert.deepEqual(listed.shares.map((share) => [share.shareId, share.hostId]), [[shareId, hostId]]);
  assert.ok(listed.shares[0]!.bytes > 0);

  const other = await signIn(h);
  const otherList = accountShareListSchema.parse(await (await fetch(new URL("api/v1/account/shares", h.url), { headers: other.headers })).json());
  assert.deepEqual(otherList.shares, []);
  const stolen = await fetch(new URL(`api/v1/account/shares/${shareId}/delete`, h.url), { method: "POST", headers: other.headers });
  assert.equal(stolen.status, 404, "another account's share is not found");

  const bucket = await h.mf.getR2Bucket("PUBLIC_SESSIONS") as unknown as R2Bucket;
  assert.ok(await bucket.head(`shares/${shareId}.json`), "still published");
  const deleted = await fetch(new URL(`api/v1/account/shares/${shareId}/delete`, h.url), { method: "POST", headers: session.headers });
  assert.equal(deleted.status, 204);
  assert.equal(await bucket.head(`shares/${shareId}.json`), null, "unpublished");
  const after = accountShareListSchema.parse(await (await fetch(new URL("api/v1/account/shares", h.url), { headers: session.headers })).json());
  assert.deepEqual(after.shares, []);
});

test("a share published before the account kept a list is unpublished by its publisher only", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const owner = await signIn(h);
  const other = await signIn(h);
  const shareId = "aaaaaaaaaaaaaaaaaaaaaa";
  const bucket = await h.mf.getR2Bucket("PUBLIC_SESSIONS") as unknown as R2Bucket;
  await bucket.put(`shares/${shareId}.json`, JSON.stringify(snapshot), { customMetadata: { principal: owner.accountId, hostId: crypto.randomUUID() } });

  const stolen = await fetch(new URL(`api/v1/account/shares/${shareId}/delete`, h.url), { method: "POST", headers: other.headers });
  assert.equal(stolen.status, 404);
  assert.ok(await bucket.head(`shares/${shareId}.json`));
  const deleted = await fetch(new URL(`api/v1/account/shares/${shareId}/delete`, h.url), { method: "POST", headers: owner.headers });
  assert.equal(deleted.status, 204);
  assert.equal(await bucket.head(`shares/${shareId}.json`), null);
});
