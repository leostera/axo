import test from "node:test";
import assert from "node:assert/strict";
import { splitMessage } from "@axo/protocol";
import { harness, Peer } from "./harness";

// RFD0016, Transport: a daemon may send a message larger than a frame as fragments; the relay
// reassembles it before parsing, and closes the socket on a fragment that breaks the rules.

test("a fragmented call from a daemon is reassembled and answered", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const daemon = await Peer.connectHost(h.url, await h.token("daemon"), crypto.randomUUID(), "daemon");
  await daemon.negotiate();

  // A heartbeat with a large field: the relay must parse it whole to refuse it as invalid params.
  const raw = JSON.stringify({ jsonrpc: "2.0", id: "big-1", method: "axo.host.heartbeat", params: { padding: "x".repeat(200_000) } });
  const frames = splitMessage(raw, "big-1")!;
  assert.ok(frames.length > 1);
  for (const frame of frames) daemon.send(frame);
  const reply = (await daemon.next()) as { id: string; error?: { code: number } };
  assert.equal(reply.id, "big-1");
  assert.equal(reply.error?.code, -32602);

  // The socket still serves ordinary calls.
  const negotiated = await daemon.call("axo.protocol.negotiate", { protocolVersion: 1 });
  assert.ok("result" in negotiated);
  daemon.close();
});

test("a fragment that breaks the rules closes the socket", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const daemon = await Peer.connectHost(h.url, await h.token("daemon"), crypto.randomUUID(), "daemon");
  await daemon.negotiate();
  daemon.send({ jsonrpc: "2.0", method: "axo.transport.fragment", params: { messageId: "m", index: 0, count: 500, data: "" } });
  await assert.rejects(daemon.next(), /Disconnected/);
});
