import assert from "node:assert/strict";
import { test } from "node:test";
import { randomToken, hmac } from "../src/auth/crypto";
import { Peer } from "../testing/client";
import { hostDataEventSchema, hostListResultSchema, hostNotificationSchema, hostPairingCreateResultSchema, hostPairingRedeemResultSchema, remoteTerminalInputResultSchema } from "@axo/protocol/v1";
import { harness, signIn, testSessionSecret } from "./harness";

const secret = testSessionSecret;

test("one AccountManager owns pairing, host metadata, and live relays for multiple hosts", async (t) => {
  const h = await harness({ bindings: { SESSION_SECRET: secret } });
  t.after(() => h.close());
  const accountId = crypto.randomUUID();
  const session = await signIn(h, accountId);
  const headers = session.headers;
  const createPairing = async () => {
    const response = await fetch(new URL("api/v1/account/host-pairings", h.url), {
      method: "POST",
      headers: session.mutationHeaders,
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
  assert.equal(accountRow[0]?.account_id, accountId, "existing valid sessions bind the stable account ID on first use");
  const storedHosts = await managerStorage.exec<{ host_id: string }>("SELECT host_id FROM account_hosts ORDER BY host_id");
  assert.deepEqual(new Set(storedHosts.map((row) => row.host_id)), new Set([first.hostId, second.hostId]));

  const daemons = await Promise.all([first, second].map((host) => Peer.connectAccountHost(
    h.url,
    accountId,
    host.hostId,
    "daemon",
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
      protocolVersion: 1,
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
  const routes = await managerStorage.exec<{ count: number }>("SELECT COUNT(*) AS count FROM route");
  assert.equal(routes[0].count, 2, "both daemon sockets terminate on the account manager DO");

  const clients = await Promise.all([first, second].map((host) => Peer.connectAccountHost(
    h.url,
    accountId,
    host.hostId,
    "client",
    session.headers,
  )));
  t.after(() => clients.forEach((client) => client.close()));
  for (const [index, client] of clients.entries()) {
    const host = index === 0 ? first : second;
    await client.negotiate();
    const subscribed = await client.call("axo.host.subscribe", {
      hostId: host.hostId,
      hostGeneration: host.hostGeneration,
    });
    assert.ok("result" in subscribed);
    const presence = hostNotificationSchema.parse(await client.next());
    assert.equal(presence.params.event.hostId, host.hostId);
  }

  const terminalSecret = "ACCOUNT_TERMINAL_BYTES_MUST_NOT_PERSIST";
  const terminalEvent = hostDataEventSchema.parse({
    type: "host.data",
    hostId: first.hostId,
    hostGeneration: first.hostGeneration,
    event: {
      type: "terminal.output",
      sessionId: 1,
      shellId: 1,
      sequence: 0,
      data: Buffer.from(terminalSecret).toString("base64"),
    },
  });
  daemons[0]!.send({ jsonrpc: "2.0", method: "axo.host.event", params: terminalEvent });
  const output = hostNotificationSchema.parse(await clients[0]!.next());
  assert.deepEqual(output.params.event, terminalEvent);
  const snapshots = await managerStorage.exec<{ snapshot_json: string }>("SELECT snapshot_json FROM host_sessions_v1");
  assert.equal(JSON.stringify(snapshots).includes(terminalSecret), false);

  const inputCall = clients[0]!.call("axo.remote.terminal.input", {
    target: { hostId: first.hostId, hostGeneration: first.hostGeneration },
    sessionId: 1,
    shellId: 1,
    sequence: 0,
    data: Buffer.from("isolated").toString("base64"),
  });
  const forwarded = await daemons[0]!.next() as { id: string; method: string };
  assert.equal(forwarded.method, "axo.remote.terminal.input");
  const leakedToOtherHost = Promise.race([
    daemons[1]!.next().then(() => true, () => true),
    new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 100)),
  ]);
  assert.equal(await leakedToOtherHost, false, "host traffic remains isolated inside the shared account object");
  daemons[0]!.send({ jsonrpc: "2.0", id: forwarded.id, result: { accepted: true, sequence: 0 } });
  const inputReply = await inputCall;
  assert.ok("result" in inputReply);
  assert.equal(remoteTerminalInputResultSchema.parse(inputReply.result).accepted, true);

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

  const otherAccountId = crypto.randomUUID();
  const otherSession = await signIn(h, otherAccountId);
  const otherHostList = await fetch(new URL("api/v1/account/hosts", h.url), {
    headers: otherSession.headers,
  });
  assert.deepEqual(hostListResultSchema.parse(await otherHostList.json()).hosts, []);

  const revoked = await fetch(new URL(`api/v1/account/hosts/${first.hostId}/revoke`, h.url), {
    method: "POST",
    headers: session.mutationHeaders,
  });
  assert.equal(revoked.status, 204);
  const afterRevocation = hostListResultSchema.parse(await (await fetch(
    new URL("api/v1/account/hosts", h.url), { headers },
  )).json()).hosts.find((host) => host.hostId === first.hostId);
  assert.equal(afterRevocation?.status, "offline");
  assert.equal(afterRevocation?.stale, true);
  await assert.rejects(Peer.connectAccountHost(
    h.url,
    accountId,
    first.hostId,
    "daemon",
    { Authorization: `Bearer ${first.credential}`, "X-Axo-Credential-Id": first.credentialId },
  ));
});
