import { createHash, randomBytes } from "node:crypto";
import { Response as MiniflareResponse } from "miniflare";

/**
 * Google as the Gmail app sees it: the OAuth consent page and token endpoint (PKCE, a client
 * secret, refresh tokens that do not rotate, an ID token with the account's email), revocation,
 * and enough of the Gmail REST API to read, search, label and send mail.
 */
export class FakeGoogle {
  readonly clientId = "google-client.apps.googleusercontent.com";
  readonly clientSecret = "GOCSPX-test-secret";
  /** Who signs in on the consent page next. */
  email = "ada@example.com";
  /** What the person allows on the consent page; by default everything asked for. */
  grantScopes: string[] | null = null;
  /** Seconds an access token lives. */
  tokenLifetime = 3600;
  /** The next send answers with this status instead of sending. */
  failNextSend: number | null = null;
  refuseRefresh = false;
  readonly tokenRequests: URLSearchParams[] = [];
  readonly revoked: string[] = [];
  readonly sent: Array<{ raw: string; threadId: string | null }> = [];
  readonly apiCalls: string[] = [];
  readonly messages = new Map<string, { threadId: string; labelIds: string[]; headers: Record<string, string>; text: string; snippet: string }>([
    ["m1", { threadId: "t1", labelIds: ["INBOX", "UNREAD"], headers: { From: "Grace <grace@example.com>", To: "ada@example.com", Subject: "Compilers", Date: "Fri, 30 Oct 2026 10:00:00 +0000", "Message-ID": "<m1@example.com>" }, text: "Shall we meet?", snippet: "Shall we meet?" }],
    ["m2", { threadId: "t2", labelIds: ["INBOX"], headers: { From: "news@example.com", To: "ada@example.com", Subject: "Weekly", Date: "Thu, 29 Oct 2026 10:00:00 +0000", "Message-ID": "<m2@example.com>" }, text: "", snippet: "Hello" }],
  ]);
  private readonly codes = new Map<string, { challenge: string; scopes: string[]; email: string; used: boolean }>();
  /** Access token → the account it acts as. */
  private readonly access = new Map<string, string>();
  private readonly refresh = new Map<string, { scopes: string[]; email: string }>();

  /** The person approves on Google's consent page: where Google sends the browser back. */
  approve(authorizeUrl: string): URL {
    const url = new URL(authorizeUrl);
    assert(url.origin === "https://accounts.google.com" && url.pathname === "/o/oauth2/v2/auth", `unexpected authorize URL ${authorizeUrl}`);
    assert(url.searchParams.get("client_id") === this.clientId, "Axo's Google client");
    assert(url.searchParams.get("code_challenge_method") === "S256", "PKCE is required");
    assert(url.searchParams.get("access_type") === "offline", "a refresh token is asked for");
    const asked = (url.searchParams.get("scope") ?? "").split(" ");
    const code = randomBytes(12).toString("hex");
    assert(url.searchParams.get("prompt")?.includes("select_account"), "the person may pick another account");
    this.codes.set(code, { challenge: url.searchParams.get("code_challenge")!, scopes: this.grantScopes ?? asked, email: this.email, used: false });
    const back = new URL(url.searchParams.get("redirect_uri")!);
    back.searchParams.set("code", code);
    back.searchParams.set("state", url.searchParams.get("state")!);
    return back;
  }

  /** Every access token stops working, as when Google revokes them; refresh tokens still work. */
  expireAccessTokens(): void {
    this.access.clear();
  }

  /** Whether `text` contains any token or the client secret. */
  leaks(text: string): boolean {
    return [...this.access.keys(), ...this.refresh.keys(), this.clientSecret].some((secret) => text.includes(secret));
  }

  async handle(request: Request): Promise<Response | undefined> {
    const url = new URL(request.url);
    if (url.origin === "https://oauth2.googleapis.com" && url.pathname === "/token") return this.token(request);
    if (url.origin === "https://oauth2.googleapis.com" && url.pathname === "/revoke") {
      this.revoked.push(new URLSearchParams(await request.text()).get("token") ?? "");
      return json({});
    }
    if (url.origin === "https://gmail.googleapis.com") return this.gmail(request, url);
    return undefined;
  }

  private async token(request: Request): Promise<Response> {
    const form = new URLSearchParams(await request.text());
    this.tokenRequests.push(form);
    if (form.get("client_id") !== this.clientId || form.get("client_secret") !== this.clientSecret) return json({ error: "invalid_client" }, 401);
    let scopes: string[];
    let email: string;
    let refreshToken: string | undefined;
    if (form.get("grant_type") === "authorization_code") {
      const code = this.codes.get(form.get("code") ?? "");
      if (!code || code.used || form.get("redirect_uri") !== "https://axo.leostera.dev/api/v1/connections/oauth/callback"
        || createHash("sha256").update(form.get("code_verifier") ?? "").digest("base64url") !== code.challenge) return json({ error: "invalid_grant" }, 400);
      code.used = true;
      scopes = code.scopes;
      email = code.email;
      refreshToken = randomBytes(16).toString("hex");
      this.refresh.set(refreshToken, { scopes, email });
    } else if (form.get("grant_type") === "refresh_token") {
      const known = this.refresh.get(form.get("refresh_token") ?? "");
      if (!known || this.refuseRefresh) return json({ error: "invalid_grant" }, 400);
      ({ scopes, email } = known);
    } else return json({ error: "unsupported_grant_type" }, 400);
    const accessToken = `ya29.${randomBytes(16).toString("hex")}`;
    this.access.set(accessToken, email);
    const claims = { iss: "https://accounts.google.com", aud: this.clientId, sub: email, email, email_verified: true };
    const idToken = `e30.${Buffer.from(JSON.stringify(claims)).toString("base64url")}.sig`;
    return json({
      access_token: accessToken,
      expires_in: this.tokenLifetime,
      scope: scopes.map((s) => (s === "email" ? "https://www.googleapis.com/auth/userinfo.email" : s)).join(" "),
      token_type: "Bearer",
      ...(refreshToken ? { refresh_token: refreshToken } : {}),
      ...(scopes.includes("openid") ? { id_token: idToken } : {}),
    });
  }

  private async gmail(request: Request, url: URL): Promise<Response> {
    const as = this.access.get(request.headers.get("authorization")?.replace("Bearer ", "") ?? "");
    if (!as) return json({ error: { code: 401, message: "Request had invalid authentication credentials." } }, 401);
    const path = url.pathname.replace("/gmail/v1/users/me", "");
    this.apiCalls.push(`${as} ${request.method} ${path}`);
    if (request.method === "GET" && path === "/profile") return json({ emailAddress: as, messagesTotal: this.messages.size, threadsTotal: 2, historyId: "1" });
    if (request.method === "GET" && path === "/labels") return json({ labels: [{ id: "INBOX", name: "INBOX", type: "system" }, { id: "Label_1", name: "Work", type: "user" }] });
    if (request.method === "GET" && path === "/messages") {
      const q = url.searchParams.get("q") ?? "";
      const ids = [...this.messages.entries()].filter(([, m]) => !q.includes("is:unread") || m.labelIds.includes("UNREAD")).map(([id, m]) => ({ id, threadId: m.threadId }));
      return json({ messages: ids.slice(0, Number(url.searchParams.get("maxResults") ?? 100)), resultSizeEstimate: ids.length });
    }
    if (request.method === "POST" && path === "/messages/send") {
      if (this.failNextSend) {
        const status = this.failNextSend;
        this.failNextSend = null;
        return json({ error: { code: status, message: "Backend Error" } }, status);
      }
      const body = (await request.json()) as { raw: string; threadId?: string };
      this.sent.push({ raw: Buffer.from(body.raw, "base64url").toString("utf8"), threadId: body.threadId ?? null });
      return json({ id: `sent${this.sent.length}`, threadId: body.threadId ?? `t-new${this.sent.length}`, labelIds: ["SENT"] });
    }
    const message = /^\/messages\/([^/]+)(\/modify|\/trash)?$/.exec(path);
    if (message) {
      const found = this.messages.get(message[1]!);
      if (!found) return json({ error: { code: 404, message: "Requested entity was not found." } }, 404);
      if (request.method === "DELETE") {
        this.messages.delete(message[1]!);
        return new MiniflareResponse(null, { status: 204 }) as unknown as Response;
      }
      if (request.method === "POST" && message[2] === "/modify") {
        const body = (await request.json()) as { addLabelIds: string[]; removeLabelIds: string[] };
        found.labelIds = [...new Set([...found.labelIds.filter((l) => !body.removeLabelIds.includes(l)), ...body.addLabelIds])];
      }
      const wanted = url.searchParams.getAll("metadataHeaders");
      const headers = Object.entries(found.headers).filter(([name]) => url.searchParams.get("format") !== "metadata" || wanted.includes(name)).map(([name, value]) => ({ name, value }));
      const payload = url.searchParams.get("format") === "full"
        ? { mimeType: "multipart/alternative", headers, parts: [
          { partId: "0", mimeType: "text/plain", headers: [{ name: "Content-Type", value: "text/plain; charset=UTF-8" }], body: { size: found.text.length, data: Buffer.from(found.text).toString("base64url") } },
          { partId: "1", mimeType: "text/html", headers: [], body: { size: 10, data: Buffer.from(`<p>${found.text || "Hello &amp; welcome"}</p>`).toString("base64url") } },
          { partId: "2", mimeType: "application/pdf", filename: "notes.pdf", headers: [], body: { size: 1234, attachmentId: "att1" } },
        ] }
        : { mimeType: "multipart/alternative", headers };
      return json({ id: message[1], threadId: found.threadId, labelIds: found.labelIds, snippet: found.snippet, payload });
    }
    if (request.method === "POST" && path === "/drafts") {
      const body = (await request.json()) as { message: { raw: string; threadId?: string } };
      return json({ id: "d1", message: { id: "m-draft", threadId: body.message.threadId ?? "t-draft", labelIds: ["DRAFT"] } });
    }
    return json({ error: { code: 404, message: `no route ${request.method} ${path}` } }, 404);
  }
}

function json(value: unknown, status = 200): Response {
  return new MiniflareResponse(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } }) as unknown as Response;
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
