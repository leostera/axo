import assert from "node:assert/strict";
import { test } from "node:test";
import { harness, Peer, signIn } from "./harness";
import { connectHost, pairHost } from "./account-support";

/** As host-do.ts names a HostDO, and host-clients.ts a client socket on it (they import workerd's modules). */
const hostDOName = (accountId: string, hostId: string) => `${accountId}:${hostId}`;
const DIRECT_CLIENT_ROLE = "direct-client";

/** Who a socket is signed in as, and for how long. */

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
  } });
  assert.equal(other.status, 101, "nothing bound it to the refused account and host");
  (other as unknown as { webSocket?: { accept(): void; close(): void } }).webSocket?.accept();
  (other as unknown as { webSocket?: { close(): void } }).webSocket?.close();
});
