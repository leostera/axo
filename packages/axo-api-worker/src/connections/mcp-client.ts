import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { ErrorCode, McpError as SdkMcpError } from "@modelcontextprotocol/sdk/types.js";
import { CfWorkerJsonSchemaValidator } from "@modelcontextprotocol/sdk/validation/cfworker-provider.js";
import { z } from "zod";

/**
 * The MCP client for a third-party connection: the official MCP SDK's client over streamable
 * HTTP, which negotiates the protocol version, keeps the server's session and reads answers sent
 * as JSON or as an SSE stream. What is Axo's is the `fetch` it is given, which:
 *
 * - puts the account's bearer token on every request, and reports a 401 with the server's
 *   `WWW-Authenticate` header (McpAuthRequired) so the caller can start sign-in;
 * - follows no redirect: a server that moved is reached at its new URL only if added again;
 * - refuses an answer larger than MAX_RESPONSE_BYTES rather than buffer it;
 * - reports a request that may have reached the server but got no answer (McpOutcomeUnknown);
 * - answers the SDK's long-lived GET for server notifications with 405, which the SDK reads as
 *   the server having none: the account's Durable Object holds no stream open per server.
 *
 * Tool lists and results are read as the server sent them, not checked against the SDK's
 * schemas, so a server a little out of the spec still works; toolOutput reads what it can.
 */

const REQUEST_TIMEOUT_MS = 60_000;
/** A tool list or result larger than this is refused rather than buffered. */
const MAX_RESPONSE_BYTES = 4 * 1_048_576;
const MAX_TOOL_PAGES = 10;

export type UpstreamTool = { name: string; title?: string; description?: string; inputSchema?: Record<string, unknown> };

export class McpAuthRequired extends Error {
  constructor(readonly wwwAuthenticate: string | null) {
    super("the server requires sign-in");
  }
}

/** The request went out and its outcome is unknown: the server may have acted. */
export class McpOutcomeUnknown extends Error {}

export class McpError extends Error {
  constructor(readonly code: number, message: string) {
    super(message);
  }
}

/** `icons` are the srcs of the icons the server named for itself in `initialize`, if any. */
export type McpSession = { url: string; token: string | null; client: Client; icons?: string[] };

/** Any JSON-RPC result, as the server sent it. */
const anyResult = z.looseObject({});

export async function initialize(url: string, token: string | null, fetcher: typeof fetch = fetch): Promise<McpSession> {
  const client = new Client({ name: "Axo", version: "1" }, { capabilities: {}, jsonSchemaValidator: new CfWorkerJsonSchemaValidator() });
  const transport = new StreamableHTTPClientTransport(new URL(url), { fetch: guarded(token, fetcher) });
  await sdk("initialize", () => client.connect(transport, { timeout: REQUEST_TIMEOUT_MS }));
  const icons = (client.getServerVersion() as { icons?: Array<{ src?: unknown }> } | undefined)?.icons;
  return {
    url,
    token,
    client,
    icons: Array.isArray(icons) ? icons.flatMap((icon) => (typeof icon?.src === "string" ? [icon.src] : [])).slice(0, 8) : [],
  };
}

export async function listTools(session: McpSession, _fetcher?: typeof fetch): Promise<UpstreamTool[]> {
  const tools: UpstreamTool[] = [];
  let cursor: string | undefined;
  for (let page = 0; page < MAX_TOOL_PAGES; page++) {
    const result = (await request(session, "tools/list", cursor ? { cursor } : {})) as { tools?: UpstreamTool[]; nextCursor?: string };
    for (const tool of Array.isArray(result.tools) ? result.tools : []) if (typeof tool?.name === "string") tools.push(tool);
    cursor = typeof result.nextCursor === "string" ? result.nextCursor : undefined;
    if (!cursor) break;
  }
  return tools;
}

export async function callTool(session: McpSession, name: string, input: unknown, _fetcher?: typeof fetch): Promise<unknown> {
  return request(session, "tools/call", { name, arguments: input ?? {} });
}

function request(session: McpSession, method: string, params: Record<string, unknown>): Promise<unknown> {
  return sdk(method, () => session.client.request({ method, params } as never, anyResult, { timeout: REQUEST_TIMEOUT_MS }));
}

/**
 * Runs one SDK call, with its failures as this file's errors: the guarded fetch's own pass
 * through, a JSON-RPC error is the server's (McpError), and a request that timed out waiting
 * for its answer may have run.
 */
async function sdk<T>(method: string, call: () => Promise<T>): Promise<T> {
  try {
    return await call();
  } catch (error) {
    if (error instanceof McpAuthRequired || error instanceof McpOutcomeUnknown || error instanceof McpError) throw error;
    if (error instanceof SdkMcpError) {
      if (error.code === ErrorCode.RequestTimeout) throw new McpOutcomeUnknown(`${method}: the server sent no response`);
      throw new McpError(error.code, error.message.replace(/^MCP error -?\d+: /, ""));
    }
    throw new McpError(-32603, `${method}: ${error instanceof Error ? error.message : String(error)}`.slice(0, 512));
  }
}

/** The SDK's fetch: Axo's credential, limits and outcomes on every request it makes. */
function guarded(token: string | null, fetcher: typeof fetch): typeof fetch {
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    const method = (init?.method ?? "GET").toUpperCase();
    // No stream of server notifications is held open (see above).
    if (method === "GET") return new Response(null, { status: 405 });
    const headers = new Headers(init?.headers);
    if (token) headers.set("Authorization", `Bearer ${token}`);
    const message = method === "POST" && typeof init?.body === "string" ? parseMessage(init.body) : null;
    const label = message?.method ?? method;
    const sent = message?.id !== undefined;
    let response: Response;
    try {
      response = await fetcher(input, { ...init, headers, redirect: "manual", signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
    } catch (error) {
      // Ending a session, or a notification, that failed changes nothing the caller relies on.
      if (!sent) throw new McpError(-32603, `${label}: ${error instanceof Error ? error.message : "the request failed"}`);
      // A request that may have reached the server is not known to have failed.
      throw new McpOutcomeUnknown(`${label}: ${error instanceof Error ? error.message : "the request failed"}`);
    }
    if (response.status >= 300 && response.status < 400) {
      await response.body?.cancel();
      throw new McpError(-32603, `${label}: the server redirected (HTTP ${response.status}); add it at its new URL`);
    }
    if (response.status === 401) {
      await response.body?.cancel();
      throw new McpAuthRequired(response.headers.get("WWW-Authenticate"));
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw new McpError(-32603, `${label}: HTTP ${response.status}`);
    }
    if (response.status === 202 || !sent) return response;
    const bytes = await bounded(response);
    // A stream that ended without the request's answer would leave the SDK waiting until its timeout.
    if ((response.headers.get("Content-Type") ?? "").includes("text/event-stream") && !answers(new TextDecoder().decode(bytes), message!.id!)) {
      throw new McpOutcomeUnknown(`${label}: the server sent no response`);
    }
    return new Response(bytes, { status: response.status, headers: response.headers });
  }) as typeof fetch;
}

function parseMessage(body: string): { id?: number | string; method?: string } | null {
  try {
    const message = JSON.parse(body) as { id?: number | string; method?: string };
    return typeof message === "object" && message ? message : null;
  } catch {
    return null;
  }
}

/** Whether the stream's `message` events carry the answer with id `id`. */
function answers(text: string, id: number | string): boolean {
  for (const event of text.split(/\r?\n\r?\n/)) {
    const data = event.split(/\r?\n/).filter((line) => line.startsWith("data:")).map((line) => line.slice(5).replace(/^ /, "")).join("\n");
    if (!data) continue;
    try {
      const parsed = JSON.parse(data) as { id?: unknown } | Array<{ id?: unknown }>;
      if ((Array.isArray(parsed) ? parsed : [parsed]).some((m) => m?.id === id)) return true;
    } catch {
      // A malformed event is skipped; the answer may follow.
    }
  }
  return false;
}

async function bounded(response: Response): Promise<Uint8Array<ArrayBuffer>> {
  const reader = response.body?.getReader();
  if (!reader) return new Uint8Array(0);
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_RESPONSE_BYTES) {
      await reader.cancel();
      throw new McpError(-32603, `the server's response is larger than ${MAX_RESPONSE_BYTES} bytes`);
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

/** What a script gets back from a tool: its structured content, its text, or its content blocks. */
export function toolOutput(result: unknown): unknown {
  const r = (result ?? {}) as { isError?: boolean; structuredContent?: unknown; content?: Array<{ type?: string; text?: string }> };
  const texts = (r.content ?? []).filter((block) => block?.type === "text" && typeof block.text === "string").map((block) => block.text!);
  if (r.isError) throw new Error(texts.join("\n").slice(0, 4096) || "the tool failed");
  if (r.structuredContent !== undefined) return r.structuredContent;
  if (texts.length === 1 && (r.content ?? []).length === 1) {
    try {
      return JSON.parse(texts[0]!);
    } catch {
      return texts[0];
    }
  }
  return r.content ?? null;
}
