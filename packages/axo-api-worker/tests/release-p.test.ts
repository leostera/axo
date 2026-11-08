import assert from "node:assert/strict";
import { test } from "node:test";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { hostSyncResultSchema } from "@axo/protocol";
import { Peer } from "../testing/client";
import { harness, signIn, type AccountSession, type Harness } from "./harness";
import { objectRows } from "./storage";
import { FakeTranscript, connectHost, pairHost, userMessage, type PairedHost } from "./account-support";

/**
 * RFD0032, Release P: the release a rollback from protocol 3 goes back to. Its HostDO closes the
 * client sockets protocol 3 left on it, and its schema is applied once per object.
 */

const foreignEntry = resolve(fileURLToPath(new URL(".", import.meta.url)), "fixtures/foreign-sockets.ts");

type HostStub = { fetch(input: string, init?: RequestInit): Promise<Response & { webSocket: MiniflareSocket | null }> };
type MiniflareSocket = {
  accept(): void;
  send(data: string): void;
  addEventListener(type: "message", listener: (event: { data: unknown }) => void): void;
};

async function hostStub(h: Harness, session: AccountSession, host: PairedHost): Promise<HostStub> {
  const namespace = (await h.mf.getDurableObjectNamespace("TEST_HOST_DO")) as unknown as { idFromName(name: string): unknown; get(id: unknown): HostStub };
  return namespace.get(namespace.idFromName(`${session.accountId}:${host.hostId}`));
}

async function sync(daemon: Peer, host: PairedHost, transcript: FakeTranscript, round: number) {
  const reply = await daemon.call("axo.host.sync", { hostId: host.hostId, hostGeneration: host.hostGeneration, round, sessions: [transcript.manifestRow()] });
  assert.ok("result" in reply, JSON.stringify(reply));
  return hostSyncResultSchema.parse(reply.result);
}

/** Accepts a socket on the HostDO with `attachment`, as another release would have. */
async function foreignSocket(stub: HostStub, attachment: unknown) {
  const response = await stub.fetch("https://host.internal/", { headers: { Upgrade: "websocket", "X-Test-Foreign": JSON.stringify(attachment) } });
  assert.equal(response.status, 101);
  const socket = response.webSocket!;
  socket.accept();
  const messages: unknown[] = [];
  socket.addEventListener("message", (event) => messages.push(event.data));
  return { socket, messages };
}

test("a HostDO ignores the client sockets another release left on it, and closes them when it wakes", async (t) => {
  const h = await harness({ entry: foreignEntry });
  t.after(() => h.close());
  const session = await signIn(h);
  const host = await pairHost(h, session);
  const daemon = await connectHost(h, session, host);
  t.after(() => daemon.close());
  const transcript = await FakeTranscript.create();
  await transcript.write(userMessage("one"));
  await sync(daemon, host, transcript, 1);

  const stub = await hostStub(h, session, host);
  const now = Date.now();
  // What protocol 3 might leave: a client in today's peer shape, and one in a shape this release
  // has never seen.
  const clientPeer = { role: "client", identity: session.accountId, expiresAt: now + 3_600_000, connectionId: crypto.randomUUID(), machineId: host.hostId, negotiated: true, window: now, calls: 0, hostSubscriptions: [] };
  await foreignSocket(stub, clientPeer);
  const unknown = await foreignSocket(stub, { protocol: 3, clientId: "tab-0123456789", connection: 7 });

  // Until it wakes, they change nothing for the Mac: its calls and presence go on.
  unknown.socket.send(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "axo.client.hello", params: { protocolVersion: 3, clientId: "tab-0123456789", connection: 7 } }));
  assert.equal((await sync(daemon, host, transcript, 2)).sessions.length, 1);
  assert.deepEqual(unknown.messages, [], "a frame on a socket this release doesn't serve is not answered");

  // Waking closes both; the Mac's socket stays, and is still served.
  const woken = (await (await stub.fetch("https://host.internal/", { headers: { "X-Test-Wake": "1" } })).json()) as Array<{ state: number; attachment: { role?: string } }>;
  const states = (role: string | undefined) => woken.filter((socket) => socket.attachment.role === role).map((socket) => socket.state);
  const CLOSING = 2;
  const OPEN = 1;
  assert.deepEqual(states("client"), [CLOSING]);
  assert.deepEqual(states(undefined), [CLOSING]);
  assert.deepEqual(states("daemon"), [OPEN]);
  assert.equal((await sync(daemon, host, transcript, 3)).sessions.length, 1);
});

const version = (h: Harness, className: string) =>
  objectRows<{ version: number }>(h, className, "SELECT version FROM schema_version").map((row) => row.version);
const hasTable = (h: Harness, className: string, table: string) =>
  objectRows<{ name: string }>(h, className, `SELECT name FROM sqlite_master WHERE type = 'table' AND name = '${table}'`).length > 0;

test("a HostDO and a SessionDO apply their schema once, and a newer release's version applies nothing", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const session = await signIn(h);
  const host = await pairHost(h, session);
  let daemon = await connectHost(h, session, host);
  const transcript = await FakeTranscript.create();
  await transcript.write(userMessage("one"));
  await sync(daemon, host, transcript, 1);
  const appended = await daemon.call("axo.host.session.append", { sessionId: transcript.sessionId, epoch: 1, from: 1, header: transcript.transcript.header, records: transcript.records(1) });
  assert.ok("result" in appended, JSON.stringify(appended));
  daemon.close();
  assert.deepEqual(version(h, "AxoHostDO"), [3]);
  assert.deepEqual(version(h, "AxoSessionDO"), [3]);
  assert.ok(hasTable(h, "AxoHostDO", "client_opens"));

  // An object from before the version existed has the tables but no version: it runs every
  // step once, and they change nothing it holds.
  await h.restart(() => {
    objectRows(h, "AxoHostDO", "DROP TABLE schema_version; DROP TABLE client_opens", true);
    objectRows(h, "AxoSessionDO", "DROP TABLE schema_version", true);
  });
  daemon = await connectHost(h, session, host);
  assert.deepEqual((await sync(daemon, host, transcript, 2)).sessions.map((row) => [row.state, "count" in row && row.count]), [["known", 1]]);
  // The index answered that from the HostDO; an append wakes the SessionDO.
  await transcript.write(userMessage("two"));
  const second = await daemon.call("axo.host.session.append", { sessionId: transcript.sessionId, epoch: 1, from: 2, records: transcript.records(2) });
  assert.ok("result" in second && (second.result as { outcome: string }).outcome === "committed", JSON.stringify(second));
  daemon.close();
  assert.deepEqual(version(h, "AxoHostDO"), [3]);
  assert.deepEqual(version(h, "AxoSessionDO"), [3]);
  assert.ok(hasTable(h, "AxoHostDO", "client_opens"));

  // A version past this release's steps was written by a newer release: nothing runs, so a table
  // this release would have created stays absent, and the object still serves its Mac.
  await h.restart(() => {
    objectRows(h, "AxoHostDO", "UPDATE schema_version SET version = 99; DROP TABLE client_opens", true);
  });
  daemon = await connectHost(h, session, host);
  t.after(() => daemon.close());
  assert.deepEqual((await sync(daemon, host, transcript, 3)).sessions.map((row) => [row.state, "count" in row && row.count]), [["known", 2]]);
  assert.deepEqual(version(h, "AxoHostDO"), [99]);
  assert.equal(hasTable(h, "AxoHostDO", "client_opens"), false);
});
