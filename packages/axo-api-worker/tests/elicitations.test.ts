import assert from "node:assert/strict";
import { test } from "node:test";
import { ELICITATION_ERRORS, type Elicitation } from "@axo/protocol";
import { Peer } from "../testing/client";
import { harness, signIn } from "./harness";
import { connectClient, connectHost, pairHost } from "./account-support";

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
