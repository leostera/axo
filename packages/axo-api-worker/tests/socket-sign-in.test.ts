import assert from "node:assert/strict";
import { test } from "node:test";
import { harness, Peer, signIn } from "./harness";
import { connectHost, pairHost } from "./account-support";

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
