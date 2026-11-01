import { createHash, randomBytes } from "node:crypto";

/**
 * The OAuth half of a fake provider (GitHub, Spotify, Withings): its consent page, which checks
 * what Axo sends the browser with, and its token endpoint's logic, which issues codes once,
 * checks PKCE and the client, and renews grants, spending the refresh token when it rotates. Each
 * fake wraps it in its provider's own answers and API.
 */

export type FakeOAuthOptions = {
  authorizeUrl: string;
  tokenAuth: "basic" | "body";
  pkce: boolean;
  scopeSeparator: " " | ",";
  rotates: boolean;
  /** How the token answer lists the scopes granted. */
  answerSeparator: " " | ",";
};

export type TokenResult =
  | { ok: true; accessToken: string; refreshToken: string; expiresIn: number; scope: string; person: string }
  | { ok: false; status: number; error: string };

const CALLBACK = "https://axo.leostera.dev/api/v1/connections/oauth/callback";

export class FakeOAuth {
  readonly clientId = `client-${randomBytes(4).toString("hex")}`;
  readonly clientSecret = `secret-${randomBytes(12).toString("hex")}`;
  /** Who signs in on the consent page next. */
  person = "ada";
  /** What the person allows; by default everything asked for. */
  grantScopes: string[] | null = null;
  /** Seconds an access token lives. */
  tokenLifetime = 3600;
  refuseRefresh = false;
  /** The next token request gets no answer (the connection drops). */
  dropNextToken = false;
  readonly tokenRequests: Array<{ form: URLSearchParams; headers: Headers }> = [];
  readonly authorizeUrls: URL[] = [];
  private readonly codes = new Map<string, { challenge: string | null; scopes: string[]; person: string; used: boolean }>();
  /** Access token → the person it acts as. */
  private readonly access = new Map<string, string>();
  private readonly refresh = new Map<string, { scopes: string[]; person: string }>();

  constructor(private readonly options: FakeOAuthOptions) {}

  /** The person approves on the consent page: where the provider sends the browser back. */
  approve(authorizeUrl: string): URL {
    const url = new URL(authorizeUrl);
    this.authorizeUrls.push(url);
    const expected = new URL(this.options.authorizeUrl);
    assert(url.origin === expected.origin && url.pathname === expected.pathname, `unexpected authorize URL ${authorizeUrl}`);
    assert(url.searchParams.get("response_type") === "code", "the code flow");
    assert(url.searchParams.get("client_id") === this.clientId, "Axo's client");
    assert(url.searchParams.get("redirect_uri") === CALLBACK, "the registered redirect URI");
    assert(url.searchParams.get("state"), "a state");
    if (this.options.pkce) assert(url.searchParams.get("code_challenge_method") === "S256", "PKCE");
    else assert(!url.searchParams.has("code_challenge"), "no PKCE where the provider has none");
    const asked = (url.searchParams.get("scope") ?? "").split(this.options.scopeSeparator).filter(Boolean);
    const code = randomBytes(12).toString("hex");
    this.codes.set(code, { challenge: url.searchParams.get("code_challenge"), scopes: this.grantScopes ?? asked, person: this.person, used: false });
    const back = new URL(CALLBACK);
    back.searchParams.set("code", code);
    back.searchParams.set("state", url.searchParams.get("state")!);
    return back;
  }

  /** The person an access token acts as, from a request's `Authorization: Bearer`. */
  who(request: Request): string | undefined {
    return this.access.get(request.headers.get("authorization")?.replace(/^Bearer /, "") ?? "");
  }

  /** Every access token stops working; refresh tokens still work. */
  expireAccessTokens(): void {
    this.access.clear();
  }

  /** Whether `text` contains any token or the client secret. */
  leaks(text: string): boolean {
    return [...this.access.keys(), ...this.refresh.keys(), this.clientSecret].some((secret) => text.includes(secret));
  }

  /** Whether a refresh token still works. */
  refreshable(token: string): boolean {
    return this.refresh.has(token);
  }

  /** The token endpoint's logic, for a form already read. */
  token(form: URLSearchParams, headers: Headers): TokenResult {
    this.tokenRequests.push({ form, headers });
    if (this.dropNextToken) {
      this.dropNextToken = false;
      throw new TypeError("connection reset");
    }
    const [id, secret] = this.options.tokenAuth === "basic"
      // Each half form-encoded, as RFC 6749 2.3.1 says.
      ? Buffer.from((headers.get("authorization") ?? "").replace(/^Basic /, ""), "base64").toString().split(":").map((half) => decodeURIComponent(half.replace(/\+/g, " ")))
      : [form.get("client_id"), form.get("client_secret")];
    if (id !== this.clientId || secret !== this.clientSecret) return { ok: false, status: 401, error: "invalid_client" };
    let scopes: string[];
    let person: string;
    if (form.get("grant_type") === "authorization_code") {
      const code = this.codes.get(form.get("code") ?? "");
      if (!code || code.used || form.get("redirect_uri") !== CALLBACK) return { ok: false, status: 400, error: "invalid_grant" };
      if (this.options.pkce && createHash("sha256").update(form.get("code_verifier") ?? "").digest("base64url") !== code.challenge) return { ok: false, status: 400, error: "invalid_grant" };
      if (!this.options.pkce && form.has("code_verifier")) return { ok: false, status: 400, error: "invalid_request" };
      code.used = true;
      ({ scopes, person } = code);
    } else if (form.get("grant_type") === "refresh_token") {
      const known = this.refresh.get(form.get("refresh_token") ?? "");
      if (!known || this.refuseRefresh) return { ok: false, status: 400, error: "invalid_grant" };
      ({ scopes, person } = known);
      if (this.options.rotates) this.refresh.delete(form.get("refresh_token")!);
    } else return { ok: false, status: 400, error: "unsupported_grant_type" };
    const accessToken = `at-${randomBytes(16).toString("hex")}`;
    this.access.set(accessToken, person);
    const refreshToken = this.options.rotates || form.get("grant_type") === "authorization_code" ? `rt-${randomBytes(16).toString("hex")}` : form.get("refresh_token")!;
    this.refresh.set(refreshToken, { scopes, person });
    return { ok: true, accessToken, refreshToken, expiresIn: this.tokenLifetime, scope: scopes.join(this.options.answerSeparator), person };
  }
}

export function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
}

export function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
