import assert from "node:assert/strict";
import { test } from "node:test";
import { CLIENT_REASSEMBLY, FRAGMENT_METHOD, FRAGMENTS } from "@axo/protocol";
import { Peer } from "../testing/client";
import { harness, signIn } from "./harness";
import { connectHost, pairHost } from "./account-support";

/**
 * A client's socket reassembles no message larger than it takes (CLIENT_REASSEMBLY): the first
 * fragment of one says how large it is, and the socket closes then, before the object holds any of it.
 */

/** The first fragment of a message as large as a Mac's socket takes (16 MiB). */
const firstOfLargest = JSON.stringify({
  jsonrpc: "2.0",
  method: FRAGMENT_METHOD,
  params: {
    messageId: "big",
    index: 0,
    count: Math.ceil(FRAGMENTS.messageBytes / FRAGMENTS.chunkBytes),
    data: Buffer.alloc(FRAGMENTS.chunkBytes, 97).toString("base64"),
  },
});

test("a client socket closes at the first fragment of a message larger than a client sends", async (t) => {
  assert.ok(FRAGMENTS.messageBytes > CLIENT_REASSEMBLY.messageBytes);
  const h = await harness();
  t.after(() => h.close());
  const session = await signIn(h);
  const host = await pairHost(h, session);
  const daemon = await connectHost(h, session, host);
  t.after(() => daemon.close());

  const account = await Peer.connectClient(h.url, `tab-${crypto.randomUUID()}`, session.headers);
  const accountClosed = account.closedWith();
  account.send(firstOfLargest);
  assert.equal((await accountClosed).code, 1008, "the account socket");

  const clientId = `tab-${crypto.randomUUID()}`;
  const onHost = await Peer.connectHostClient(h.url, host.hostId, clientId, session.headers);
  const hello = await onHost.call("axo.client.hello", { protocolVersion: 3, clientId, connection: 1 });
  assert.ok("result" in hello, JSON.stringify(hello));
  const hostClosed = onHost.closedWith();
  onHost.send(firstOfLargest);
  assert.equal((await hostClosed).code, 1008, "the socket on the Mac's HostDO");
});
