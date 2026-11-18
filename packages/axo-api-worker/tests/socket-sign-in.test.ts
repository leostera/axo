import assert from "node:assert/strict";
import { test } from "node:test";
import { harness, Peer, signIn } from "./harness";
import { connectHost, pairHost } from "./account-support";

/** As host-do.ts names a HostDO, and host-clients.ts a client socket on it (they import workerd's modules). */
const hostDOName = (accountId: string, hostId: string) => `${accountId}:${hostId}`;
const DIRECT_CLIENT_ROLE = "direct-client";

/** Who a socket is signed in as, and for how long (RFD0071). */

/** A lease short enough to see end: the account confirms each socket's sign-in this often. */
const LEASE_MS = 400;
const leased = () => harness({ bindings: { SIGN_IN_LEASE_MS: String(LEASE_MS) } });

/** The close code of a socket that closes within `ms`, or "open". */
async function within(peer: Peer, ms: number): Promise<number | "open"> {
  const closed = peer.closedWith();
  return Promise.race([closed.then((close) => close.code), new Promise<"open">((resolve) => setTimeout(() => resolve("open"), ms))]);
}

/** Hello on a host's socket (it numbers its connections), or on the account socket. */
const hello = (peer: Peer, clientId: string) => peer.call("axo.client.hello", { protocolVersion: 3, clientId, connection: 1 });
const accountHello = (peer: Peer, clientId: string) => peer.call("axo.client.hello", { protocolVersion: 3, clientId });

test("a person cannot take a Mac's client id", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const session = await signIn(h);
  const laptop = await pairHost(h, session, "Laptop");
  const daemon = await connectHost(h, session, laptop);
  t.after(() => daemon.close());
  const credential = { Authorization: `Bearer ${laptop.credential}`, "X-Axo-Credential-Id": laptop.credentialId };
  const peers = await Peer.connectHostPeers(h.url, session.accountId, laptop.hostId, credential);
  t.after(() => peers.close());
  const peersClosed = peers.closedWith();

  const taken = `host-${laptop.hostId}`;
  await assert.rejects(Peer.connectClient(h.url, taken, session.headers), "the account socket");
  await assert.rejects(Peer.connectHostClient(h.url, laptop.hostId, taken, session.headers), "a host's socket");
  const http = await fetch(new URL(`api/v1/account/client/http?clientId=${taken}`, h.url), { method: "POST", headers: session.headers, body: "{}" });
  assert.equal(http.status, 400, "the HTTP client");

  const still = await Promise.race([peersClosed, new Promise((resolve) => setTimeout(() => resolve("open"), 300))]);
  assert.equal(still, "open", "the Mac's own socket is not replaced");
});

test("a Mac's socket refused for its credential leaves its HostDO unbound", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const [accountId, hostId] = [crypto.randomUUID(), crypto.randomUUID()];
  const wrong = { Authorization: `Bearer ${"a".repeat(43)}`, "X-Axo-Credential-Id": crypto.randomUUID() };
  await assert.rejects(Peer.connectHostDaemon(h.url, accountId, hostId, wrong), "the Worker refuses it");

  // The HostDO itself, asked directly, refuses it too, and still binds to the first who is let in.
  const namespace = (await h.mf.getDurableObjectNamespace("TEST_HOST_DO")) as unknown as {
    idFromName(name: string): unknown; get(id: unknown): { fetch(url: string, init?: RequestInit): Promise<Response> };
  };
  const stub = namespace.get(namespace.idFromName(hostDOName(accountId, hostId)));
  const daemon = await stub.fetch("https://host.internal/daemon", { headers: {
    Upgrade: "websocket", "X-Axo-Role": "daemon", "X-Axo-Identity": accountId, "X-Axo-Machine": hostId,
    "X-Axo-Expiry": String(Date.now() + 60_000), "X-Axo-Credential": "a".repeat(43), "X-Axo-Credential-Id": wrong["X-Axo-Credential-Id"],
  } });
  assert.equal(daemon.status, 403);
  const other = await stub.fetch("https://host.internal/", { headers: {
    Upgrade: "websocket", "X-Axo-Role": DIRECT_CLIENT_ROLE, "X-Axo-Account": crypto.randomUUID(), "X-Axo-Machine": crypto.randomUUID(),
    "X-Axo-Client": "tab-unbound-test", "X-Axo-Person": "1", "X-Axo-Expiry": String(Date.now() + 60_000),
    "X-Axo-Sign-In": JSON.stringify({ kind: "session", digest: "unbound-test" }),
  } });
  assert.equal(other.status, 101, "nothing bound it to the refused account and host");
  (other as unknown as { webSocket?: { accept(): void; close(): void } }).webSocket?.accept();
  (other as unknown as { webSocket?: { close(): void } }).webSocket?.close();
});

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** Something a Mac asks: the HostDO's notice of it goes to every socket on it that said hello. */
const question = () => ({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: {
  id: crypto.randomUUID(), sessionId: crypto.randomUUID(), kind: "confirm", askedBy: "agent",
  message: "Synthetic question", createdAt: Date.now(), expiresAt: Date.now() + 60_000,
} });

/** The codes the sockets close with, or "open" if one is still open after `ms`. */
async function closes(peers: Peer[], ms: number): Promise<number[] | "open"> {
  const closed = Promise.all(peers.map((peer) => peer.closedWith())).then((all) => all.map((close) => close.code));
  return Promise.race([closed, sleep(ms).then(() => "open" as const)]);
}

test("once a session signs out, its sockets close at their next frame, in or out, and only its", async (t) => {
  const h = await leased();
  t.after(() => h.close());
  const subject = crypto.randomUUID();
  const session = await signIn(h, subject);
  // The same person, signed in on another device.
  const elsewhere = await signIn(h, subject);
  assert.equal(elsewhere.accountId, session.accountId);
  const host = await pairHost(h, session, "Studio");
  const daemon = await connectHost(h, session, host);
  t.after(() => daemon.close());

  const sockets = async (headers: Record<string, string>) => {
    const accountId = `tab-${crypto.randomUUID()}`;
    const account = await Peer.connectClient(h.url, accountId, headers);
    assert.ok("result" in await accountHello(account, accountId));
    const hostId = `tab-${crypto.randomUUID()}`;
    const onHost = await Peer.connectHostClient(h.url, host.hostId, hostId, headers);
    assert.ok("result" in await hello(onHost, hostId));
    return { account, onHost };
  };
  const leaving = await sockets(session.headers);
  const staying = await sockets(elsewhere.headers);
  t.after(() => { staying.account.close(); staying.onHost.close(); });

  // A sign-in that stands is confirmed again once its lease ends, and its sockets go on.
  await sleep(LEASE_MS * 2);
  const answered = await leaving.account.call("axo.client.refresh", {});
  assert.ok("result" in answered, JSON.stringify(answered));
  daemon.send(question());
  await sleep(LEASE_MS / 2);
  assert.equal(await within(leaving.onHost, 1), "open", "a notice after a renewed lease is delivered");

  const out = await fetch(new URL("api/auth/logout", h.url), { method: "POST", headers: session.headers });
  assert.equal(out.status, 204);
  await sleep(LEASE_MS * 2);
  leaving.account.send({ jsonrpc: "2.0", id: 1, method: "axo.client.refresh", params: {} });
  assert.deepEqual(await closes([leaving.account], LEASE_MS * 5), [4001], "a frame in closes the signed-out account socket");
  daemon.send(question());
  assert.deepEqual(await closes([leaving.onHost], LEASE_MS * 5), [4001], "a notice out closes the signed-out socket on the Mac");
  assert.equal(await within(staying.account, LEASE_MS), "open", "the other device's sockets stay");
  assert.ok("result" in await staying.account.call("axo.client.refresh", {}));
  assert.equal(await within(staying.onHost, 1), "open");
});

test("once a Mac is revoked, its sockets on its account and its other Macs, and sockets on it, close at their next frame", async (t) => {
  const h = await leased();
  t.after(() => h.close());
  const session = await signIn(h);
  const studio = await pairHost(h, session, "Studio");
  const laptop = await pairHost(h, session, "Laptop");
  const studioDaemon = await connectHost(h, session, studio);
  t.after(() => studioDaemon.close());
  const credential = { Authorization: `Bearer ${laptop.credential}`, "X-Axo-Credential-Id": laptop.credentialId };

  const peers = await Peer.connectHostPeers(h.url, session.accountId, laptop.hostId, credential);
  const peerId = `host-${laptop.hostId}`;
  assert.ok("result" in await accountHello(peers, peerId));
  const onStudio = await Peer.connectPeerHostClient(h.url, session.accountId, laptop.hostId, studio.hostId, credential);
  assert.ok("result" in await hello(onStudio, peerId));
  // A person looking at the laptop.
  const viewerId = `tab-${crypto.randomUUID()}`;
  const viewer = await Peer.connectHostClient(h.url, laptop.hostId, viewerId, session.headers);
  assert.ok("result" in await hello(viewer, viewerId));
  await sleep(LEASE_MS * 2);
  assert.ok("result" in await peers.call("axo.client.refresh", {}), "the Mac's sockets are renewed while it is linked");

  const revoked = await fetch(new URL(`api/v1/account/hosts/${laptop.hostId}/revoke`, h.url), { method: "POST", headers: session.headers });
  assert.equal(revoked.status, 204);
  await sleep(LEASE_MS * 2);
  peers.send({ jsonrpc: "2.0", id: 1, method: "axo.client.refresh", params: {} });
  assert.deepEqual(await closes([peers], LEASE_MS * 5), [4001], "its peers socket");
  studioDaemon.send(question());
  assert.deepEqual(await closes([onStudio], LEASE_MS * 5), [4001], "its socket on the Studio, at the Studio's next notice");
  viewer.send({ jsonrpc: "2.0", id: 1, method: "axo.client.session.close", params: { sessionId: crypto.randomUUID() } });
  assert.deepEqual(await closes([viewer], LEASE_MS * 5), [4001], "a person's socket on the revoked Mac");
});
