import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { RemoteAxoApi, type HostEvent, type WebSocketLike } from "@axo/app";
import WebSocket from "ws";
import { createConnection } from "node:net";
import { harness, signIn, type AccountSession } from "./harness";

const sleep = (milliseconds: number) =>
  new Promise((resolveSleep) => setTimeout(resolveSleep, milliseconds));

async function waitFor<T>(
  description: string,
  timeoutMs: number,
  poll: () => Promise<T | undefined>,
  child?: ChildProcess,
): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child && child.exitCode !== null) {
      throw new Error(`axod exited before ${description} (code ${child.exitCode}, signal ${child.signalCode})`);
    }
    const value = await poll();
    if (value !== undefined) return value;
    await sleep(40);
  }
  throw new Error(`Timed out waiting for ${description}`);
}

async function terminate(child: ChildProcess, processGroup = false): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const signal = (name: NodeJS.Signals) => {
    try {
      if (processGroup && child.pid) process.kill(-child.pid, name);
      else child.kill(name);
    } catch { /* already exited */ }
  };
  const exited = new Promise<void>((resolveExit) => child.once("exit", () => resolveExit()));
  signal("SIGTERM");
  await Promise.race([exited, sleep(4_000)]);
  if (child.exitCode === null && child.signalCode === null) {
    signal("SIGKILL");
    await Promise.race([exited, sleep(2_000)]);
  }
}

/** One JSON-RPC call over axod's local socket (newline-delimited JSON). */
async function localCall(socketPath: string, method: string, params?: unknown): Promise<unknown> {
  return new Promise((resolveCall, rejectCall) => {
    const socket = createConnection(socketPath);
    let buffered = "";
    socket.setTimeout(30_000, () => socket.destroy(new Error(`${method} timed out`)));
    socket.on("error", rejectCall);
    socket.on("data", (chunk) => {
      buffered += chunk.toString("utf8");
      const newline = buffered.indexOf("\n");
      if (newline < 0) return;
      socket.end();
      const reply = JSON.parse(buffered.slice(0, newline)) as { result?: unknown; error?: { message: string } };
      if (reply.error) rejectCall(new Error(`${method}: ${reply.error.message}`));
      else resolveCall(reply.result);
    });
    socket.on("connect", () => {
      socket.write(`${JSON.stringify({ jsonrpc: "2.0", id: 1, method, params: params ?? null })}\n`);
    });
  });
}

function accountApi(url: string, account: AccountSession): RemoteAxoApi {
  return new RemoteAxoApi(
    url,
    async (input, init) => {
      const headers = new Headers(init?.headers);
      for (const [name, value] of Object.entries(account.headers)) headers.set(name, value);
      return fetch(input, { ...init, headers });
    },
    browserWebSocketFactory(account.headers),
  );
}

function browserWebSocketFactory(headers: Record<string, string>) {
  return (url: string): WebSocketLike => {
    const socket = new WebSocket(url, {
      headers,
      followRedirects: false,
      maxPayload: 65_536,
    });
    let onopen: WebSocketLike["onopen"] = null;
    let onmessage: WebSocketLike["onmessage"] = null;
    let onerror: WebSocketLike["onerror"] = null;
    let onclose: WebSocketLike["onclose"] = null;
    socket.on("open", () => onopen?.(new Event("open")));
    socket.on("message", (data) => onmessage?.({ data: data.toString() } as MessageEvent));
    socket.on("error", () => onerror?.(new Event("error")));
    socket.on("close", (code, reason) => onclose?.({ code, reason: reason.toString() } as CloseEvent));
    return {
      get readyState() { return socket.readyState; },
      send: (data) => socket.send(data),
      close: (code, reason) => socket.close(code, reason),
      get onopen() { return onopen; },
      set onopen(handler) { onopen = handler; },
      get onmessage() { return onmessage; },
      set onmessage(handler) { onmessage = handler; },
      get onerror() { return onerror; },
      set onerror(handler) { onerror = handler; },
      get onclose() { return onclose; },
      set onclose(handler) { onclose = handler; },
    } satisfies WebSocketLike;
  };
}

async function waitForHostEvent(
  events: HostEvent[],
  predicate: (event: HostEvent) => boolean,
  description: string,
  child?: ChildProcess,
) {
  return waitFor(description, 18_000, async () => {
    const index = events.findIndex(predicate);
    if (index < 0) return undefined;
    return events.splice(index, 1)[0];
  }, child);
}

test("an isolated axod pairs with an account, then the account drives it through the relay until revoked", async (t) => {
  const binary = process.env.AXOD_BINARY;
  assert.ok(binary, "set AXOD_BINARY to the Bazel-built axod binary");
  const axodBinary = resolve(process.cwd(), binary);
  assert.ok(existsSync(axodBinary), `axod binary must exist at ${axodBinary}`);

  const api = await harness();
  const root = await mkdtemp(join(tmpdir(), "axo-axod-relay-"));
  const serverDirectory = join(root, "server");
  const socketPath = join(root, "axod.sock");
  await mkdir(serverDirectory, { recursive: true, mode: 0o700 });
  await writeFile(
    join(serverDirectory, "relay.json"),
    JSON.stringify({
      relayUrl: api.url,
      hostLabel: "Isolated axod test host",
      hostKind: "macos",
      allowInsecureLoopback: true,
    }),
    { mode: 0o600 },
  );

  let daemon: ChildProcess | undefined;
  let attachment: ChildProcess | undefined;
  let client: Awaited<ReturnType<RemoteAxoApi["connectHost"]>> | undefined;
  const liveEvents: HostEvent[] = [];
  const outputChunks: string[] = [];
  try {
    daemon = spawn(axodBinary, [
      "--server-dir", serverDirectory,
      "--socket", socketPath,
      // Never touch the login Keychain from a test.
      "--host-credentials", "files",
    ], {
      stdio: "ignore",
      env: { ...process.env, HOME: root },
    });
    await new Promise<void>((resolveSpawn, rejectSpawn) => {
      daemon!.once("spawn", () => resolveSpawn());
      daemon!.once("error", rejectSpawn);
    });
    await waitFor("the axod socket", 15_000, async () => (existsSync(socketPath) ? true : undefined), daemon);

    // A signed-in person creates a pairing code; this Mac redeems it locally.
    const account = await signIn(api);
    const remoteApi = accountApi(api.url, account);
    assert.deepEqual(await remoteApi.listHosts(), [], "an unpaired host is not visible to anyone");
    const pairing = await fetch(new URL("api/v1/account/host-pairings", api.url), {
      method: "POST",
      headers: account.headers,
    });
    assert.equal(pairing.status, 200);
    const { code } = (await pairing.json()) as { code: string };
    const linked = (await localCall(socketPath, "axo.relay.link", { code })) as { linked: boolean };
    assert.equal(linked.linked, true);

    const relayConfig = await readFile(join(serverDirectory, "relay.json"), "utf8");
    const { credentialId, accountId } = JSON.parse(relayConfig) as { credentialId: string; accountId: string };
    assert.equal(accountId, account.accountId);
    const credentialFile = join(serverDirectory, "host-credentials", credentialId);
    assert.equal((await stat(credentialFile)).mode & 0o777, 0o600);
    assert.equal(relayConfig.includes((await readFile(credentialFile)).toString("utf8")), false,
      "the credential is never written to relay.json");

    const replay = await fetch(new URL("api/v1/account/host-pairings", api.url), { method: "GET", headers: account.headers });
    assert.notEqual(replay.status, 200, "pairing codes are created only by POST");

    const registered = await waitFor("axod host registration", 20_000, async () =>
      (await remoteApi.listHosts()).find((host) => host.label === "Isolated axod test host" && host.status === "online"),
    daemon);
    assert.equal(registered.stale, false);
    const { hostId, hostGeneration } = registered;
    assert.ok(registered.sessions.length > 0, "axod must register its initial local session");
    const firstSession = registered.sessions[0];
    assert.ok(firstSession.shells.length > 0, "registered session has a shell");
    assert.equal(JSON.stringify(firstSession).match(/attachSocketPath|ptyDevice|terminalOutput/gi), null);

    // Another account sees nothing and cannot open the host.
    const stranger = await signIn(api);
    assert.deepEqual(await accountApi(api.url, stranger).listHosts(), []);
    await assert.rejects(
      accountApi(api.url, stranger).connectHost({ hostId, hostGeneration }, () => {}),
      "a client of another account cannot reach this host",
    );

    let clientClosedBecause: string | undefined;
    client = await remoteApi.connectHost({ hostId, hostGeneration }, (event) => {
      liveEvents.push(event);
      if (event.type === "host.data" && event.event.type === "terminal.output") {
        outputChunks.push(Buffer.from(event.event.data, "base64").toString("utf8"));
      }
    }, (error) => { clientClosedBecause = error.message; });
    await waitForHostEvent(
      liveEvents,
      (event) => event.type === "host.presence" && event.status === "online",
      "the app relay subscription",
      daemon,
    );

    const sessionList = await remoteApi.listHostSessions({ hostId, hostGeneration });
    assert.equal(sessionList.some((session) => session.sessionId === firstSession.sessionId), true);

    attachment = spawn("python3", [
      "-c",
      "import pty, sys; pty.spawn(sys.argv[1:])",
      axodBinary,
      "terminal-attach",
      "--attach-socket",
      join(serverDirectory, "attach.sock"),
      "--shell-id",
      String(firstSession.shells[0].shellId),
    ], {
      detached: true,
      stdio: ["pipe", "ignore", "ignore"],
      env: { ...process.env, HOME: root },
    });
    await new Promise<void>((resolveSpawn, rejectSpawn) => {
      attachment!.once("spawn", () => resolveSpawn());
      attachment!.once("error", rejectSpawn);
    });
    await waitForHostEvent(
      liveEvents,
      (event) => event.type === "host.data" && event.event.type === "shell.activity" && event.event.activity === "attached",
      "the isolated local PTY attachment",
      attachment,
    );

    const terminalText = `AXO_REMOTE_RELAY_${crypto.randomUUID().replaceAll("-", "")}`;
    const input = Buffer.from(`printf '${terminalText}\\n'\n`).toString("base64");
    const inputReply = await client.call("axo.remote.terminal.input", {
      target: { hostId, hostGeneration },
      sessionId: firstSession.sessionId,
      shellId: firstSession.shells[0].shellId,
      sequence: 0,
      data: input,
    });
    assert.equal(inputReply.accepted, true);
    await waitFor("the streamed remote terminal output", 18_000, async () =>
      outputChunks.join("").includes(terminalText) ? true : undefined,
    );

    const createReply = await client.call("axo.remote.session.create", {
      target: { hostId, hostGeneration },
    });
    const created = createReply.session;
    assert.equal(created.hostId, hostId);
    await waitFor("the new session snapshot", 5_000, async () => {
      const current = await remoteApi.listHostSessions({ hostId, hostGeneration });
      return current.some((session) => session.sessionId === created.sessionId) ? true : undefined;
    }, daemon);

    // Terminal bytes are relayed, never stored, on either side.
    const accountStorage = await api.mf.unsafeGetDurableObjectStorage("api-test", "AxoAccountDirectory", {
      name: account.accountId,
    });
    const storedSessions = await accountStorage.exec<{ snapshot_json: string }>(
      "SELECT snapshot_json FROM host_sessions_v1 WHERE host_id = ?",
      hostId,
    );
    assert.ok(storedSessions.length > 0, "session metadata is retained for the account");
    assert.equal(JSON.stringify(storedSessions).includes(terminalText), false);
    const databaseBytes = await readFile(join(serverDirectory, "axo.db")).catch(() => Buffer.alloc(0));
    assert.equal(databaseBytes.includes(Buffer.from(terminalText)), false);

    // Revoking the host closes its relay and keeps its metadata as offline.
    const revoked = await fetch(new URL(`api/v1/account/hosts/${hostId}/revoke`, api.url), {
      method: "POST",
      headers: account.headers,
    });
    assert.equal(revoked.status, 204);
    const offlineHost = await waitFor("the revoked host to be offline", 10_000, async () => {
      const host = (await remoteApi.listHosts()).find((item) => item.hostId === hostId);
      return host && host.status !== "online" ? host : undefined;
    });
    assert.ok(offlineHost.sessions.some((session) => session.sessionId === created.sessionId));
    await waitFor("the revoked host's clients to be disconnected", 5_000, async () => clientClosedBecause);
    // axod retries with its revoked credential and is refused.
    await waitFor("axod's reconnect with the revoked credential to be refused", 15_000, async () => {
      const log = await readFile(join(serverDirectory, "stderr.log"), "utf8");
      return /event=relay\.connection_retry reason=HTTP error: 403/.test(log) ? true : undefined;
    }, daemon);
    const afterRetry = (await remoteApi.listHosts()).find((item) => item.hostId === hostId);
    assert.notEqual(afterRetry?.status, "online", "a revoked host credential cannot reconnect");
  } finally {
    if (client) client.close();
    if (attachment) await terminate(attachment, true);
    if (daemon) await terminate(daemon);
    await api.close();
    await rm(root, { recursive: true, force: true });
  }
});
