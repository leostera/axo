import assert from "node:assert/strict";
import { test } from "node:test";
import type { HostMethodParams } from "@axo/protocol/v1";
import { Peer } from "../testing/client";
import { connectHost, pairHost } from "./account-support";
import { harness, signIn } from "./harness";

const method = "axo.remote.session.fork";

test("paired Mac fork commands are scoped to their account and destination on both peer routes", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const account = await signIn(h);
  const otherAccount = await signIn(h);
  const source = await pairHost(h, account, "Source");
  const destination = await pairHost(h, account, "Destination");
  const foreign = await pairHost(h, otherAccount, "Foreign");
  const daemon = await connectHost(h, account, destination);
  t.after(() => daemon.close());
  const credential = (host: typeof source) => ({
    Authorization: `Bearer ${host.credential}`,
    "X-Axo-Credential-Id": host.credentialId,
  });

  await assert.rejects(
    Peer.connectPeerHostClient(h.url, account.accountId, source.hostId, destination.hostId, credential(foreign)),
    /401/,
  );
  await assert.rejects(
    Peer.connectPeerHostClient(h.url, account.accountId, source.hostId, foreign.hostId, credential(source)),
    /404/,
  );

  const target = { hostId: destination.hostId, hostGeneration: destination.hostGeneration };
  const params: HostMethodParams<typeof method> = {
    target, sourceHostId: source.hostId, sessionId: crypto.randomUUID(),
    epoch: 1, head: 42, requestId: crypto.randomUUID(), folder: "/Users/example/project",
  };
  const result = { session: {
    hostId: destination.hostId, sessionId: crypto.randomUUID(), shells: [], layout: null,
    updatedAt: "2026-10-30T00:00:00Z",
  } };
  const clientId = `host-${source.hostId}`;
  for (const protocol of [2, 3]) {
    const peer = protocol === 2
      ? await Peer.connectHostPeers(h.url, account.accountId, source.hostId, credential(source))
      : await Peer.connectPeerHostClient(h.url, account.accountId, source.hostId, destination.hostId, credential(source));
    t.after(() => peer.close());
    const hello = await peer.call("axo.client.hello", { protocolVersion: protocol, clientId, ...(protocol === 3 ? { connection: 1 } : {}) });
    assert.ok("result" in hello, JSON.stringify(hello));
    const command = (fork: HostMethodParams<typeof method>, hostId = target.hostId) =>
      peer.call("axo.client.command", { hostId, method, params: fork });

    for (const [invalid, hostId, code] of [
      [{ ...params, sourceHostId: foreign.hostId }, target.hostId, -32602],
      [{ ...params, sourceHostId: target.hostId }, target.hostId, -32602],
      [{ ...params, target: { ...target, hostId: source.hostId } }, target.hostId, -32002],
      [{ ...params, target: { ...target, hostGeneration: crypto.randomUUID() } }, target.hostId, -32002],
      [params, foreign.hostId, -32602],
      [{ ...params, folder: "relative/path" }, target.hostId, -32602],
    ] as const) {
      const reply = await command(invalid, hostId);
      assert.ok("error" in reply, JSON.stringify(reply));
      assert.equal(reply.error.code, code);
    }

    const invoke = async (reply: { result: unknown } | { error: { code: number; message: string } }) => {
      const pending = command(params);
      const sent = await daemon.next() as { id: string; method: string; params: unknown };
      assert.equal(sent.method, method);
      assert.deepEqual(sent.params, params, "rejected calls did not reach the daemon");
      daemon.send({ jsonrpc: "2.0", id: sent.id, ...reply });
      return pending;
    };
    const forked = await invoke({ result });
    assert.ok("result" in forked, JSON.stringify(forked));
    assert.deepEqual(forked.result, result);
    for (const error of [
      { code: -32602, message: "Choose a destination folder" },
      { code: -32601, message: "Method not found" },
      { code: -32602, message: "Only Pi sessions can be forked" },
    ]) {
      const refused = await invoke({ error });
      assert.ok("error" in refused, JSON.stringify(refused));
      assert.deepEqual(refused.error, error);
    }
    const invalid = await invoke({ result: { accepted: true } });
    assert.ok("error" in invalid, JSON.stringify(invalid));
    assert.equal(invalid.error.code, -32004);
    peer.close();
  }
});
