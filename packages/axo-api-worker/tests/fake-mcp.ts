import { createHash, randomBytes } from "node:crypto";
import { Response as MiniflareResponse } from "miniflare";

/**
 * A remote MCP server that is also its own OAuth authorization server, as Linear's is: protected
 * resource metadata, authorization server metadata, dynamic client registration, PKCE, rotating
 * refresh tokens, and a streamable HTTP endpoint that answers tool calls over SSE.
 */
export class FakeMcp {
  readonly origin: string;
  readonly url: string;
  requireAuth = true;
  /** The icons the server names for itself in `initialize`, as MCP lets it. */
  serverIcons: Array<{ src: string; mimeType?: string }> = [];
  /** The service behind the server refuses it, as PayPal's does once its own sign-in lapses: tools answer a 401 as their error. */
  upstreamRefuses = false;
  /** Seconds an access token lives. */
  tokenLifetime = 3600;
  tools: Array<{ name: string; description: string; inputSchema: Record<string, unknown> }> = [
    { name: "list-issues", description: "Lists issues of a team.", inputSchema: { type: "object", properties: { team: { type: "string" } } } },
    { name: "create_issue", description: "Creates an issue.", inputSchema: { type: "object", properties: { title: { type: "string" } } } },
  ];
  readonly clients = new Set<string>();
  readonly calls: Array<{ tool: string; args: unknown; token: string | null }> = [];
  readonly tokenRequests: URLSearchParams[] = [];
  private readonly codes = new Map<string, { challenge: string; clientId: string; used: boolean }>();
  private readonly access = new Set<string>();
  private readonly refresh = new Set<string>();

  constructor(host = "mcp.example.test") {
    this.origin = `https://${host}`;
    this.url = `${this.origin}/mcp`;
  }

  /** The person approves on the provider's consent page: returns where the provider sends the browser. */
  approve(authorizeUrl: string): URL {
    const url = new URL(authorizeUrl);
    assert(url.origin === this.origin && url.pathname === "/authorize", `unexpected authorize URL ${authorizeUrl}`);
    assert(url.searchParams.get("code_challenge_method") === "S256", "PKCE is required");
    const code = randomBytes(12).toString("hex");
    this.codes.set(code, { challenge: url.searchParams.get("code_challenge")!, clientId: url.searchParams.get("client_id")!, used: false });
    const back = new URL(url.searchParams.get("redirect_uri")!);
    back.searchParams.set("code", code);
    back.searchParams.set("state", url.searchParams.get("state")!);
    return back;
  }

  async handle(request: Request): Promise<Response | undefined> {
    const url = new URL(request.url);
    if (url.origin !== this.origin) return undefined;
    const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
      new MiniflareResponse(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } }) as unknown as Response;
    if (url.pathname === "/.well-known/oauth-protected-resource/mcp")
      return json({ resource: this.url, authorization_servers: [this.origin], scopes_supported: ["read", "write"] });
    if (url.pathname === "/.well-known/oauth-authorization-server")
      return json({
        issuer: this.origin,
        authorization_endpoint: `${this.origin}/authorize`,
        token_endpoint: `${this.origin}/token`,
        registration_endpoint: `${this.origin}/register`,
        code_challenge_methods_supported: ["S256"],
      });
    if (url.pathname === "/register" && request.method === "POST") {
      const body = (await request.json()) as { redirect_uris: string[] };
      assert(body.redirect_uris.length === 1 && body.redirect_uris[0] === "https://axo.leostera.dev/api/v1/connections/oauth/callback", "one fixed callback");
      const clientId = `client-${randomBytes(6).toString("hex")}`;
      this.clients.add(clientId);
      return json({ client_id: clientId }, 201);
    }
    if (url.pathname === "/token" && request.method === "POST") {
      const form = new URLSearchParams(await request.text());
      this.tokenRequests.push(form);
      if (!this.clients.has(form.get("client_id") ?? "")) return json({ error: "invalid_client" }, 401);
      if (form.get("grant_type") === "authorization_code") {
        const grant = this.codes.get(form.get("code") ?? "");
        const challenge = createHash("sha256").update(form.get("code_verifier") ?? "").digest("base64url");
        if (!grant || grant.used || grant.challenge !== challenge || grant.clientId !== form.get("client_id")) return json({ error: "invalid_grant" }, 400);
        grant.used = true;
        return json(this.issue());
      }
      if (form.get("grant_type") === "refresh_token") {
        const token = form.get("refresh_token") ?? "";
        // Refresh tokens rotate: each works once.
        if (!this.refresh.delete(token)) return json({ error: "invalid_grant" }, 400);
        return json(this.issue());
      }
      return json({ error: "unsupported_grant_type" }, 400);
    }
    if (url.pathname === "/mcp" && request.method === "POST") {
      const token = /^Bearer (.+)$/.exec(request.headers.get("Authorization") ?? "")?.[1] ?? null;
      if (this.requireAuth && (!token || !this.access.has(token)))
        return json({ error: "unauthorized" }, 401, { "WWW-Authenticate": `Bearer resource_metadata="${this.origin}/.well-known/oauth-protected-resource/mcp"` });
      const message = (await request.json()) as { id?: number; method: string; params?: { name?: string; arguments?: unknown } };
      if (message.id === undefined) return new MiniflareResponse(null, { status: 202 }) as unknown as Response;
      if (message.method === "initialize")
        return json({ jsonrpc: "2.0", id: message.id, result: { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "fake", ...(this.serverIcons.length ? { icons: this.serverIcons } : {}) } } }, 200, { "Mcp-Session-Id": "s-1" });
      if (message.method === "tools/list") return json({ jsonrpc: "2.0", id: message.id, result: { tools: this.tools } });
      if (message.method === "tools/call") {
        this.calls.push({ tool: message.params!.name!, args: message.params!.arguments, token });
        const result = this.upstreamRefuses
          ? { isError: true, content: [{ type: "text", text: "Failed to fetch transactions: 401 Unauthorized" }] }
          : { content: [{ type: "text", text: JSON.stringify({ tool: message.params!.name, args: message.params!.arguments }) }] };
        // Answered as a stream, as many servers do.
        const body = `event: message\ndata: ${JSON.stringify({ jsonrpc: "2.0", id: message.id, result })}\n\n`;
        return new MiniflareResponse(body, { status: 200, headers: { "Content-Type": "text/event-stream" } }) as unknown as Response;
      }
      return json({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "Method not found" } });
    }
    return json({ error: "not found" }, 404);
  }

  /** Whether `text` contains any token this server issued. */
  leaks(text: string): boolean {
    return [...this.access, ...this.refresh].some((token) => text.includes(token));
  }

  private issue() {
    const access = `at-${randomBytes(12).toString("hex")}`;
    const refresh = `rt-${randomBytes(12).toString("hex")}`;
    this.access.add(access);
    this.refresh.add(refresh);
    return { access_token: access, refresh_token: refresh, token_type: "Bearer", expires_in: this.tokenLifetime };
  }
}

function assert(condition: boolean, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
