import { standardToken, type OAuthProvider } from "./provider";

/**
 * GitHub as an OAuth provider: an OAuth app (not a GitHub App) with expiring user tokens on, so an
 * access token lives eight hours and each renewal spends the refresh token for a new one. PKCE is
 * supported. The token endpoint answers JSON only when asked, and refuses with HTTP 200 and
 * `{ error }`.
 */

const TIMEOUT_MS = 15_000;
// GitHub refuses API requests without a User-Agent.
const API_HEADERS = { "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "Axo", Accept: "application/vnd.github+json" };

export const githubProvider: OAuthProvider = {
  name: "github",
  title: "GitHub",
  authorizeUrl: "https://github.com/login/oauth/authorize",
  tokenUrl: "https://github.com/login/oauth/access_token",
  consoleUrl: "https://github.com/settings/developers",
  scopeSeparator: " ",
  // A choice of account, so a second one can be added.
  authorizeParams: { prompt: "select_account" },
  pkce: true,
  tokenAuth: "body",
  tokenParams: {},
  parseToken: (json) => standardToken(json, "GitHub"),
  rotatesRefreshTokens: true,
  async identify(_grant, api) {
    const me = (await api.request("GET", "/user", { headers: API_HEADERS, accept: API_HEADERS.Accept })) as { login?: unknown };
    return typeof me.login === "string" ? me.login : null;
  },
  /** Deletes the person's authorization of the OAuth app, and every token of it. */
  async revoke(grant, client, fetcher) {
    const response = await fetcher(`https://api.github.com/applications/${encodeURIComponent(client.clientId)}/grant`, {
      method: "DELETE",
      headers: { ...API_HEADERS, Authorization: `Basic ${btoa(`${client.clientId}:${client.clientSecret}`)}`, "Content-Type": "application/json" },
      body: JSON.stringify({ access_token: grant.accessToken }),
      redirect: "manual",
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    await response.body?.cancel();
  },
};
