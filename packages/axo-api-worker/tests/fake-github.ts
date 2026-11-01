import { FakeOAuth, json } from "./fake-oauth";

/**
 * GitHub as the GitHub app sees it: an OAuth app with expiring user tokens (eight hours, and a
 * refresh token each renewal spends), PKCE, a token endpoint that answers JSON only when asked
 * and refuses with HTTP 200 and `{ error }`, grant revocation, and enough of the REST API.
 */
export class FakeGitHub {
  readonly oauth = new FakeOAuth({ authorizeUrl: "https://github.com/login/oauth/authorize", tokenAuth: "body", pkce: true, scopeSeparator: " ", rotates: true, answerSeparator: "," });
  readonly revoked: Array<{ authorization: string | null; accessToken: string }> = [];
  readonly apiCalls: Array<{ as: string; call: string; headers: Headers }> = [];

  constructor() {
    this.oauth.tokenLifetime = 28_800;
  }

  async handle(request: Request): Promise<Response | undefined> {
    const url = new URL(request.url);
    if (url.origin === "https://github.com" && url.pathname === "/login/oauth/access_token" && request.method === "POST") {
      const result = this.oauth.token(new URLSearchParams(await request.text()), request.headers);
      const answer = result.ok
        ? { access_token: result.accessToken, token_type: "bearer", scope: result.scope, expires_in: result.expiresIn, refresh_token: result.refreshToken, refresh_token_expires_in: 15_897_600 }
        : { error: result.error === "invalid_grant" ? "bad_verification_code" : result.error, error_description: "The code passed is incorrect or expired." };
      if (request.headers.get("accept") !== "application/json") return new Response(new URLSearchParams(Object.entries(answer).map(([k, v]) => [k, String(v)])).toString(), { status: 200 });
      return json(answer);
    }
    if (url.origin !== "https://api.github.com") return undefined;
    const grant = /^\/applications\/([^/]+)\/grant$/.exec(url.pathname);
    if (grant && request.method === "DELETE") {
      this.revoked.push({ authorization: request.headers.get("authorization"), accessToken: ((await request.json()) as { access_token: string }).access_token });
      return new Response(null, { status: 204 });
    }
    // As GitHub does: plain text, not its usual JSON.
    if (!request.headers.get("User-Agent")) return new Response("Request forbidden by administrative rules. Please make sure your request has a User-Agent header (https://docs.github.com/en/rest/overview/resources-in-the-rest-api#user-agent-required).\n", { status: 403, headers: { "Content-Type": "text/plain" } });
    const as = this.oauth.who(request);
    if (!as) return json({ message: "Bad credentials" }, 401);
    this.apiCalls.push({ as, call: `${request.method} ${url.pathname}`, headers: request.headers });
    if (url.pathname === "/user") return json({ login: as === "ada" ? "Ada" : as, name: as });
    if (url.pathname === "/repos/ada/engine/issues/3") return json({ number: 3, title: "Bug", state: "open", user: { login: "bob" }, labels: [{ name: "bug" }], comments: 1, created_at: "c", updated_at: "u", html_url: "https://github.com/ada/engine/issues/3", body: "It breaks" });
    if (url.pathname === "/repos/ada/engine/issues/3/comments") return json([{ user: { login: "ada" }, body: "On it", created_at: "d" }]);
    if (url.pathname === "/repos/ada/engine/contents/src/main.rs") return json({ type: "file", path: "src/main.rs", sha: "s", size: 12, encoding: "base64", content: btoa("fn main() {}") });
    if (url.pathname === "/repos/ada/archived") return new Response("<html><body><h1>Repository access blocked</h1></body></html>", { status: 451, headers: { "Content-Type": "text/html" } });
    if (url.pathname === "/repos/ada/engine") return json({ full_name: "ada/engine", stargazers_count: 7 });
    if (url.pathname === "/notifications") return json([{ id: "n1", reason: "mention", updated_at: "u", repository: { full_name: "ada/engine" }, subject: { type: "Issue", title: "Bug" } }]);
    return json({ message: "Not Found" }, 404);
  }
}
