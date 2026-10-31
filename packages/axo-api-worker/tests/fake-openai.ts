import { randomBytes } from "node:crypto";

/**
 * OpenAI as the ChatGPT app sees it: the Codex CLI's device sign-in at auth.openai.com (a user
 * code, polling until the person enters it, then a code and PKCE verifier to redeem), refresh
 * tokens that rotate (a spent one is refused), and the Codex backend at chatgpt.com: streamed
 * Responses, models and usage, each needing the access token and the ChatGPT account ID.
 */
export class FakeOpenAI {
  readonly clientId = "app_EMoamEEZ73f0CkXaXp7hrann";
  tokenLifetime = 3600;
  readonly revoked: string[] = [];
  readonly responses: Array<{ body: Record<string, unknown>; headers: Headers }> = [];
  private readonly devices = new Map<string, { userCode: string; approvedBy: { email: string; accountId: string } | null; declined: boolean; redeemed: boolean }>();
  private readonly codes = new Map<string, { verifier: string; email: string; accountId: string; used: boolean }>();
  private readonly access = new Map<string, { email: string; accountId: string }>();
  private readonly refresh = new Map<string, { email: string; accountId: string; spent: boolean }>();

  /** The person enters the code at auth.openai.com/codex/device, signed in as `email`. */
  approve(userCode: string, email = "ada@example.com", accountId = "acct-ada"): void {
    const device = [...this.devices.values()].find((d) => d.userCode === userCode);
    if (!device) throw new Error(`no device code ${userCode}`);
    device.approvedBy = { email, accountId };
  }

  decline(userCode: string): void {
    const device = [...this.devices.values()].find((d) => d.userCode === userCode);
    if (device) device.declined = true;
  }

  expireAccessTokens(): void {
    this.access.clear();
  }

  leaks(text: string): boolean {
    return [...this.access.keys(), ...this.refresh.keys()].some((secret) => text.includes(secret));
  }

  async handle(request: Request): Promise<Response | undefined> {
    const url = new URL(request.url);
    if (url.origin === "https://auth.openai.com") return this.auth(request, url);
    if (url.origin === "https://chatgpt.com") return this.chatgpt(request, url);
    return undefined;
  }

  private async auth(request: Request, url: URL): Promise<Response> {
    if (url.pathname === "/api/accounts/deviceauth/usercode") {
      const { client_id } = (await request.json()) as { client_id: string };
      if (client_id !== this.clientId) return json({ error: "unknown client" }, 400);
      const id = `dev-${randomBytes(6).toString("hex")}`;
      const userCode = `${randomBytes(2).toString("hex").toUpperCase()}-${randomBytes(2).toString("hex").toUpperCase()}`;
      this.devices.set(id, { userCode, approvedBy: null, declined: false, redeemed: false });
      return json({ device_auth_id: id, user_code: userCode, interval: "5", expires_at: new Date(Date.now() + 900_000).toISOString() });
    }
    if (url.pathname === "/api/accounts/deviceauth/token") {
      const { device_auth_id, user_code } = (await request.json()) as { device_auth_id: string; user_code: string };
      const device = this.devices.get(device_auth_id);
      if (!device || device.userCode !== user_code) return json({ error: { code: "invalid_request" } }, 400);
      if (device.declined) return json({ error: { code: "access_denied" } }, 400);
      if (!device.approvedBy || device.redeemed) return json({ error: { code: "deviceauth_authorization_pending" } }, 403);
      device.redeemed = true;
      const code = randomBytes(8).toString("hex");
      const verifier = randomBytes(16).toString("hex");
      this.codes.set(code, { verifier, ...device.approvedBy, used: false });
      return json({ authorization_code: code, code_challenge: "unused", code_verifier: verifier });
    }
    if (url.pathname === "/oauth/token") {
      const form = new URLSearchParams(await request.text());
      if (form.get("client_id") !== this.clientId) return json({ error: "invalid_client" }, 401);
      if (form.get("grant_type") === "authorization_code") {
        const code = this.codes.get(form.get("code") ?? "");
        if (!code || code.used || code.verifier !== form.get("code_verifier") || form.get("redirect_uri") !== "https://auth.openai.com/deviceauth/callback")
          return json({ error: "invalid_grant" }, 400);
        code.used = true;
        return this.issue(code.email, code.accountId, true);
      }
      if (form.get("grant_type") === "refresh_token") {
        const grant = this.refresh.get(form.get("refresh_token") ?? "");
        if (!grant || grant.spent) return json({ error: { code: "refresh_token_reused" } }, 401);
        grant.spent = true;
        return this.issue(grant.email, grant.accountId, false);
      }
      return json({ error: "unsupported_grant_type" }, 400);
    }
    if (url.pathname === "/oauth/revoke") {
      this.revoked.push(new URLSearchParams(await request.text()).get("token") ?? "");
      return json({});
    }
    return json({ error: "not found" }, 404);
  }

  private issue(email: string, accountId: string, withIdToken: boolean): Response {
    const access = `at-${randomBytes(8).toString("hex")}`;
    const refresh = `rt-${randomBytes(8).toString("hex")}`;
    this.access.set(access, { email, accountId });
    this.refresh.set(refresh, { email, accountId, spent: false });
    const claims = { email, "https://api.openai.com/auth": { chatgpt_account_id: accountId, chatgpt_plan_type: "pro" } };
    return json({ access_token: access, refresh_token: refresh, expires_in: this.tokenLifetime, ...(withIdToken ? { id_token: jwt(claims) } : {}) });
  }

  private async chatgpt(request: Request, url: URL): Promise<Response> {
    const token = /^Bearer (.+)$/.exec(request.headers.get("Authorization") ?? "")?.[1];
    const who = token ? this.access.get(token) : undefined;
    if (!who) return json({ detail: "Unauthorized" }, 401);
    if (request.headers.get("chatgpt-account-id") !== who.accountId) return json({ detail: "wrong account" }, 403);
    if (url.pathname === "/backend-api/codex/models") return json({ models: [{ slug: "gpt-5.5", display_name: "GPT-5.5", description: "Frontier", supported_reasoning_levels: [{ effort: "low" }, { effort: "high" }] }] });
    if (url.pathname === "/backend-api/wham/usage") return json({ plan_type: "pro", rate_limit: { primary_window: { used_percent: 12 } } });
    if (url.pathname === "/backend-api/codex/responses" && request.method === "POST") {
      const body = (await request.json()) as Record<string, unknown>;
      this.responses.push({ body, headers: request.headers });
      if (body.store !== false || body.stream !== true) return json({ detail: "Store must be set to false" }, 400);
      if (body.model === "nope") return sse([{ type: "response.failed", response: { error: { message: "model not supported" } } }]);
      const input = body.input as Array<{ content: Array<{ text: string }> }>;
      const said = input.at(-1)!.content[0]!.text;
      const output = [
        { type: "reasoning", summary: [{ text: "Thinking about it" }] },
        { type: "message", role: "assistant", content: [{ type: "output_text", text: `You said: ${said}` }] },
      ];
      return sse([
        { type: "response.created", response: { id: "resp_1" } },
        { type: "response.output_text.delta", delta: "You said" },
        { type: "response.completed", response: { id: "resp_1", model: body.model, status: "completed", output, usage: { input_tokens: 5, output_tokens: 4 } } },
      ]);
    }
    return json({ detail: "not found" }, 404);
  }
}

function jwt(claims: unknown): string {
  const part = (value: unknown) => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${part({ alg: "RS256" })}.${part(claims)}.signature`;
}

function sse(events: unknown[]): Response {
  return new Response(events.map((e) => `event: ${(e as { type: string }).type}\ndata: ${JSON.stringify(e)}\n\n`).join(""), { headers: { "Content-Type": "text/event-stream" } });
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
}
