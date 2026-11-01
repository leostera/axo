import { jsonResponse, type OAuthProvider } from "./provider";

/**
 * Withings as an OAuth provider. Its token endpoint is an API action (`POST /v2/oauth2` with
 * `action=requesttoken`), takes the client in the form, has no PKCE, and answers HTTP 200 with
 * `{ status, body }`: any status but 0 is a refusal. Scopes are joined with commas. Refresh tokens
 * rotate. The answer names the account by its numeric user ID, which is the account's name here.
 */
export const withingsProvider: OAuthProvider = {
  name: "withings",
  title: "Withings",
  issuer: "https://account.withings.com",
  authorizeUrl: "https://account.withings.com/oauth2_user/authorize2",
  tokenUrl: "https://wbsapi.withings.net/v2/oauth2",
  consoleUrl: "https://developer.withings.com/dashboard/",
  scopeSeparator: ",",
  authorizeParams: {},
  pkce: false,
  tokenAuth: "body",
  tokenParams: { action: "requesttoken" },
  // `{ status: 0, body }` is the standard answer, with `userid`; any other status, a refusal.
  async adaptTokenResponse(response) {
    if (response.status !== 200) return response;
    const answer = (await response.json().catch(() => null)) as { status?: unknown; error?: unknown; body?: Record<string, unknown> } | null;
    if (answer?.status === 0 && answer.body) return jsonResponse({ token_type: "Bearer", ...answer.body }, 200);
    return jsonResponse({ error: `status_${String(answer?.status).slice(0, 8)}`, error_description: typeof answer?.error === "string" ? answer.error.slice(0, 256) : undefined }, 400);
  },
  rotatesRefreshTokens: true,
  identify: async (grant) => grant.userId ?? null,
};
