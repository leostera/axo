import { spawn, type ChildProcess } from "node:child_process";
import { RemoteAxoApi, type AccountConnection, type AccountEvents, type ClientHost, type ClientRecord, type ClientSession, type WebSocketLike } from "@axo/app";
import WebSocket from "ws";
import { createConnection } from "node:net";


export const sleep = (milliseconds: number) =>
  new Promise((resolveSleep) => setTimeout(resolveSleep, milliseconds));

export async function waitFor<T>(
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

export async function terminate(child: ChildProcess, processGroup = false): Promise<void> {
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
export async function localCall(socketPath: string, method: string, params?: unknown, timeoutMs = 30_000): Promise<unknown> {
  return new Promise((resolveCall, rejectCall) => {
    const socket = createConnection(socketPath);
    let buffered = "";
    socket.setTimeout(timeoutMs, () => socket.destroy(new Error(`${method} timed out`)));
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

export function accountApi(url: string, account: { headers: Record<string, string> }): RemoteAxoApi {
  return new RemoteAxoApi(url, browserWebSocketFactory(account.headers));
}

type ListedHost = { hostId: string; hostGeneration: string; status: string; stale: boolean };

/** The account's hosts over HTTP, as the pairing screen reads them. */
export async function listHosts(url: string, account: { headers: Record<string, string> }): Promise<ListedHost[]> {
  const response = await fetch(new URL("api/v1/account/hosts", url), { headers: account.headers });
  if (!response.ok) throw new Error(`listing hosts failed (${response.status})`);
  return ((await response.json()) as { hosts: ListedHost[] }).hosts;
}

/**
 * The account's socket, with every notice it receives kept for a test to wait on, and each open
 * Session's records gathered in order.
 */
export class TestAccountClient {
  readonly records = new Map<string, ClientRecord[]>();
  readonly sessions = new Map<string, ClientSession>();
  hosts: ClientHost[] = [];
  readonly progress: Array<{ sessionId: string; slot: string; snapshot: unknown }> = [];
  closedBecause: string | undefined;
  connection!: AccountConnection;

  static async connect(url: string, account: { headers: Record<string, string> }, clientId = `test-${crypto.randomUUID().slice(0, 8)}`) {
    const client = new TestAccountClient();
    const events: AccountEvents = {
      hosts: (hosts) => { client.hosts = hosts; },
      sessions: (_hostId, sessions) => { for (const session of sessions) client.sessions.set(session.sessionId, session); },
      records: (sessionId, _epoch, records) => client.records.set(sessionId, [...(client.records.get(sessionId) ?? []), ...records]),
      progress: (sessionId, slot, snapshot) => client.progress.push({ sessionId, slot, snapshot }),
      reset: (sessionId, _epoch, keep) => client.records.set(sessionId, (client.records.get(sessionId) ?? []).filter((record) => record.cursor <= keep)),
      closed: (error) => { client.closedBecause = error.message; },
    };
    client.connection = await accountApi(url, account).connect(clientId, events);
    client.hosts = client.connection.hello.hosts;
    for (const session of client.connection.hello.sessions) client.sessions.set(session.sessionId, session);
    return client;
  }

  /** Opens a Session with its last records and gathers what follows. */
  async open(hostId: string, sessionId: string) {
    const opened = await this.connection.open({ hostId, sessionId, window: { last: 64 } });
    this.records.set(sessionId, opened.records);
    return opened;
  }

  /** The Pi entries of a Session gathered so far, parsed. */
  entries(sessionId: string): Array<{ type: string; message?: { role: string; content: unknown } }> {
    return (this.records.get(sessionId) ?? []).map((record) => JSON.parse(record.line));
  }

  close() { this.connection?.close(); }
}

export function browserWebSocketFactory(headers: Record<string, string>) {
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


/** A phone's answer key: `answer` signs each answer with it (RFD0029). */
export async function trustedDevice(_serverDirectory: string, name = "Leo's iPhone") {
  const { newDeviceKey, signAnswer } = await import("@axo/app");
  const key = await newDeviceKey();
  return {
    key,
    answer: async (
      connection: { resolveElicitation: (hostId: string, id: string, action: "accept" | "decline", device: { key: string; name: string; signature: string }, sealed?: { enc: string; ciphertext: string }) => Promise<void> },
      hostId: string, id: string, action: "accept" | "decline", sealed?: { enc: string; ciphertext: string },
    ) => connection.resolveElicitation(hostId, id, action, await signAnswer(key, name, id, action, sealed), sealed),
  };
}
