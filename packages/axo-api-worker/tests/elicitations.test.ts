import assert from "node:assert/strict";
import { test } from "node:test";
import { ELICITATION_ERRORS, type Elicitation } from "@axo/protocol";
import { Peer } from "../testing/client";
import { ElicitationReplay } from "../src/elicitation-replay";
import { deliverHostNoticeBatch } from "../src/host-notice-delivery";
import type { HostNotice } from "../src/host-do";
import { harness, signIn } from "./harness";
import { connectClient, connectHost, pairHost } from "./account-support";

test("requests and resolution bypass a stalled legacy follower without reordering ordinary notices", async () => {
  let release!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  const direct: HostNotice[][] = [];
  const targets = { direct: async (batch: HostNotice[]) => { direct.push(batch); },
    legacy: async () => { await gate; }, urgentFailure: () => assert.fail("no delivery error") };
  const requested: HostNotice = { kind: "elicitationRequested", elicitation: {
    id: "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f93", sessionId: "2a76c3e1-8b42-4f8d-9c15-1a2b3c4d5e6f",
    kind: "confirm", askedBy: "agent", message: "Fixture", createdAt: 1, expiresAt: 10_000 } };
  const ordinary: HostNotice = { kind: "presence", online: false, hostGeneration: null };
  const asking = deliverHostNoticeBatch([ordinary, requested], targets);
  assert.deepEqual(direct, [[requested]], "the legacy gate has not retired");
  const resolved: HostNotice = { kind: "elicitationResolved", resolved: {
    id: requested.elicitation.id, sessionId: requested.elicitation.sessionId, action: "accept" } };
  const answering = deliverHostNoticeBatch([resolved], targets);
  assert.deepEqual(direct, [[requested], [resolved]], "resolution is not stuck behind the older flush");
  release();
  await Promise.all([asking, answering]);
  assert.deepEqual(direct, [[requested], [resolved], [ordinary]]);
});

test("failure of urgent direct delivery never skips the legacy recipients", async () => {
  let failures = 0, legacy = 0;
  await deliverHostNoticeBatch([{ kind: "elicitationResolved", resolved: {
    id: "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f94", sessionId: "2a76c3e1-8b42-4f8d-9c15-1a2b3c4d5e6f", action: "cancel" } }], {
    direct: async () => { throw new Error("Closed direct socket"); },
    legacy: async () => { legacy++; },
    urgentFailure: () => { failures++; },
  });
  assert.equal(failures, 1);
  assert.equal(legacy, 1);
});

test("resolution wins both before and after a delayed subscription snapshot", () => {
  for (const resolveFirst of [true, false]) {
    const replay = new ElicitationReplay();
    const reading = replay.begin();
    const question: Elicitation = { id: "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f91", sessionId: "2a76c3e1-8b42-4f8d-9c15-1a2b3c4d5e6f", kind: "confirm", askedBy: "agent", message: "Fixture", createdAt: 1, expiresAt: 10_000 };
    if (resolveFirst) replay.resolve(question.id);
    reading.add("host", question);
    assert.deepEqual(replay.take(), [], "never send an incomplete snapshot");
    if (!resolveFirst) replay.resolve(question.id);
    reading.finish();
    assert.deepEqual(replay.take(), []);
  }
});

test("superseding or disconnecting a snapshot retires its catch-up authority", () => {
  const replay = new ElicitationReplay();
  const question: Elicitation = { id: "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f92", sessionId: "2a76c3e1-8b42-4f8d-9c15-1a2b3c4d5e6f", kind: "confirm", askedBy: "agent", message: "Fixture", createdAt: 1, expiresAt: 10_000 };
  const obsolete = replay.begin();
  const current = replay.begin();
  obsolete.add("old-host", question);
  obsolete.finish();
  assert.deepEqual(replay.take(), []);
  current.add("host", question);
  current.finish();
  assert.deepEqual(replay.take(), [{ hostId: "host", elicitation: question }]);
  assert.deepEqual(replay.take(), [], "a ready snapshot is consumed once");
  const disconnected = replay.begin();
  replay.clear();
  disconnected.add("host", question);
  disconnected.finish();
  assert.deepEqual(replay.take(), []);
});

/**
 * Elicitations through the cloud (RFD0029): what a Mac asks reaches every client its person has
 * open, including one that connects later; an answer goes from a person's client to the Mac and
 * nowhere else; and a Mac's own credential can neither see nor answer one.
 */

type Message = { id?: string | number; method?: string; params?: Record<string, unknown>; result?: unknown; error?: { code: number } };

async function until(peer: Peer, method: string): Promise<Record<string, unknown>> {
  for (;;) {
    const message = (await peer.next()) as Message;
    if (message.method === method) return message.params!;
  }
}

/** Whether `peer` gets a `method` notification within `ms`. */
async function hears(peer: Peer, method: string, ms = 400): Promise<boolean> {
  return Promise.race([until(peer, method).then(() => true), new Promise<boolean>((resolve) => setTimeout(() => resolve(false), ms))]);
}

async function fixture(t: { after(fn: () => unknown): void }) {
  const h = await harness();
  t.after(() => h.close());
  const session = await signIn(h);
  const host = await pairHost(h, session);
  const daemon = await connectHost(h, session, host);
  t.after(() => daemon.close());
  const elicitation: Elicitation = {
    id: crypto.randomUUID(), sessionId: crypto.randomUUID(), kind: "confirm", askedBy: "computerUse",
    message: "Delete the branch feat/old-ui?", createdAt: Date.now(), expiresAt: Date.now() + 300_000,
  };
  return { h, session, host, daemon, elicitation };
}

test("what a Mac asks reaches its person's clients, and their answer reaches the Mac", async (t) => {
  const { h, session, host, daemon, elicitation } = await fixture(t);
  const { client: phone } = await connectClient(h, session);
  t.after(() => phone.close());

  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: elicitation });
  assert.deepEqual(await until(phone, "axo.elicitation.requested"), { hostId: host.hostId, elicitation });

  // A client that connects later gets it right after its hello.
  const { client: browser } = await connectClient(h, session);
  t.after(() => browser.close());
  assert.deepEqual(await until(browser, "axo.elicitation.requested"), { hostId: host.hostId, elicitation });

  const answer = phone.call("axo.elicitation.resolve", { hostId: host.hostId, elicitationId: elicitation.id, action: "accept" });
  const forwarded = (await daemon.next()) as Message;
  assert.equal(forwarded.method, "axo.elicitation.resolve");
  assert.deepEqual(forwarded.params, {
    target: { hostId: host.hostId, hostGeneration: host.hostGeneration }, elicitationId: elicitation.id, action: "accept",
  });
  daemon.send({ jsonrpc: "2.0", id: forwarded.id, result: { resolved: true } });
  assert.deepEqual(((await answer) as Message).result, { resolved: true });

  // The Mac says it is settled, and every client dismisses the card.
  const resolved = { id: elicitation.id, sessionId: elicitation.sessionId, action: "accept" };
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.resolved", params: resolved });
  assert.deepEqual(await until(phone, "axo.elicitation.resolved"), { hostId: host.hostId, ...resolved });
  assert.deepEqual(await until(browser, "axo.elicitation.resolved"), { hostId: host.hostId, ...resolved });

  // Settled: a late answer never reaches the Mac.
  const late = (await browser.call("axo.elicitation.resolve", { hostId: host.hostId, elicitationId: elicitation.id, action: "decline" })) as Message;
  assert.equal(late.error?.code, ELICITATION_ERRORS.notPending);
});

test("all simultaneous person clients hear requests and resolution without opening the Session", async (t) => {
  const { h, session, host, daemon, elicitation } = await fixture(t);
  const { client: legacy } = await connectClient(h, session);
  t.after(() => legacy.close());
  const direct = async () => {
    const clientId = `tab-${crypto.randomUUID()}`;
    const client = await Peer.connectHostClient(h.url, host.hostId, clientId, session.headers);
    t.after(() => client.close());
    const hello = await client.call("axo.client.hello", { protocolVersion: 3, clientId, connection: 1 });
    assert.ok("result" in hello);
    return client;
  };
  const phone = await direct();
  const browser = await direct();
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: elicitation });
  for (const client of [legacy, phone, browser])
    assert.deepEqual(await until(client, "axo.elicitation.requested"), { hostId: host.hostId, elicitation });
  const later = await direct();
  assert.deepEqual(await until(later, "axo.elicitation.requested"), { hostId: host.hostId, elicitation });
  const answer = phone.call("axo.elicitation.resolve", { hostId: host.hostId, elicitationId: elicitation.id, action: "decline" });
  const forwarded = (await daemon.next()) as Message;
  assert.equal(forwarded.method, "axo.elicitation.resolve");
  daemon.send({ jsonrpc: "2.0", id: forwarded.id, result: { resolved: true } });
  assert.deepEqual(((await answer) as Message).result, { resolved: true });
  const resolved = { id: elicitation.id, sessionId: elicitation.sessionId, action: "decline" };
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.resolved", params: resolved });
  for (const client of [legacy, phone, browser, later])
    assert.deepEqual(await until(client, "axo.elicitation.resolved"), { hostId: host.hostId, ...resolved });
});

test("a Mac's own credential neither sees nor answers what another Mac asks", async (t) => {
  const { h, session, host, daemon, elicitation } = await fixture(t);
  const laptop = await pairHost(h, session, "MacBook Pro");
  const laptopDaemon = await connectHost(h, session, laptop);
  t.after(() => laptopDaemon.close());
  const peers = await Peer.connectHostPeers(h.url, session.accountId, laptop.hostId, {
    Authorization: `Bearer ${laptop.credential}`, "X-Axo-Credential-Id": laptop.credentialId,
  });
  t.after(() => peers.close());
  const hello = (await peers.call("axo.client.hello", { protocolVersion: 2, clientId: `host-${laptop.hostId}` })) as Message;
  assert.ok("result" in hello);

  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: elicitation });
  assert.equal(await hears(peers, "axo.elicitation.requested"), false);
  const refused = (await peers.call("axo.elicitation.resolve", { hostId: host.hostId, elicitationId: elicitation.id, action: "accept" })) as Message;
  assert.equal(refused.error?.code, ELICITATION_ERRORS.notAPerson);
  assert.equal(await hears(daemon, "axo.elicitation.resolve"), false, "nothing reaches the Mac");
});

test("a Mac going offline dismisses what it asked; nothing is answered for it", async (t) => {
  const { h, session, host, daemon, elicitation } = await fixture(t);
  const { client } = await connectClient(h, session);
  t.after(() => client.close());
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: elicitation });
  await until(client, "axo.elicitation.requested");

  daemon.close();
  assert.deepEqual(await until(client, "axo.elicitation.resolved"), {
    hostId: host.hostId, id: elicitation.id, sessionId: elicitation.sessionId, action: "cancel",
  });
  const offline = (await client.call("axo.elicitation.resolve", { hostId: host.hostId, elicitationId: elicitation.id, action: "accept" })) as Message;
  assert.equal(offline.error?.code, -32005);
});

test("what a Mac asks outlives its object being evicted while its socket hibernates", async (t) => {
  const { h, session, host, daemon, elicitation } = await fixture(t);
  const { client: phone } = await connectClient(h, session);
  t.after(() => phone.close());
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: elicitation });
  await until(phone, "axo.elicitation.requested");

  // Production evicts an idle object and keeps its hibernated sockets: the Mac stays connected,
  // so it never sends what it asks again.
  for (const id of await h.mf.listDurableObjectIds("TEST_HOST_DO"))
    await h.mf.unsafeEvictDurableObject("api-test", "AxoHostDO", { id, webSockets: "hibernate" });

  // A client that connects now still hears what waits for its person.
  const { client: browser } = await connectClient(h, session);
  t.after(() => browser.close());
  assert.deepEqual(await until(browser, "axo.elicitation.requested"), { hostId: host.hostId, elicitation });

  // And an answer still reaches the Mac, over the socket that hibernated.
  const answer = browser.call("axo.elicitation.resolve", { hostId: host.hostId, elicitationId: elicitation.id, action: "accept" });
  const forwarded = (await daemon.next()) as Message;
  assert.equal(forwarded.method, "axo.elicitation.resolve");
  daemon.send({ jsonrpc: "2.0", id: forwarded.id, result: { resolved: true } });
  assert.deepEqual(((await answer) as Message).result, { resolved: true });

  // Once settled, it is gone for good: a client connecting after eviction does not hear it again.
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.resolved", params: { id: elicitation.id, sessionId: elicitation.sessionId, action: "accept" } });
  await until(browser, "axo.elicitation.resolved");
  for (const id of await h.mf.listDurableObjectIds("TEST_HOST_DO"))
    await h.mf.unsafeEvictDurableObject("api-test", "AxoHostDO", { id, webSockets: "hibernate" });
  const { client: later } = await connectClient(h, session);
  t.after(() => later.close());
  assert.equal(await hears(later, "axo.elicitation.requested"), false);
});

test("a question past its expiry is not delivered, even if the Mac's resolved never came", async (t) => {
  const { h, session, daemon, elicitation } = await fixture(t);
  const soon = { ...elicitation, expiresAt: Date.now() + 300 };
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: soon });
  const { client: phone } = await connectClient(h, session);
  t.after(() => phone.close());
  await until(phone, "axo.elicitation.requested");

  await new Promise((done) => setTimeout(done, 400));
  const { client: later } = await connectClient(h, session);
  t.after(() => later.close());
  assert.equal(await hears(later, "axo.elicitation.requested"), false);
});
