import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { RemoteAxoApi, type HostEvent, type WebSocketLike } from "@axo/app";
import WebSocket from "ws";
import { harness } from "./harness";

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

function browserWebSocketFactory() {
  return (url: string): WebSocketLike => {
    const socket = new WebSocket(url, {
      headers: { Origin: "https://axo.leostera.dev" },
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

test("an isolated axod registers, publishes, streams PTY output, accepts remote input, and creates sessions", async (t) => {
  const binary = process.env.AXOD_BINARY;
  assert.ok(binary, "set AXOD_BINARY to the Bazel-built axod binary");
  const axodBinary = resolve(process.cwd(), binary);
  assert.ok(existsSync(axodBinary), `axod binary must exist at ${axodBinary}`);

  const api = await harness();
  const root = await import("node:fs/promises").then(({ mkdtemp }) => mkdtemp(join(tmpdir(), "axo-axod-relay-")));
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
  let remoteApi: RemoteAxoApi | undefined;
  try {
    daemon = spawn(axodBinary, ["--server-dir", serverDirectory, "--socket", socketPath], {
      stdio: "ignore",
      env: { ...process.env, HOME: root },
    });
    await new Promise<void>((resolveSpawn, rejectSpawn) => {
      daemon!.once("spawn", () => resolveSpawn());
      daemon!.once("error", rejectSpawn);
    });

    remoteApi = new RemoteAxoApi(
      api.url,
      async (input, init) => {
        const headers = new Headers(init?.headers);
        headers.set("Origin", "https://axo.leostera.dev");
        return fetch(input, { ...init, headers });
      },
      browserWebSocketFactory(),
    );
    const registered = await waitFor("axod host registration", 20_000, async () =>
      (await remoteApi!.listHosts()).find((host) => host.label === "Isolated axod test host"),
    daemon);
    assert.equal(registered.status, "online");
    assert.equal(registered.stale, false);
    const { hostId, hostGeneration } = registered;
    assert.ok(registered.sessions.length > 0, "axod must register its initial local session");
    const firstSession = registered.sessions[0];
    assert.ok(firstSession.shells.length > 0, "registered session has a shell");
    assert.equal(JSON.stringify(firstSession).match(/attachSocketPath|ptyDevice|terminalOutput/gi), null);

    client = await remoteApi.connectHost({ hostId, hostGeneration }, (event) => {
      liveEvents.push(event);
      if (event.type === "host.data" && event.event.type === "terminal.output") {
        outputChunks.push(Buffer.from(event.event.data, "base64").toString("utf8"));
      }
    });
    const initialPresence = await waitForHostEvent(
      liveEvents,
      (event) => event.type === "host.presence" && event.status === "online",
      "the app relay subscription",
      daemon,
    );
    assert.equal(initialPresence.type, "host.presence");

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
    const attachedEvent = await waitForHostEvent(
      liveEvents,
      (event) => event.type === "host.data" && event.event.type === "shell.activity" && event.event.activity === "attached",
      "the isolated local PTY attachment",
      attachment,
    );
    assert.equal(attachedEvent.type, "host.data");

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
    assert.match(outputChunks.join(""), new RegExp(terminalText));

    const createReply = await client.call("axo.remote.session.create", {
      target: { hostId, hostGeneration },
    });
    const created = createReply.session;
    assert.equal(created.hostId, hostId);
    const sessionsAfterCreate = await waitFor("the new session snapshot", 5_000, async () => {
      const current = await remoteApi!.listHostSessions({ hostId, hostGeneration });
      return current.some((session) => session.sessionId === created.sessionId)
        ? current
        : undefined;
    }, daemon);
    assert.ok(sessionsAfterCreate.some((session) => session.sessionId === created.sessionId));

    const directoryStorage = await api.mf.unsafeGetDurableObjectStorage("api-test", "AxoHostDirectory", {
      name: "private-fleet",
    });
    const storedSessions = await directoryStorage.exec<{ snapshot_json: string }>(
      "SELECT snapshot_json FROM host_sessions_v1 WHERE host_id = ?",
      hostId,
    );
    assert.equal(JSON.stringify(storedSessions).includes(terminalText), false);
    const databaseBytes = await readFile(join(serverDirectory, "axo.db")).catch(() => Buffer.alloc(0));
    assert.equal(databaseBytes.includes(Buffer.from(terminalText)), false);

    const hostOffline = terminate(daemon);
    await hostOffline;
    const offlineHost = await waitFor("the persisted offline host metadata", 5_000, async () => {
      const host = (await remoteApi!.listHosts()).find((item) => item.hostId === hostId);
      return host?.status === "offline" ? host : undefined;
    });
    assert.equal(offlineHost.stale, true);
    assert.ok(offlineHost.sessions.some((session) => session.sessionId === created.sessionId));
  } finally {
    if (client) client.close();
    if (attachment) await terminate(attachment, true);
    if (daemon) await terminate(daemon);
    await api.close();
    await rm(root, { recursive: true, force: true });
  }
});
