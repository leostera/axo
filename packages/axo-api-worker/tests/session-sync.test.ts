import assert from "node:assert/strict";
import { test } from "node:test";
import {
  appendResultSchema,
  chainAtResultSchema,
  hostSyncResultSchema,
  truncateResultSchema,
  type ClientRecord,
} from "@axo/protocol";
import type { Peer } from "../testing/client";
import { harness, signIn, type AccountSession, type Harness } from "./harness";
import { FakeTranscript, assistantMessage, connectClient, connectHost, pairHost, userMessage, type PairedHost } from "./account-support";

type Notification = { method?: string; params?: Record<string, unknown> };

/** The next notification `method` on `peer`, skipping others. */
async function until(peer: Peer, method: string): Promise<Record<string, unknown>> {
  for (;;) {
    const message = (await peer.next()) as Notification;
    if (message.method === method) return message.params!;
  }
}

/** Whether `pending` settles within `ms`. */
async function settles(pending: Promise<unknown>, ms = 400): Promise<boolean> {
  return Promise.race([
    pending.then(() => true, () => true),
    new Promise<boolean>((resolve) => setTimeout(() => resolve(false), ms)),
  ]);
}

async function call<T>(peer: Peer, method: string, params: unknown, schema?: { parse(value: unknown): T }): Promise<T> {
  const reply = await peer.call(method, params);
  assert.ok("result" in reply, `${method}: ${JSON.stringify(reply)}`);
  return schema ? schema.parse(reply.result) : (reply.result as T);
}

type Fixture = { h: Harness; session: AccountSession; host: PairedHost; daemon: Peer; transcript: FakeTranscript; round: number };

/** A paired, connected host with one synced Session of `lines` records. */
async function fixture(t: { after(fn: () => unknown): void }, lines = 3): Promise<Fixture> {
  const h = await harness();
  t.after(() => h.close());
  const session = await signIn(h);
  const host = await pairHost(h, session);
  const daemon = await connectHost(h, session, host);
  t.after(() => daemon.close());
  const transcript = await FakeTranscript.create();
  for (let index = 0; index < lines; index++) await transcript.write(userMessage(`line ${index + 1}`));
  const synced = await call(daemon, "axo.host.sync", { hostId: host.hostId, hostGeneration: host.hostGeneration, round: 1, sessions: [transcript.manifestRow()] }, hostSyncResultSchema);
  assert.deepEqual(synced.sessions, [{ sessionId: transcript.sessionId, state: "unknown" }]);
  if (lines > 0) {
    const appended = await append(daemon, transcript, 1, 1, true);
    assert.equal(appended.outcome, "committed");
  }
  return { h, session, host, daemon, transcript, round: 1 };
}

function append(daemon: Peer, transcript: FakeTranscript, from: number, epoch = 1, header = false, to?: number) {
  return call(daemon, "axo.host.session.append", {
    sessionId: transcript.sessionId,
    epoch,
    from,
    ...(header ? { header: transcript.transcript.header } : {}),
    records: transcript.records(from, to),
  }, appendResultSchema);
}

test("a host's appends are verified, committed and acknowledged, and a retry changes nothing", async (t) => {
  const { daemon, transcript, host } = await fixture(t);
  const { chain } = transcript.transcript;
  assert.deepEqual(await append(daemon, transcript, 2), { outcome: "committed", epoch: 1, count: 3, chain }, "a retry overlapping committed records is acknowledged again");

  await transcript.write(userMessage("four"), userMessage("five"));
  const gap = await call(daemon, "axo.host.session.append", { sessionId: transcript.sessionId, epoch: 1, from: 5, records: transcript.records(5) }, appendResultSchema);
  assert.equal(gap.outcome, "gap");
  assert.equal(gap.count, 3);

  const forged = transcript.records(4).map((record, index) => (index === 0 ? { ...record, hash: transcript.records(1)[0]!.hash } : record));
  const conflict = await call(daemon, "axo.host.session.append", { sessionId: transcript.sessionId, epoch: 1, from: 4, records: forged }, appendResultSchema);
  assert.equal(conflict.outcome, "conflict", "a hash the cloud does not compute is refused");

  const committed = await append(daemon, transcript, 4);
  assert.deepEqual(committed, { outcome: "committed", epoch: 1, count: 5, chain: transcript.transcript.chain });

  const known = await call(daemon, "axo.host.sync", { hostId: host.hostId, hostGeneration: host.hostGeneration, round: 2, sessions: [transcript.manifestRow()] }, hostSyncResultSchema);
  assert.deepEqual(known.sessions, [{ sessionId: transcript.sessionId, state: "known", epoch: 1, count: 5, chain: transcript.transcript.chain, heads: transcript.transcript.heads }]);
  const stale = await call(daemon, "axo.host.sync", { hostId: host.hostId, hostGeneration: host.hostGeneration, round: 1, sessions: [] }, hostSyncResultSchema);
  assert.equal(stale.applied, false, "a manifest from an older round changes nothing");
});

test("a diverged copy is found with chainAt and cut back with truncate, which starts a new epoch", async (t) => {
  const { daemon, transcript } = await fixture(t);
  const chains = await call(daemon, "axo.host.session.chainAt", { sessionId: transcript.sessionId, round: 1, positions: [0, 1, 3, 4] }, chainAtResultSchema);
  assert.deepEqual(chains.chains, [transcript.transcript.chainAt(0), transcript.transcript.chainAt(1), transcript.transcript.chainAt(3), null]);

  const mismatch = await call(daemon, "axo.host.session.truncate", { sessionId: transcript.sessionId, round: 1, keep: 1, expectedChain: transcript.transcript.chainAt(2) }, truncateResultSchema);
  assert.equal(mismatch.outcome, "mismatch");
  const truncated = await call(daemon, "axo.host.session.truncate", { sessionId: transcript.sessionId, round: 1, keep: 1, expectedChain: transcript.transcript.chainAt(1) }, truncateResultSchema);
  assert.deepEqual(truncated, { round: 1, outcome: "truncated", epoch: 2, count: 1, chain: transcript.transcript.chainAt(1) });

  assert.equal((await append(daemon, transcript, 2, 1)).outcome, "epoch", "an append for the old epoch is refused");
  assert.deepEqual(await append(daemon, transcript, 2, 2), { outcome: "committed", epoch: 2, count: 3, chain: transcript.transcript.chain });
});

test("a client opens a Session by window, gets live records one acknowledged batch at a time, and pages back", async (t) => {
  const { h, session, daemon, transcript, host } = await fixture(t);
  const { client, hello } = await connectClient(h, session);
  t.after(() => client.close());
  assert.deepEqual(hello.hosts.map(({ hostId, online }) => ({ hostId, online })), [{ hostId: host.hostId, online: true }]);
  assert.deepEqual(hello.sessions.map(({ sessionId, head }) => ({ sessionId, head })), [{ sessionId: transcript.sessionId, head: 3 }]);

  const opened = await call<{ epoch: number; records: ClientRecord[]; cursor: number; older: number | null }>(client, "axo.client.session.open", { hostId: host.hostId, sessionId: transcript.sessionId, window: { last: 2 } });
  assert.deepEqual(opened.records.map((record) => record.cursor), [2, 3]);
  assert.equal(opened.records[0]!.line, transcript.transcript.records[1]!.line, "records carry Pi's raw line");
  assert.deepEqual({ epoch: opened.epoch, cursor: opened.cursor, older: opened.older }, { epoch: 1, cursor: 3, older: 2 });

  await transcript.write(userMessage("four"));
  await append(daemon, transcript, 4);
  const live = await until(client, "axo.client.session.records");
  assert.deepEqual((live.records as ClientRecord[]).map((record) => record.cursor), [4]);

  // Not acknowledged yet: the next record waits, and the socket stays open.
  await transcript.write(userMessage("five"));
  await append(daemon, transcript, 5);
  const pending = until(client, "axo.client.session.records");
  assert.equal(await settles(pending), false, "nothing more is sent before the acknowledgement");
  client.send({ jsonrpc: "2.0", method: "axo.client.session.ack", params: { sessionId: transcript.sessionId, cursor: 4 } });
  const next = await pending;
  assert.deepEqual((next.records as ClientRecord[]).map((record) => record.cursor), [5]);

  const older = await call<{ records: ClientRecord[]; older: number | null }>(client, "axo.client.session.older", { sessionId: transcript.sessionId, before: 2, limit: 5 });
  assert.deepEqual(older.records.map((record) => record.cursor), [1]);
  assert.equal(older.older, null);

  const resumed = await call<{ records: ClientRecord[]; cursor: number }>(client, "axo.client.session.open", { hostId: host.hostId, sessionId: transcript.sessionId, have: { epoch: 1, cursor: 3 } });
  assert.deepEqual(resumed.records.map((record) => record.cursor), [4, 5], "a client that holds part of a Session gets only the rest");
});

test("progress reaches an open Session and is cleared by the record it previews", async (t) => {
  const { h, session, daemon, transcript, host } = await fixture(t, 1);
  const { client } = await connectClient(h, session);
  t.after(() => client.close());
  await call(client, "axo.client.session.open", { hostId: host.hostId, sessionId: transcript.sessionId });

  daemon.send({ jsonrpc: "2.0", method: "axo.host.session.progress", params: { sessionId: transcript.sessionId, slot: "message", snapshot: { role: "assistant", content: [{ type: "text", text: "Wri" }] }, at: 1 } });
  const progress = await until(client, "axo.client.session.progress");
  assert.equal(progress.slot, "message");
  assert.notEqual(progress.snapshot, null);

  await transcript.write(assistantMessage("Written."));
  await append(daemon, transcript, 2);
  const cleared = await until(client, "axo.client.session.progress");
  assert.deepEqual({ slot: cleared.slot, snapshot: cleared.snapshot }, { slot: "message", snapshot: null });
});

test("a truncate resets clients, who continue in the new epoch", async (t) => {
  const { h, session, daemon, transcript, host } = await fixture(t);
  const { client } = await connectClient(h, session);
  t.after(() => client.close());
  await call(client, "axo.client.session.open", { hostId: host.hostId, sessionId: transcript.sessionId });

  await call(daemon, "axo.host.session.truncate", { sessionId: transcript.sessionId, round: 1, keep: 1, expectedChain: transcript.transcript.chainAt(1) });
  const reset = await until(client, "axo.client.session.reset");
  assert.deepEqual(reset, { sessionId: transcript.sessionId, epoch: 2, keep: 1 });

  await append(daemon, transcript, 2, 2);
  const records = await until(client, "axo.client.session.records");
  assert.equal(records.epoch, 2);
  assert.deepEqual((records.records as ClientRecord[]).map((record) => record.cursor), [2, 3]);
});

test("a command reaches the host, and fails at once when the host is offline", async (t) => {
  const { h, session, daemon, transcript, host } = await fixture(t);
  const { client } = await connectClient(h, session);
  t.after(() => client.close());
  const params = { target: { hostId: host.hostId, hostGeneration: host.hostGeneration }, sessionId: transcript.sessionId, text: "Hello" };
  const prompt = client.call("axo.client.command", { hostId: host.hostId, method: "axo.remote.session.prompt", params });
  const forwarded = (await daemon.next()) as { id: string; method: string; params: unknown };
  assert.equal(forwarded.method, "axo.remote.session.prompt");
  assert.deepEqual(forwarded.params, params);
  daemon.send({ jsonrpc: "2.0", id: forwarded.id, result: { accepted: true } });
  const accepted = await prompt;
  assert.ok("result" in accepted);
  assert.deepEqual(accepted.result, { accepted: true });

  daemon.close();
  const presence = await until(client, "axo.client.hosts");
  assert.equal((presence.hosts as Array<{ online: boolean }>)[0]!.online, false);
  const offline = await client.call("axo.client.command", { hostId: host.hostId, method: "axo.remote.session.prompt", params });
  assert.ok("error" in offline);
  assert.equal(offline.error.code, -32005, "nothing is queued for an offline host");
});

test("a Session the host stops listing is archived, never deleted, and metadata only moves forward", async (t) => {
  const { h, session, daemon, transcript, host } = await fixture(t);
  const { client } = await connectClient(h, session);
  t.after(() => client.close());

  const synced = await call(daemon, "axo.host.sync", { hostId: host.hostId, hostGeneration: host.hostGeneration, round: 2, sessions: [] }, hostSyncResultSchema);
  assert.deepEqual(synced.serverOnly, [transcript.sessionId]);
  const archived = await until(client, "axo.client.sessions");
  assert.equal((archived.sessions as Array<{ metadata: { archived: boolean } }>)[0]!.metadata.archived, true);

  const renamed = await call<{ applied: boolean }>(daemon, "axo.host.session.meta", { sessionId: transcript.sessionId, metadataVersion: 2, metadata: transcript.manifestRow(2, { name: "Renamed" }).metadata });
  assert.equal(renamed.applied, true);
  const older = await call<{ applied: boolean }>(daemon, "axo.host.session.meta", { sessionId: transcript.sessionId, metadataVersion: 1, metadata: transcript.manifestRow(1, { name: "Old name" }).metadata });
  assert.equal(older.applied, false);

  const opened = await call<{ records: ClientRecord[] }>(client, "axo.client.session.open", { hostId: host.hostId, sessionId: transcript.sessionId });
  assert.equal(opened.records.length, 3, "an archived Session stays readable");
});

test("a line too large for one SQLite value is stored in parts and read back whole", async (t) => {
  const { h, session, daemon, transcript, host } = await fixture(t, 1);
  await transcript.write(userMessage("x".repeat(1_200_000) + "✓"));
  assert.equal((await append(daemon, transcript, 2)).outcome, "committed");
  const { client } = await connectClient(h, session);
  t.after(() => client.close());
  const opened = await call<{ records: ClientRecord[] }>(client, "axo.client.session.open", { hostId: host.hostId, sessionId: transcript.sessionId });
  assert.equal(opened.records.at(-1)!.line, transcript.transcript.records[1]!.line);
});
