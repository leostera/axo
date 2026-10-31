import assert from "node:assert/strict";
import { test } from "node:test";
import { randomToken, hmac } from "../src/auth/crypto";
import { Peer } from "../testing/client";
import { hostListResultSchema, hostPairingCreateResultSchema, hostPairingRedeemResultSchema, remoteTerminalInputResultSchema } from "@axo/protocol/v1";
import { harness, signIn, testSessionSecret } from "./harness";

const secret = testSessionSecret;

test("the account owns pairing and hosts; each host's socket lives in its own HostDO, and a client reaches every host through one socket", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const session = await signIn(h);
  const { accountId, headers } = session;
  const createPairing = async () => {
    const response = await fetch(new URL("api/v1/account/host-pairings", h.url), {
      method: "POST",
      headers: session.headers,
    });
    assert.equal(response.status, 200);
    return hostPairingCreateResultSchema.parse(await response.json()).code;
  };
  const redeem = async (code: string, label: string) => {
    const credentials = {
      hostId: crypto.randomUUID(),
      hostGeneration: crypto.randomUUID(),
      credentialId: crypto.randomUUID(),
      credential: randomToken(),
      label,
      hostKind: "macos",
    };
    const response = await fetch(new URL("api/v1/host-pairings/redeem", h.url), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code, ...credentials }),
    });
    assert.equal(response.status, 200);
    const result = hostPairingRedeemResultSchema.parse(await response.json());
    assert.equal(result.accountId, accountId);
    assert.equal(result.hostId, credentials.hostId);
    return { ...credentials, result };
  };

  const first = await redeem(await createPairing(), "Account host one");
  const second = await redeem(await createPairing(), "Account host two");
  const managerStorage = await h.mf.unsafeGetDurableObjectStorage("api-test", "AxoAccountDirectory", { name: accountId });
  const accountRow = await managerStorage.exec<{ account_id: string }>("SELECT account_id FROM account WHERE singleton = 1");
  assert.equal(accountRow[0]?.account_id, accountId, "a verified sign-in binds the stable account ID");
  const storedHosts = await managerStorage.exec<{ host_id: string }>("SELECT host_id FROM account_hosts ORDER BY host_id");
  assert.deepEqual(new Set(storedHosts.map((row) => row.host_id)), new Set([first.hostId, second.hostId]));

  const daemons = await Promise.all([first, second].map((host) => Peer.connectHostDaemon(
    h.url,
    accountId,
    host.hostId,
    {
      Authorization: `Bearer ${host.credential}`,
      "X-Axo-Credential-Id": host.credentialId,
    },
  )));
  t.after(() => daemons.forEach((daemon) => daemon.close()));

  for (const [index, daemon] of daemons.entries()) {
    const host = index === 0 ? first : second;
    await daemon.negotiate();
    const registered = await daemon.call("axo.host.register", {
      protocolVersion: 2,
      hostId: host.hostId,
      hostGeneration: host.hostGeneration,
      label: host.label,
      hostKind: host.hostKind,
      ...(index === 0 ? { capabilities: [
        { id: "agent.pi", version: 1 },
        { id: "terminal.pty", version: 1 },
        { id: "workspace.filesystem", version: 1 },
      ] } : {}),
      sessions: [],
    });
    assert.ok("result" in registered);
  }

  const listResponse = await fetch(new URL("api/v1/account/hosts", h.url), { headers });
  assert.equal(listResponse.status, 200);
  const hosts = hostListResultSchema.parse(await listResponse.json()).hosts;
  assert.equal(hosts.length, 2);
  assert.equal(hosts.every((host) => host.status === "online" && !host.stale), true);
  assert.deepEqual(hosts.find((host) => host.hostId === first.hostId)?.capabilities, [
    { id: "agent.pi", version: 1 },
    { id: "terminal.pty", version: 1 },
    { id: "workspace.filesystem", version: 1 },
  ], "the account manager persists host capability advertisements");
  assert.equal(hosts.find((host) => host.hostId === second.hostId)?.capabilities, undefined,
    "hosts that do not advertise capabilities remain distinguishable from hosts with an empty manifest");
  for (const host of [first, second]) {
    const hostStorage = await h.mf.unsafeGetDurableObjectStorage("api-test", "AxoHostDO", { name: `${accountId}:${host.hostId}` });
    const routes = await hostStorage.exec<{ count: number }>("SELECT COUNT(*) AS count FROM route");
    assert.equal(routes[0].count, 1, "each host's socket terminates on its own HostDO");
  }

  const clientId = `tab-${crypto.randomUUID()}`;
  const client = await Peer.connectClient(h.url, clientId, session.headers);
  t.after(() => client.close());
  const hello = await client.call("axo.client.hello", { protocolVersion: 2, clientId });
  assert.ok("result" in hello);
  const followed = (hello.result as { hosts: Array<{ hostId: string; online: boolean }> }).hosts;
  assert.deepEqual(new Set(followed.map((host) => host.hostId)), new Set([first.hostId, second.hostId]));
  assert.equal(followed.every((host) => host.online), true);

  const inputCall = client.call("axo.client.command", {
    hostId: first.hostId,
    method: "axo.remote.terminal.input",
    params: {
      target: { hostId: first.hostId, hostGeneration: first.hostGeneration },
      sessionId: "00000001-0000-4000-8000-000000000001",
      shellId: 1,
      sequence: 0,
      data: Buffer.from("isolated").toString("base64"),
    },
  });
  const forwarded = await daemons[0]!.next() as { id: string; method: string };
  assert.equal(forwarded.method, "axo.remote.terminal.input");
  const leakedToOtherHost = Promise.race([
    daemons[1]!.next().then(() => true, () => true),
    new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 100)),
  ]);
  assert.equal(await leakedToOtherHost, false, "a command reaches only the host it names");
  daemons[0]!.send({ jsonrpc: "2.0", id: forwarded.id, result: { accepted: true, sequence: 0 } });
  const inputReply = await inputCall;
  assert.ok("result" in inputReply);
  assert.equal(remoteTerminalInputResultSchema.parse(inputReply.result).accepted, true);

  const strangerClientId = `tab-${crypto.randomUUID()}`;
  const stranger = await Peer.connectClient(h.url, strangerClientId, (await signIn(h)).headers);
  t.after(() => stranger.close());
  await stranger.call("axo.client.hello", { protocolVersion: 2, clientId: strangerClientId });
  const refused = await stranger.call("axo.client.command", { hostId: first.hostId, method: "axo.remote.session.prompt", params: {} });
  assert.ok("error" in refused, "another account's client cannot reach this host");

  const firstCode = await createPairing();
  const firstReplayPayload = {
    code: firstCode,
    hostId: crypto.randomUUID(),
    hostGeneration: crypto.randomUUID(),
    credentialId: crypto.randomUUID(),
    credential: randomToken(),
    label: "Idempotent host",
    hostKind: "macos",
  };
  const redeemUrl = new URL("api/v1/host-pairings/redeem", h.url);
  const redeemOnce = () => fetch(redeemUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(firstReplayPayload),
  });
  const initialRedemption = await redeemOnce();
  await managerStorage.exec(
    "UPDATE pairings SET expires_at = ? WHERE code_verifier = ?",
    Date.now() - 1,
    await hmac(secret, `pairing-code\0${firstCode}`),
  );
  const idempotentRedemption = await redeemOnce();
  assert.equal(initialRedemption.status, 200);
  assert.equal(idempotentRedemption.status, 200);
  const replay = await fetch(redeemUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...firstReplayPayload, hostId: crypto.randomUUID() }),
  });
  assert.equal(replay.status, 400);

  const raceCode = await createPairing();
  const racedHosts = [0, 1].map((index) => ({
    code: raceCode,
    hostId: crypto.randomUUID(),
    hostGeneration: crypto.randomUUID(),
    credentialId: crypto.randomUUID(),
    credential: randomToken(),
    label: `Concurrent host ${index}`,
    hostKind: "macos",
  }));
  const raceResponses = await Promise.all(racedHosts.map((payload) => fetch(redeemUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  })));
  assert.deepEqual(raceResponses.map((response) => response.status).sort(), [200, 400]);
  const raceRows = await managerStorage.exec<{ host_id: string }>(
    "SELECT host_id FROM account_hosts WHERE host_id IN (?, ?)",
    racedHosts[0]!.hostId,
    racedHosts[1]!.hostId,
  );
  assert.equal(raceRows.length, 1, "a pairing code can atomically link only one host");

  const otherSession = await signIn(h);
  const otherHostList = await fetch(new URL("api/v1/account/hosts", h.url), {
    headers: otherSession.headers,
  });
  assert.deepEqual(hostListResultSchema.parse(await otherHostList.json()).hosts, []);

  const revoked = await fetch(new URL(`api/v1/account/hosts/${first.hostId}/revoke`, h.url), {
    method: "POST",
    headers: session.headers,
  });
  assert.equal(revoked.status, 204);
  const afterRevocation = hostListResultSchema.parse(await (await fetch(
    new URL("api/v1/account/hosts", h.url), { headers },
  )).json()).hosts.find((host) => host.hostId === first.hostId);
  assert.equal(afterRevocation?.status, "offline");
  assert.equal(afterRevocation?.stale, true);
  await assert.rejects(Peer.connectHostDaemon(
    h.url,
    accountId,
    first.hostId,
    { Authorization: `Bearer ${first.credential}`, "X-Axo-Credential-Id": first.credentialId },
  ));
});
