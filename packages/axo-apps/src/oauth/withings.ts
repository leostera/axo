import { GrantRefused, OAuthError } from "../errors";
import type { OAuthProvider, TokenAnswer } from "./provider";

/**
 * Withings as an OAuth provider. Its token endpoint is an API action (`POST /v2/oauth2` with
 * `action=requesttoken`), takes the client in the form, has no PKCE, and answers HTTP 200 with
 * `{ status, body }`: any status but 0 is a refusal. Scopes are joined with commas. Refresh tokens
 * rotate. The answer names the account by its numeric user ID, which is the account's name here.
 */
export const withingsProvider: OAuthProvider = {
  name: "withings",
  title: "Withings",
  authorizeUrl: "https://account.withings.com/oauth2_user/authorize2",
  tokenUrl: "https://wbsapi.withings.net/v2/oauth2",
  consoleUrl: "https://developer.withings.com/dashboard/",
  scopeSeparator: ",",
  authorizeParams: {},
  pkce: false,
  tokenAuth: "body",
  tokenParams: { action: "requesttoken" },
  parseToken(json): TokenAnswer {
    const answer = (json ?? {}) as { status?: unknown; error?: unknown; body?: Record<string, unknown> };
    if (answer.status !== 0) throw new GrantRefused(`Withings refused: status ${String(answer.status).slice(0, 8)}${typeof answer.error === "string" ? ` (${answer.error.slice(0, 64)})` : ""}`);
    const body = answer.body ?? {};
    if (typeof body.access_token !== "string" || !body.access_token) throw new OAuthError("Withings returned no access token");
    const userId = typeof body.userid === "number" || typeof body.userid === "string" ? String(body.userid) : null;
    return {
      accessToken: body.access_token,
      refreshToken: typeof body.refresh_token === "string" ? body.refresh_token : undefined,
      expiresIn: typeof body.expires_in === "number" ? body.expires_in : undefined,
      scope: typeof body.scope === "string" ? body.scope : undefined,
      userId,
    };
  },
  rotatesRefreshTokens: true,
  identify: async (grant) => grant.userId ?? null,
};
