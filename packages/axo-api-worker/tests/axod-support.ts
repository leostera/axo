import { spawn, type ChildProcess } from "node:child_process";
import { RemoteAxoApi, type HostEvent, type WebSocketLike } from "@axo/app";
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
export async function localCall(socketPath: string, method: string, params?: unknown): Promise<unknown> {
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

export function accountApi(url: string, account: { headers: Record<string, string> }): RemoteAxoApi {
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

export async function waitForHostEvent(
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

