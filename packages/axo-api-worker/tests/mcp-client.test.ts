import assert from "node:assert/strict";
import { test } from "node:test";
import { callTool, initialize, listTools, McpAuthRequired, McpError, McpOutcomeUnknown } from "../src/connections/mcp-client";

/**
 * RFD0016, third-party connections: the MCP client is the official SDK's, with Axo's fetch around
 * it. These pin what that fetch adds: the credential, no held-open stream, no redirects, a bounded
 * answer, and which failures leave a call's outcome unknown.
 */

const URL_ = "https://mcp.example.com/mcp";
type Seen = { method: string; headers: Headers; body: { id?: number; method?: string; params?: unknown } | null };

function server(answer: (message: { id?: number; method?: string; params?: unknown }) => Response | null = () => null) {
  const seen: Seen[] = [];
  const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(input, init);
    const text = request.method === "POST" ? await request.text() : "";
    const body = text ? (JSON.parse(text) as { id?: number; method?: string; params?: unknown }) : null;
    seen.push({ method: request.method, headers: request.headers, body });
    if (request.method !== "POST" || !body) return new Response(null, { status: 405 });
    const custom = answer(body);
    if (custom) return custom;
    if (body.id === undefined) return new Response(null, { status: 202 });
    const json = (result: unknown, headers: Record<string, string> = {}) =>
      new Response(JSON.stringify({ jsonrpc: "2.0", id: body.id, result }), { headers: { "Content-Type": "application/json", ...headers } });
    if (body.method === "initialize") return json({ protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "fake", version: "1", icons: [{ src: "https://mcp.example.com/icon.png" }] } }, { "Mcp-Session-Id": "s-1" });
    // A tool without an input schema, as some servers send, is still listed.
    if (body.method === "tools/list") return json({ tools: [{ name: "search", inputSchema: { type: "object" } }, { name: "loose" }] });
    if (body.method === "tools/call" && (body.params as { name?: string }).name === "missing") {
      return new Response(JSON.stringify({ jsonrpc: "2.0", id: body.id, error: { code: -32602, message: "Unknown tool: missing" } }), { headers: { "Content-Type": "application/json" } });
    }
    if (body.method === "tools/call") return json({ content: [{ type: "text", text: "{\"ok\":true}" }] });
    return new Response(JSON.stringify({ jsonrpc: "2.0", id: body.id, error: { code: -32601, message: "Method not found" } }), { headers: { "Content-Type": "application/json" } });
  }) as typeof fetch;
  return { seen, fetcher };
}

test("a session negotiates the version, keeps the server's session and token on every request, and holds no stream open", async () => {
  const { seen, fetcher } = server();
  const session = await initialize(URL_, "token-1", fetcher);
  assert.deepEqual(session.icons, ["https://mcp.example.com/icon.png"]);
  assert.deepEqual((await listTools(session)).map((t) => t.name), ["search", "loose"]);
  assert.deepEqual(await callTool(session, "search", { q: "x" }), { content: [{ type: "text", text: "{\"ok\":true}" }] });
  const posts = seen.filter((s) => s.method === "POST");
  assert.deepEqual(posts.map((s) => s.body?.method), ["initialize", "notifications/initialized", "tools/list", "tools/call"]);
  assert.ok(posts.every((s) => s.headers.get("Authorization") === "Bearer token-1"));
  assert.ok(posts.slice(1).every((s) => s.headers.get("Mcp-Session-Id") === "s-1" && s.headers.get("MCP-Protocol-Version") === "2025-06-18"));
  // The SDK's GET for server notifications never leaves the Worker.
  assert.equal(seen.some((s) => s.method === "GET"), false);
});

test("a 401 asks for sign-in with the server's challenge, a redirect is refused, and a JSON-RPC error is the server's", async () => {
  const challenge = 'Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp"';
  const unauthorized = server(() => new Response(null, { status: 401, headers: { "WWW-Authenticate": challenge } }));
  const refused = await initialize(URL_, null, unauthorized.fetcher).then(() => null, (error: unknown) => error);
  assert.ok(refused instanceof McpAuthRequired);
  assert.equal(refused.wwwAuthenticate, challenge);

  const moved = server(() => new Response(null, { status: 307, headers: { Location: "https://elsewhere.example.com/mcp" } }));
  await assert.rejects(initialize(URL_, null, moved.fetcher), (error) => error instanceof McpError && /redirected \(HTTP 307\); add it at its new URL/.test(error.message));

  const session = await initialize(URL_, null, server().fetcher);
  await assert.rejects(callTool(session, "missing", {}), (error) => error instanceof McpError && error.code === -32602 && error.message === "Unknown tool: missing");
});

test("a request that may have reached the server without an answer is unknown, and an oversized answer is refused", async () => {
  // The connection drops once the call is sent.
  let drop = false;
  const flaky = server((message) => {
    if (drop && message.method === "tools/call") throw new TypeError("connection reset");
    return null;
  });
  const session = await initialize(URL_, null, flaky.fetcher);
  drop = true;
  await assert.rejects(callTool(session, "search", {}), McpOutcomeUnknown);

  // An SSE stream that ends without the call's answer does not wait for the timeout.
  const silent = server((message) => (message.method === "tools/call"
    ? new Response("event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n\n", { headers: { "Content-Type": "text/event-stream" } })
    : null));
  const quiet = await initialize(URL_, null, silent.fetcher);
  const started = Date.now();
  await assert.rejects(callTool(quiet, "search", {}), McpOutcomeUnknown);
  assert.ok(Date.now() - started < 5_000);

  const huge = server((message) => (message.method === "tools/list"
    ? new Response(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: { tools: [{ name: "x".repeat(5 * 1_048_576) }] } }), { headers: { "Content-Type": "application/json" } })
    : null));
  const big = await initialize(URL_, null, huge.fetcher);
  await assert.rejects(listTools(big), (error) => error instanceof McpError && /larger than/.test(error.message));
});
