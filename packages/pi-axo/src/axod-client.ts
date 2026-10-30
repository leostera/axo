import { createConnection } from "node:net";

/** Axod refused or failed a call; `message` is written for people. */
export class AxodCallError extends Error {
  readonly code: number | null;

  constructor(message: string, code: number | null) {
    super(message);
    this.name = "AxodCallError";
    this.code = code;
  }
}

/**
 * One JSON-RPC call to Axod over its local socket (`AXO_SOCKET`): newline-delimited JSON, one
 * request and its reply per connection.
 */
export function callAxod(socketPath: string, method: string, params: unknown, timeoutMs: number): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(socketPath);
    let buffered = "";
    let settled = false;
    const settle = (outcome: () => void) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      outcome();
    };
    socket.setTimeout(timeoutMs, () =>
      settle(() => reject(new AxodCallError(`Axo did not answer within ${Math.round(timeoutMs / 1000)} seconds`, null))));
    socket.on("error", error => settle(() => reject(new AxodCallError(`Could not reach Axo: ${error.message}`, null))));
    socket.on("close", () => settle(() => reject(new AxodCallError("Axo closed the connection without answering", null))));
    socket.on("connect", () => socket.write(`${JSON.stringify({ jsonrpc: "2.0", id: 1, method, params })}\n`));
    socket.on("data", chunk => {
      buffered += chunk.toString("utf8");
      const newline = buffered.indexOf("\n");
      if (newline < 0) return;
      settle(() => {
        let reply: { result?: unknown; error?: { code?: unknown; message?: unknown } };
        try {
          reply = JSON.parse(buffered.slice(0, newline));
        } catch {
          reject(new AxodCallError("Axo sent a malformed reply", null));
          return;
        }
        if (reply.error) {
          const message = typeof reply.error.message === "string" ? reply.error.message : "Axo refused the request";
          reject(new AxodCallError(message, typeof reply.error.code === "number" ? reply.error.code : null));
        } else resolve(reply.result);
      });
    });
  });
}
