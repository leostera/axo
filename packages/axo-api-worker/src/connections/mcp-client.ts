/**
 * A minimal MCP client over streamable HTTP (MCP 2025-06-18), enough for a third-party
 * connection: initialize, list tools, call a tool. The server may answer a request with JSON or
 * with an SSE stream carrying the response; both are read here.
 *
 * Every request carries the account's bearer token when it has one. A 401 is reported with the
 * server's `WWW-Authenticate` header so the caller can start sign-in.
 */

export const MCP_PROTOCOL_VERSION = "2025-06-18";
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

export type McpSession = { url: string; token: string | null; sessionId: string | null };

type JsonRpcReply = { jsonrpc: "2.0"; id: number | string; result?: unknown; error?: { code: number; message: string } };

let nextId = 1;

export async function initialize(url: string, token: string | null, fetcher: typeof fetch = fetch): Promise<McpSession> {
  const session: McpSession = { url, token, sessionId: null };
  const { headers } = await post(session, {
    jsonrpc: "2.0",
    id: nextId++,
    method: "initialize",
    params: { protocolVersion: MCP_PROTOCOL_VERSION, capabilities: {}, clientInfo: { name: "Axo", version: "1" } },
  }, fetcher);
  session.sessionId = headers.get("Mcp-Session-Id");
  await post(session, { jsonrpc: "2.0", method: "notifications/initialized" }, fetcher);
  return session;
}

export async function listTools(session: McpSession, fetcher: typeof fetch = fetch): Promise<UpstreamTool[]> {
  const tools: UpstreamTool[] = [];
  let cursor: string | undefined;
  for (let page = 0; page < MAX_TOOL_PAGES; page++) {
    const result = (await request(session, "tools/list", cursor ? { cursor } : {}, fetcher)) as { tools?: UpstreamTool[]; nextCursor?: string };
    for (const tool of result.tools ?? []) if (typeof tool?.name === "string") tools.push(tool);
    cursor = result.nextCursor;
    if (!cursor) break;
  }
  return tools;
}

export async function callTool(session: McpSession, name: string, input: unknown, fetcher: typeof fetch = fetch): Promise<unknown> {
  return request(session, "tools/call", { name, arguments: input ?? {} }, fetcher);
}

async function request(session: McpSession, method: string, params: unknown, fetcher: typeof fetch): Promise<unknown> {
  const id = nextId++;
  const { reply } = await post(session, { jsonrpc: "2.0", id, method, params }, fetcher);
  if (!reply) throw new McpOutcomeUnknown(`${method}: the server sent no response`);
  if (reply.error) throw new McpError(reply.error.code, reply.error.message);
  return reply.result;
}

async function post(
  session: McpSession,
  message: { id?: number | string; method: string; jsonrpc: "2.0"; params?: unknown },
  fetcher: typeof fetch,
): Promise<{ reply: JsonRpcReply | null; headers: Headers }> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Accept: "application/json, text/event-stream",
    "MCP-Protocol-Version": MCP_PROTOCOL_VERSION,
  };
  if (session.token) headers.Authorization = `Bearer ${session.token}`;
  if (session.sessionId) headers["Mcp-Session-Id"] = session.sessionId;
  const sent = message.id !== undefined;
  let response: Response;
  try {
    response = await fetcher(session.url, {
      method: "POST",
      headers,
      body: JSON.stringify(message),
      redirect: "manual",
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  } catch (error) {
    // A request that may have reached the server is not known to have failed.
    throw new McpOutcomeUnknown(`${message.method}: ${error instanceof Error ? error.message : "the request failed"}`);
  }
  // Redirects are not followed: a server that moved is reached at its new URL only if re-added.
  if (response.status >= 300 && response.status < 400) {
    await response.body?.cancel();
    throw new McpError(-32603, `${message.method}: the server redirected (HTTP ${response.status}); add it at its new URL`);
  }
  if (response.status === 401) {
    await response.body?.cancel();
    throw new McpAuthRequired(response.headers.get("WWW-Authenticate"));
  }
  if (response.status === 202 || !sent) {
    await response.body?.cancel();
    if (!response.ok) throw new McpError(-32603, `${message.method}: HTTP ${response.status}`);
    return { reply: null, headers: response.headers };
  }
  if (!response.ok) {
    await response.body?.cancel();
    throw new McpError(-32603, `${message.method}: HTTP ${response.status}`);
  }
  const text = await boundedText(response);
  const type = response.headers.get("Content-Type") ?? "";
  const reply = type.includes("text/event-stream") ? fromEventStream(text, message.id!) : (JSON.parse(text) as JsonRpcReply);
  return { reply, headers: response.headers };
}

/** The response with id `id` among the stream's `message` events, or null. */
function fromEventStream(text: string, id: number | string): JsonRpcReply | null {
  for (const event of text.split(/\r?\n\r?\n/)) {
    const data = event.split(/\r?\n/).filter((line) => line.startsWith("data:")).map((line) => line.slice(5).replace(/^ /, "")).join("\n");
    if (!data) continue;
    try {
      const parsed = JSON.parse(data) as JsonRpcReply | JsonRpcReply[];
      for (const message of Array.isArray(parsed) ? parsed : [parsed]) if (message?.id === id) return message;
    } catch {
      // A malformed event is skipped; the response may follow.
    }
  }
  return null;
}

async function boundedText(response: Response): Promise<string> {
  const reader = response.body?.getReader();
  if (!reader) return "";
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
  return new TextDecoder().decode(bytes);
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
