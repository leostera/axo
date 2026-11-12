import assert from "node:assert/strict";
import { test } from "node:test";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";
import { RemoteAxoApi, type AccountConnection, type AccountEvents, type WebSocketLike } from "@axo/app";
import { appendResultSchema, hostSyncResultSchema, type ClientRecord } from "@axo/protocol";
import { Peer } from "../testing/client";
import { harness, signIn, type AccountSession, type Harness } from "./harness";
import { objectRows } from "./storage";
import { FakeTranscript, connectClient, connectHost, pairHost, userMessage, type PairedHost } from "./account-support";

/**
 * RFD0032, protocol 3: a client holds a socket on each Mac's HostDO, which sends it what it
 * commits from the append in hand, and reads the SessionDO only for what it no longer holds.
 */

const countingEntry = resolve(fileURLToPath(new URL(".", import.meta.url)), "fixtures/counting-reads.ts");

/** SessionDO reads so far, across every Session (the fixture counts them). */
const reads = (h: Harness) => objectRows<{ reads: number }>(h, "AxoSessionDO", "SELECT reads FROM test_reads").reduce((sum, row) => sum + row.reads, 0);

type Fixture = { h: Harness; session: AccountSession; host: PairedHost; daemon: Peer; transcript: FakeTranscript };

async function fixture(t: { after(fn: () => unknown): void }, lines = 2): Promise<Fixture> {
  const h = await harness({ entry: countingEntry });
  t.after(() => h.close());
  const session = await signIn(h);
  const host = await pairHost(h, session);
  const daemon = await connectHost(h, session, host);
  t.after(() => daemon.close());
  const transcript = await FakeTranscript.create();
  for (let index = 0; index < lines; index++) await transcript.write(userMessage(`line ${index + 1}`));
  const synced = await daemon.call("axo.host.sync", { hostId: host.hostId, hostGeneration: host.hostGeneration, round: 1, sessions: [transcript.manifestRow()] });
  assert.ok("result" in synced, JSON.stringify(synced));
  hostSyncResultSchema.parse(synced.result);
  if (lines > 0) await append(daemon, transcript, 1, 1, true);
  return { h, session, host, daemon, transcript };
}

async function append(daemon: Peer, transcript: FakeTranscript, from: number, epoch = 1, header = false) {
  const reply = await daemon.call("axo.host.session.append", {
    sessionId: transcript.sessionId, epoch, from, ...(header ? { header: transcript.transcript.header } : {}), records: transcript.records(from),
  });
  assert.ok("result" in reply, JSON.stringify(reply));
  const result = appendResultSchema.parse(reply.result);
  assert.equal(result.outcome, "committed", JSON.stringify(result));
  return result;
}

/** What a tab heard, with a way to wait for the next of each kind. */
class Heard {
  records: Array<{ sessionId: string; epoch: number; cursors: number[] }> = [];
  progress: Array<{ sessionId: string; slot: string; snapshot: unknown }> = [];
  resets: Array<{ sessionId: string; epoch: number; keep: number }> = [];
  hosts: Array<Array<{ hostId: string; online: boolean; label: string }>> = [];
  closed: Error[] = [];
  private waiters: Array<() => void> = [];

  readonly events: AccountEvents = {
    records: (sessionId, epoch, records: ClientRecord[]) => this.push(() => this.records.push({ sessionId, epoch, cursors: records.map((record) => record.cursor) })),
    progress: (sessionId, slot, snapshot) => this.push(() => this.progress.push({ sessionId, slot, snapshot })),
    reset: (sessionId, epoch, keep) => this.push(() => this.resets.push({ sessionId, epoch, keep })),
    hosts: (hosts) => this.push(() => this.hosts.push(hosts.map(({ hostId, online, label }) => ({ hostId, online, label })))),
    closed: (error) => this.push(() => this.closed.push(error)),
  };

  private push(record: () => void): void {
    record();
    for (const waiter of this.waiters.splice(0)) waiter();
  }

  /** Waits until `done` holds, re-checking after each event. */
  async until(done: () => boolean, what: string, ms = 5_000): Promise<void> {
    const deadline = Date.now() + ms;
    while (!done()) {
      const left = deadline - Date.now();
      if (left <= 0) throw new Error(`Timed out waiting for ${what}`);
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, Math.min(left, 200));
        this.waiters.push(() => {
          clearTimeout(timer);
          resolve();
        });
      });
    }
  }
}

function api(h: Harness, session: AccountSession, protocol: 2 | 3) {
  return new RemoteAxoApi(h.url, (url) => new WebSocket(url, { headers: session.headers }) as unknown as WebSocketLike, { protocol });
}

async function tab(t: { after(fn: () => unknown): void }, h: Harness, session: AccountSession, protocol: 2 | 3 = 3) {
  const heard = new Heard();
  const connection = await api(h, session, protocol).connect(`tab-${crypto.randomUUID()}`, heard.events);
  t.after(() => connection.close());
  return { connection, heard };
}

test("a protocol 3 tab opens at the head with no read, and gets each committed record from the append", async (t) => {
  const { h, session, host, daemon, transcript } = await fixture(t);
  const before = reads(h);
  const { connection, heard } = await tab(t, h, session);
  assert.deepEqual(connection.hello.hosts.map(({ hostId, online }) => ({ hostId, online })), [{ hostId: host.hostId, online: true }]);
  const listed = connection.hello.sessions.find((row) => row.sessionId === transcript.sessionId);
  assert.deepEqual(listed && { epoch: listed.epoch, head: listed.head }, { epoch: 1, head: 2 });

  const opened = await connection.open({ hostId: host.hostId, sessionId: transcript.sessionId, have: { epoch: 1, cursor: 2 } });
  assert.deepEqual({ epoch: opened.epoch, cursor: opened.cursor, records: opened.records.length }, { epoch: 1, cursor: 2, records: 0 });
  assert.equal(reads(h), before, "an open at the head reads nothing (openAtHead)");

  await transcript.write(userMessage("three"));
  await append(daemon, transcript, 3);
  await heard.until(() => heard.records.length > 0, "the committed record");
  assert.deepEqual(heard.records, [{ sessionId: transcript.sessionId, epoch: 1, cursors: [3] }]);
  // The tab acknowledged it; the next commit goes straight out too.
  await transcript.write(userMessage("four"), userMessage("five"));
  await append(daemon, transcript, 4);
  await heard.until(() => heard.records.length > 1, "the next batch");
  assert.deepEqual(heard.records[1], { sessionId: transcript.sessionId, epoch: 1, cursors: [4, 5] });
  assert.equal(reads(h), before, "every record came from the append in hand (pushFromAppend)");

  // Progress goes to the socket with the Session open.
  daemon.send({ jsonrpc: "2.0", method: "axo.host.session.progress", params: { sessionId: transcript.sessionId, slot: "message", snapshot: { message: "typing" }, at: Math.floor(Date.now() / 1000) } });
  await heard.until(() => heard.progress.length > 0, "progress");
  assert.deepEqual(heard.progress[0], { sessionId: transcript.sessionId, slot: "message", snapshot: { message: "typing" } });
});

test("a tab that opens behind reads what it misses once, then follows from the append", async (t) => {
  const { h, session, host, daemon, transcript } = await fixture(t, 3);
  const before = reads(h);
  const { connection, heard } = await tab(t, h, session);
  const opened = await connection.open({ hostId: host.hostId, sessionId: transcript.sessionId, have: { epoch: 1, cursor: 1 } });
  assert.deepEqual(opened.records.map((record) => record.cursor), [2, 3]);
  assert.equal(reads(h), before + 1);
  await transcript.write(userMessage("four"));
  await append(daemon, transcript, 4);
  await heard.until(() => heard.records.length > 0, "the committed record");
  assert.deepEqual(heard.records[0]!.cursors, [4]);
  assert.equal(reads(h), before + 1);
});

test("a cut reaches a protocol 3 tab as a reset with no read, and records of the new epoch follow", async (t) => {
  const { h, session, host, daemon, transcript } = await fixture(t, 3);
  const { connection, heard } = await tab(t, h, session);
  await connection.open({ hostId: host.hostId, sessionId: transcript.sessionId, have: { epoch: 1, cursor: 3 } });
  const before = reads(h);
  const truncated = await daemon.call("axo.host.session.truncate", { sessionId: transcript.sessionId, round: 1, keep: 1, expectedChain: transcript.transcript.chainAt(1) });
  assert.ok("result" in truncated, JSON.stringify(truncated));
  await heard.until(() => heard.resets.length > 0, "the reset");
  assert.deepEqual(heard.resets[0], { sessionId: transcript.sessionId, epoch: 2, keep: 1 });

  // The Mac writes past the cut again, in epoch 2.
  await append(daemon, transcript, 2, 2);
  await heard.until(() => heard.records.some((batch) => batch.epoch === 2), "a record of epoch 2");
  assert.deepEqual(heard.records.find((batch) => batch.epoch === 2)!.cursors, [2, 3]);
  assert.equal(reads(h), before, "the HostDO made the cut, so it told the tab where with no read");
});

test("protocol 2 and protocol 3 tabs both get the record, and protocol 2's frames keep their shape", async (t) => {
  const { h, session, host, daemon, transcript } = await fixture(t);
  const three = await tab(t, h, session, 3);
  await three.connection.open({ hostId: host.hostId, sessionId: transcript.sessionId, have: { epoch: 1, cursor: 2 } });
  const { client: two, hello } = await connectClient(h, session);
  t.after(() => two.close());
  assert.deepEqual(Object.keys(hello).sort(), ["hosts", "sessions"]);
  assert.equal(hello.sessions.length, 1, "protocol 2's hello still carries the index");
  const opened = await two.call("axo.client.session.open", { hostId: host.hostId, sessionId: transcript.sessionId, have: { epoch: 1, cursor: 2 } });
  assert.ok("result" in opened, JSON.stringify(opened));
  assert.deepEqual(Object.keys(opened.result as object).sort(), ["cursor", "epoch", "older", "progress", "records"]);

  await transcript.write(userMessage("three"));
  await append(daemon, transcript, 3);
  await three.heard.until(() => three.heard.records.length > 0, "the record on protocol 3");
  for (;;) {
    const frame = (await two.next()) as { method?: string; params?: Record<string, unknown> };
    if (frame.method !== "axo.client.session.records") continue;
    assert.deepEqual(Object.keys(frame).sort(), ["jsonrpc", "method", "params"]);
    assert.deepEqual(Object.keys(frame.params!).sort(), ["cursor", "epoch", "records", "sessionId"]);
    assert.deepEqual(Object.keys((frame.params!.records as object[])[0]!).sort(), ["cursor", "format", "hash", "id", "line"]);
    break;
  }
});

test("commands go over the host socket, and a host's newest connection from a client wins", async (t) => {
  const { h, session, host, daemon } = await fixture(t, 0);
  const { connection } = await tab(t, h, session);
  const target = { hostId: host.hostId, hostGeneration: host.hostGeneration };
  const stopping = connection.command("axo.remote.session.stop", { target, sessionId: crypto.randomUUID(), turnId: "a1b2c3d4" });
  const forwarded = (await daemon.next()) as { id: string; method: string };
  assert.equal(forwarded.method, "axo.remote.session.stop");
  daemon.send({ jsonrpc: "2.0", id: forwarded.id, result: { stopped: true } });
  assert.deepEqual(await stopping, { stopped: true });

  const clientId = `tab-${crypto.randomUUID()}`;
  const hello = (socket: Peer, number: number) => socket.call("axo.client.hello", { protocolVersion: 3, clientId, connection: number });
  const first = await Peer.connectHostClient(h.url, host.hostId, clientId, session.headers);
  t.after(() => first.close());
  assert.ok("result" in (await hello(first, 5)));
  const late = await Peer.connectHostClient(h.url, host.hostId, clientId, session.headers);
  t.after(() => late.close());
  const lateClosed = late.closedWith();
  void hello(late, 3).catch(() => undefined);
  assert.deepEqual(await lateClosed, { code: 4000, reason: "Replaced" }, "an older connection's hello that comes late is refused");
  const newer = await Peer.connectHostClient(h.url, host.hostId, clientId, session.headers);
  t.after(() => newer.close());
  const firstClosed = first.closedWith();
  assert.ok("result" in (await hello(newer, 7)));
  assert.deepEqual(await firstClosed, { code: 4000, reason: "Replaced" }, "a newer connection replaces the older socket");
});

test("a host socket is only for a host the signed-in account owns", async (t) => {
  const { h, session } = await fixture(t, 0);
  const stranger = await signIn(h);
  const theirs = await pairHost(h, stranger, "Their Mac");
  const socket = new WebSocket(`${h.url.replace(/^http/, "ws")}api/v1/account/hosts/${theirs.hostId}/client?clientId=tab-0123456789`, { headers: session.headers });
  socket.on("error", () => undefined);
  const status = await new Promise<number>((done) => {
    socket.once("unexpected-response", (_request, response) => done(response.statusCode ?? 0));
    socket.once("open", () => done(101));
  });
  socket.terminate();
  assert.equal(status, 404);
});

test("after a reset the tab connects again and catches up from what it holds", async (t) => {
  const { h, session, host, transcript } = await fixture(t, 3);
  const first = await tab(t, h, session);
  await first.connection.open({ hostId: host.hostId, sessionId: transcript.sessionId, have: { epoch: 1, cursor: 3 } });
  await h.restart();
  await first.heard.until(() => first.heard.closed.length > 0, "the close");
  const daemon = await connectHost(h, session, host);
  t.after(() => daemon.close());
  await transcript.write(userMessage("four"));
  const synced = await daemon.call("axo.host.sync", { hostId: host.hostId, hostGeneration: host.hostGeneration, round: 2, sessions: [transcript.manifestRow()] });
  assert.ok("result" in synced);
  await append(daemon, transcript, 4);
  const before = reads(h);
  const second = await tab(t, h, session);
  const opened = await second.connection.open({ hostId: host.hostId, sessionId: transcript.sessionId, have: { epoch: 1, cursor: 3 } });
  assert.deepEqual(opened.records.map((record) => record.cursor), [4]);
  assert.equal(reads(h), before + 1, "what memory lost is read once");
});

/** The next notification `method` on `peer`, skipping others. */
async function until(peer: Peer, method: string): Promise<Record<string, unknown>> {
  for (;;) {
    const message = (await peer.next()) as { method?: string; params?: Record<string, unknown> };
    if (message.method === method) return message.params!;
  }
}

async function hostSocket(h: Harness, session: AccountSession, host: PairedHost, t: { after(fn: () => unknown): void }) {
  const clientId = `tab-${crypto.randomUUID()}`;
  const socket = await Peer.connectHostClient(h.url, host.hostId, clientId, session.headers);
  t.after(() => socket.close());
  const hello = await socket.call("axo.client.hello", { protocolVersion: 3, clientId, connection: 1 });
  assert.ok("result" in hello, JSON.stringify(hello));
  return { socket, hello: hello.result as { online: boolean; hostGeneration: string | null; sessions: unknown[] } };
}

test("what a Mac asks reaches a host socket, after its hello too, and the answer reaches the Mac", async (t) => {
  const { h, session, host, daemon } = await fixture(t, 0);
  const elicitation = {
    id: crypto.randomUUID(), sessionId: crypto.randomUUID(), kind: "confirm", askedBy: "computerUse",
    message: "Delete the branch feat/old-ui?", createdAt: Date.now(), expiresAt: Date.now() + 300_000,
  };
  const { socket: first } = await hostSocket(h, session, host, t);
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: elicitation });
  assert.deepEqual(await until(first, "axo.elicitation.requested"), { hostId: host.hostId, elicitation });
  const { socket: later } = await hostSocket(h, session, host, t);
  assert.deepEqual(await until(later, "axo.elicitation.requested"), { hostId: host.hostId, elicitation }, "a socket that says hello later is told at once");

  const answer = later.call("axo.elicitation.resolve", { hostId: host.hostId, elicitationId: elicitation.id, action: "accept" });
  const forwarded = (await daemon.next()) as { id: string; method: string; params: unknown };
  assert.equal(forwarded.method, "axo.elicitation.resolve");
  assert.deepEqual(forwarded.params, { target: { hostId: host.hostId, hostGeneration: host.hostGeneration }, elicitationId: elicitation.id, action: "accept" });
  daemon.send({ jsonrpc: "2.0", id: forwarded.id, result: { resolved: true } });
  const answered = await answer;
  assert.ok("result" in answered && (answered.result as { resolved: boolean }).resolved, JSON.stringify(answered));

  const resolved = { id: elicitation.id, sessionId: elicitation.sessionId, action: "accept" };
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.resolved", params: resolved });
  assert.deepEqual(await until(first, "axo.elicitation.resolved"), { hostId: host.hostId, ...resolved });
});

test("a protocol 3 tab hears its Mac go offline from the Mac's host socket", async (t) => {
  const { h, session, host, daemon } = await fixture(t, 0);
  const { connection, heard } = await tab(t, h, session);
  assert.equal(connection.hello.hosts[0]!.online, true);
  daemon.close();
  await heard.until(() => heard.hosts.some((hosts) => hosts[0]?.online === false), "the Mac going offline");
});

test("the account socket in protocol 3 lists hosts and no Sessions, and refuses what the host sockets carry", async (t) => {
  const { h, session, host } = await fixture(t);
  const clientId = `tab-${crypto.randomUUID()}`;
  const account = await Peer.connectClient(h.url, clientId, session.headers);
  t.after(() => account.close());
  const hello = await account.call("axo.client.hello", { protocolVersion: 3, clientId });
  assert.ok("result" in hello, JSON.stringify(hello));
  const result = hello.result as { hosts: Array<{ hostId: string; online: boolean }>; sessions: unknown[] };
  assert.deepEqual(result.hosts.map(({ hostId, online }) => ({ hostId, online })), [{ hostId: host.hostId, online: false }]);
  assert.deepEqual(result.sessions, []);
  const open = await account.call("axo.client.session.open", { hostId: host.hostId, sessionId: crypto.randomUUID() });
  assert.ok("error" in open && open.error.code === -32601, JSON.stringify(open));
});

test("a Mac follows another Mac's HostDO with its host credential: the index and pushed records, but not what the Mac asks", async (t) => {
  const { h, session, host, daemon, transcript } = await fixture(t);
  const follower = await pairHost(h, session, "Studio");
  const credential = { Authorization: `Bearer ${follower.credential}`, "X-Axo-Credential-Id": follower.credentialId };
  const peer = await Peer.connectPeerHostClient(h.url, session.accountId, follower.hostId, host.hostId, credential);
  t.after(() => peer.close());
  const clientId = `host-${follower.hostId}`;
  const hello = await peer.call("axo.client.hello", { protocolVersion: 3, clientId, connection: 1 });
  assert.ok("result" in hello, JSON.stringify(hello));
  assert.deepEqual((hello.result as { sessions: Array<{ sessionId: string }> }).sessions.map((row) => row.sessionId), [transcript.sessionId]);
  const before = reads(h);
  const opened = await peer.call("axo.client.session.open", { hostId: host.hostId, sessionId: transcript.sessionId, have: { epoch: 1, cursor: 2 } });
  assert.ok("result" in opened && (opened.result as { cursor: number }).cursor === 2, JSON.stringify(opened));

  const elicitation = { id: crypto.randomUUID(), sessionId: transcript.sessionId, kind: "confirm", askedBy: "computerUse", message: "Go?", createdAt: Date.now(), expiresAt: Date.now() + 300_000 };
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: elicitation });
  await transcript.write(userMessage("three"));
  await append(daemon, transcript, 3);
  for (;;) {
    const message = (await peer.next()) as { method?: string; params?: { cursor?: number } };
    assert.notEqual(message.method, "axo.elicitation.requested", "a Mac following its peers never sees what a Mac asks");
    if (message.method === "axo.client.session.records") {
      assert.equal(message.params!.cursor, 3);
      break;
    }
  }
  assert.equal(reads(h), before, "a Mac that already holds the head costs no read, to open or to follow");
  const refused = await peer.call("axo.elicitation.resolve", { hostId: host.hostId, elicitationId: elicitation.id, action: "accept" });
  assert.ok("error" in refused && refused.error.code === -32012, JSON.stringify(refused));

  const wrong = new WebSocket(`${h.url.replace(/^http/, "ws")}api/v1/accounts/${session.accountId}/hosts/${follower.hostId}/peers/${host.hostId}/client`, {
    headers: { Authorization: `Bearer ${"x".repeat(43)}`, "X-Axo-Credential-Id": follower.credentialId },
  });
  wrong.on("error", () => undefined);
  const status = await new Promise<number>((done) => {
    wrong.once("unexpected-response", (_request, response) => done(response.statusCode ?? 0));
    wrong.once("open", () => done(101));
  });
  wrong.terminate();
  assert.equal(status, 401);
});

test("a command waiting on the Mac's socket is not failed when another connection is fenced", async (t) => {
  const entry = resolve(fileURLToPath(new URL(".", import.meta.url)), "fixtures/fence-hook.ts");
  const h = await harness({ entry });
  t.after(() => h.close());
  const session = await signIn(h);
  const host = await pairHost(h, session);
  const daemon = await connectHost(h, session, host);
  t.after(() => daemon.close());
  const { socket } = await hostSocket(h, session, host, t);
  const target = { hostId: host.hostId, hostGeneration: host.hostGeneration };
  const answer = socket.call("axo.client.command", { hostId: host.hostId, method: "axo.remote.session.create", params: { target } });
  const forwarded = (await daemon.next()) as { id: string; method: string };
  assert.equal(forwarded.method, "axo.remote.session.create");

  // An old socket of this Mac closes late: its connection is fenced, not the one the command went on.
  const namespace = (await h.mf.getDurableObjectNamespace("TEST_HOST_DO")) as unknown as { idFromName(name: string): unknown; get(id: unknown): { fetch(url: string, init?: RequestInit): Promise<Response> } };
  const stub = namespace.get(namespace.idFromName(`${session.accountId}:${host.hostId}`));
  assert.equal((await stub.fetch("https://host.internal/", { headers: { "X-Test-Fence": crypto.randomUUID() } })).status, 204);

  const created = { session: { hostId: host.hostId, sessionId: crypto.randomUUID(), shells: [], layout: null, updatedAt: new Date().toISOString() } };
  daemon.send({ jsonrpc: "2.0", id: forwarded.id, result: created });
  const reply = await answer;
  assert.ok("result" in reply, `the Mac's answer reaches the client: ${JSON.stringify(reply)}`);
});

test("a Session's status and progress outlive the HostDO being evicted while the Mac's socket hibernates", async (t) => {
  const { h, session, host, daemon, transcript } = await fixture(t);
  const at = Math.floor(Date.now() / 1000);
  daemon.send({ jsonrpc: "2.0", method: "axo.host.session.status", params: { sessionId: transcript.sessionId, status: "working", at } });
  daemon.send({ jsonrpc: "2.0", method: "axo.host.session.progress", params: { sessionId: transcript.sessionId, slot: "tool", snapshot: { running: "swift build" }, at } });
  // A tab that is open hears both: the HostDO has them.
  const { connection: first, heard } = await tab(t, h, session);
  await first.open({ hostId: host.hostId, sessionId: transcript.sessionId, have: { epoch: 1, cursor: 2 } });
  await heard.until(() => heard.progress.length > 0, "the progress");

  // A long quiet tool call: nothing comes from the Mac, the object is evicted, its socket kept.
  await new Promise((done) => setTimeout(done, 1_500));
  for (const id of await h.mf.listDurableObjectIds("TEST_HOST_DO"))
    await h.mf.unsafeEvictDurableObject("api-test", "AxoHostDO", { id, webSockets: "hibernate" });

  const { connection } = await tab(t, h, session);
  const listed = connection.hello.sessions.find((row) => row.sessionId === transcript.sessionId);
  assert.equal(listed?.status, "working", "the status the Mac last reported");
  const opened = await connection.open({ hostId: host.hostId, sessionId: transcript.sessionId, have: { epoch: 1, cursor: 2 } });
  assert.deepEqual(opened.progress, [{ slot: "tool", snapshot: { running: "swift build" } }], "what the Mac is doing");
});
