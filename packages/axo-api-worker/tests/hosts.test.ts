import assert from "node:assert/strict";
import { test } from "node:test";
import {
  hostListResultSchema,
  hostRegisterResultSchema,
  hostSessionsListResultSchema,
  hostDataEventSchema,
  hostNotificationSchema,
  remoteSessionCreateResultSchema,
  remoteTerminalInputResultSchema,
  sessionsPublishResultSchema,
} from "@axo/protocol/v1";
import { accessHeaders } from "../testing/access-headers";
import { harness, Peer } from "./harness";

const noStore = (response: Response) => assert.match(response.headers.get("Cache-Control") ?? "", /no-store/);

async function waitForOffline(url: string, headers: Record<string, string>, hostId: string) {
  const deadline = Date.now() + 3_000;
  while (Date.now() < deadline) {
    const response = await fetch(url, { headers });
    const result = hostListResultSchema.parse(await response.json());
    const host = result.hosts.find((item) => item.hostId === hostId);
    if (host?.status === "offline") return host;
    await new Promise((resolve) => setTimeout(resolve, 30));
  }
  throw new Error("Host did not become offline before the bounded deadline");
}

test("host metadata is available without Worker JWT validation and becomes stale without persisting terminal content", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const hostId = crypto.randomUUID();
  const hostGeneration = crypto.randomUUID();
  const headers = accessHeaders(await h.token("client"));
  const listURL = new URL("v1/hosts", h.url);
  const appOrigin = "https://axo.leostera.dev";

  assert.equal((await fetch(listURL)).status, 200);
  assert.equal((await fetch(listURL, { headers: accessHeaders(await h.token("daemon")) })).status, 200);
  const appResponse = await fetch(listURL, {
    headers: { ...headers, Origin: appOrigin },
  });
  assert.equal(appResponse.headers.get("Access-Control-Allow-Origin"), appOrigin);
  assert.equal(appResponse.headers.get("Access-Control-Allow-Credentials"), "true");
  assert.match(appResponse.headers.get("Vary") ?? "", /Origin/);
  const deniedOriginResponse = await fetch(listURL, {
    headers: { ...headers, Origin: "https://attacker.example" },
  });
  assert.equal(deniedOriginResponse.headers.get("Access-Control-Allow-Origin"), null);
  const preflight = await fetch(listURL, {
    method: "OPTIONS",
    headers: {
      Origin: appOrigin,
      "Access-Control-Request-Method": "GET",
      "Access-Control-Request-Headers": "content-type",
    },
  });
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get("Access-Control-Allow-Origin"), appOrigin);

  const daemon = await Peer.connectHost(h.url, await h.token("daemon"), hostId, "daemon");
  await daemon.negotiate();
  const registered = await daemon.call("axo.host.register", {
    protocolVersion: 1,
    hostId,
    hostGeneration,
    label: "Axo Mac metadata fixture",
    hostKind: "macos",
    sessions: [{
      hostId,
      sessionId: 9,
      shells: [{ shellId: 12 }, { shellId: 13 }],
      layout: {
        kind: "split",
        id: crypto.randomUUID(),
        direction: "right",
        ratio: 0.5,
        first: { kind: "pane", shellId: 12 },
        second: { kind: "pane", shellId: 13 },
      },
      updatedAt: new Date().toISOString(),
    }],
  });
  assert.ok("result" in registered, "host registration should succeed");
  const registrationResult = hostRegisterResultSchema.parse(registered.result);
  assert.equal(registrationResult.host.status, "online");
  assert.equal(registrationResult.host.stale, false);

  const listResponse = await fetch(listURL, { headers });
  assert.equal(listResponse.status, 200);
  noStore(listResponse);
  const listed = hostListResultSchema.parse(await listResponse.json());
  assert.equal(listed.hosts.length, 1);
  assert.equal(listed.hosts[0].hostId, hostId);
  assert.equal(listed.hosts[0].sessions[0].sessionId, 9);

  const sessionsURL = new URL(`v1/hosts/${hostId}/sessions`, h.url);
  sessionsURL.searchParams.set("hostGeneration", hostGeneration);
  const sessionsResponse = await fetch(sessionsURL, { headers });
  assert.equal(sessionsResponse.status, 200);
  noStore(sessionsResponse);
  const sessions = hostSessionsListResultSchema.parse(await sessionsResponse.json());
  assert.equal(sessions.host.hostId, hostId);
  assert.deepEqual(sessions.sessions[0].shells, [{ shellId: 12 }, { shellId: 13 }]);

  const listedViaRpc = await fetch(new URL("v1/rpc", h.url), {
    method: "POST",
    headers: { ...headers, "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: "hosts", method: "axo.host.list", params: {} }),
  });
  assert.equal(listedViaRpc.status, 200);
  noStore(listedViaRpc);
  const rpcList = await listedViaRpc.json() as { result: unknown };
  assert.equal(hostListResultSchema.parse(rpcList.result).hosts[0].hostId, hostId);

  const publication = await daemon.call("axo.host.sessions.publish", {
    hostId,
    hostGeneration,
    sessions: [{
      hostId,
      sessionId: 10,
      shells: [{ shellId: 14 }],
      layout: { kind: "pane", shellId: 14 },
      updatedAt: new Date().toISOString(),
    }],
  });
  assert.ok("result" in publication);
  assert.equal(sessionsPublishResultSchema.parse(publication.result).storedAt.length > 0, true);
  const latestResponse = await fetch(sessionsURL, { headers });
  const latest = hostSessionsListResultSchema.parse(await latestResponse.json());
  assert.deepEqual(latest.sessions.map((session) => session.sessionId), [10]);

  const staleGenerationURL = new URL(sessionsURL);
  staleGenerationURL.searchParams.set("hostGeneration", crypto.randomUUID());
  assert.equal((await fetch(staleGenerationURL, { headers })).status, 409);

  const attemptedTerminalContent = await daemon.call("axo.host.sessions.publish", {
    hostId,
    hostGeneration,
    sessions: [{
      ...latest.sessions[0],
      terminalOutput: "NEVER_PERSIST_TERMINAL_CONTENT",
    }],
  });
  assert.ok("error" in attemptedTerminalContent, "terminal content must fail strict boundary parsing");
  assert.equal(attemptedTerminalContent.error.code, -32602);

  const storage = await h.mf.unsafeGetDurableObjectStorage("api-test", "AxoHostDirectory", {
    name: "private-fleet",
  });
  const storedRows = await storage.exec<{ host_id: string; snapshot_json: string }>(
    "SELECT host_id, snapshot_json FROM host_sessions_v1 WHERE host_id = ?",
    hostId,
  );
  assert.equal(storedRows.length, 1);
  assert.equal(storedRows[0].host_id, hostId);
  const storedSnapshot = JSON.parse(storedRows[0].snapshot_json) as Record<string, unknown>;
  assert.deepEqual(Object.keys(storedSnapshot).sort(), ["hostId", "layout", "sessionId", "shells", "updatedAt"].sort());
  assert.equal(JSON.stringify(storedRows).includes("NEVER_PERSIST_TERMINAL_CONTENT"), false);

  daemon.close();
  const offline = await waitForOffline(String(listURL), headers, hostId);
  assert.equal(offline.stale, true);
  assert.equal(offline.sessions[0].sessionId, 10);

  await h.restart();
  const restartedListURL = new URL("v1/hosts", h.url);
  const afterRestartResponse = await fetch(restartedListURL, { headers });
  const afterRestart = hostListResultSchema.parse(await afterRestartResponse.json());
  assert.equal(afterRestart.hosts[0].status, "offline");
  assert.equal(afterRestart.hosts[0].stale, true);
  assert.equal(afterRestart.hosts[0].sessions[0].sessionId, 10);
});

test("host subscriptions stream metadata and output; remote controls are routed without storing terminal bytes", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const hostId = crypto.randomUUID();
  const hostGeneration = crypto.randomUUID();
  const daemon = await Peer.connectHost(h.url, await h.token("daemon"), hostId, "daemon");
  await daemon.negotiate();
  const initialSnapshot = {
    hostId,
    sessionId: 1,
    shells: [{ shellId: 2 }],
    layout: { kind: "pane", shellId: 2 },
    updatedAt: new Date().toISOString(),
  };
  const registration = await daemon.call("axo.host.register", {
    protocolVersion: 1,
    hostId,
    hostGeneration,
    label: "Relay fixture",
    hostKind: "macos",
    sessions: [initialSnapshot],
  });
  assert.ok("result" in registration);

  const client = await Peer.connectHost(
    h.url,
    await h.token("client"),
    hostId,
    "client",
    true,
    "https://axo.leostera.dev",
  );
  await client.negotiate();
  const subscribed = await client.call("axo.host.subscribe", { hostId, hostGeneration });
  assert.ok("result" in subscribed);
  const subscriptionId = (subscribed.result as { subscriptionId: string }).subscriptionId;
  const presence = hostNotificationSchema.parse(await client.next());
  assert.equal(presence.params.subscriptionId, subscriptionId);
  assert.equal(presence.params.event.type, "host.presence");

  const liveSnapshot = {
    ...initialSnapshot,
    sessionId: 3,
    updatedAt: new Date().toISOString(),
  };
  const metadataEvent = hostDataEventSchema.parse({
    type: "host.data",
    hostId,
    hostGeneration,
    event: { type: "session.snapshot", snapshot: liveSnapshot },
  });
  daemon.send({ jsonrpc: "2.0", method: "axo.host.event", params: metadataEvent });
  const metadataNotification = hostNotificationSchema.parse(await client.next());
  assert.deepEqual(metadataNotification.params.event, metadataEvent);
  const stored = await fetch(new URL(`v1/hosts/${hostId}/sessions?hostGeneration=${hostGeneration}`, h.url), {
    headers: accessHeaders(await h.token("client")),
  });
  const persisted = hostSessionsListResultSchema.parse(await stored.json());
  assert.ok(persisted.sessions.some((session) => session.sessionId === 3));

  const terminalText = "REMOTE_TERMINAL_BYTES_MUST_NOT_PERSIST";
  const terminalEvent = hostDataEventSchema.parse({
    type: "host.data",
    hostId,
    hostGeneration,
    event: {
      type: "terminal.output",
      sessionId: 3,
      shellId: 2,
      sequence: 1,
      data: Buffer.from(terminalText).toString("base64"),
    },
  });
  daemon.send({ jsonrpc: "2.0", method: "axo.host.event", params: terminalEvent });
  const outputNotification = hostNotificationSchema.parse(await client.next());
  assert.deepEqual(outputNotification.params.event, terminalEvent);

  const remoteInput = client.call("axo.remote.terminal.input", {
    target: { hostId, hostGeneration },
    sessionId: 3,
    shellId: 2,
    sequence: 0,
    data: Buffer.from("echo remote").toString("base64"),
  });
  const inputRequest = await daemon.next() as {
    id: string;
    method: string;
    params: unknown;
  };
  assert.equal(inputRequest.method, "axo.remote.terminal.input");
  daemon.send({
    jsonrpc: "2.0",
    id: inputRequest.id,
    result: { accepted: true, sequence: 0 },
  });
  const inputResult = await remoteInput;
  assert.ok("result" in inputResult);
  assert.equal(remoteTerminalInputResultSchema.parse(inputResult.result).accepted, true);

  const createSession = client.call("axo.remote.session.create", { target: { hostId, hostGeneration } });
  const createRequest = await daemon.next() as { id: string; method: string };
  assert.equal(createRequest.method, "axo.remote.session.create");
  daemon.send({
    jsonrpc: "2.0",
    id: createRequest.id,
    result: { session: { ...initialSnapshot, sessionId: 4 } },
  });
  const createResult = await createSession;
  assert.ok("result" in createResult);
  assert.equal(remoteSessionCreateResultSchema.parse(createResult.result).session.sessionId, 4);

  const workspaceSessionCreate = client.call("axo.remote.workspace.session.create", {
    target: { hostId, hostGeneration },
    workspaceId: "04d389d1-9896-420e-9b42-fc7835522937",
  });
  const workspaceCreateRequest = await daemon.next() as { id: string; method: string; params: { workspaceId: string } };
  assert.equal(workspaceCreateRequest.method, "axo.remote.workspace.session.create");
  assert.equal(workspaceCreateRequest.params.workspaceId, "04d389d1-9896-420e-9b42-fc7835522937");
  daemon.send({
    jsonrpc: "2.0",
    id: workspaceCreateRequest.id,
    result: { session: { ...initialSnapshot, sessionId: 5, workspaceId: workspaceCreateRequest.params.workspaceId, workspaceName: "Test workspace", hasAgent: true, shells: [], layout: null } },
  });
  const workspaceCreateResult = await workspaceSessionCreate;
  assert.ok("result" in workspaceCreateResult);
  assert.equal(remoteSessionCreateResultSchema.parse(workspaceCreateResult.result).session.sessionId, 5);

  const directoryStorage = await h.mf.unsafeGetDurableObjectStorage("api-test", "AxoHostDirectory", {
    name: "private-fleet",
  });
  const persistedRows = await directoryStorage.exec<{ snapshot_json: string }>(
    "SELECT snapshot_json FROM host_sessions_v1 WHERE host_id = ?",
    hostId,
  );
  assert.equal(JSON.stringify(persistedRows).includes(terminalText), false);
  const relayStorage = await h.mf.unsafeGetDurableObjectStorage("api-test", "AxoHostRelay", {
    name: hostId,
  });
  const relayRows = await relayStorage.exec<{ value: string }>(
    "SELECT name AS value FROM sqlite_master WHERE type = 'table'",
  );
  assert.equal(JSON.stringify(relayRows).includes(terminalText), false);

  const unsubscribed = await client.call("axo.host.unsubscribe", { subscriptionId });
  assert.ok("result" in unsubscribed);
  client.close();
  daemon.close();
});
