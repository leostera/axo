import { z } from "zod";
import { standardToken, type OAuthClient, type OAuthGrant, type OAuthProvider } from "./oauth-provider";

/**
 * Google as an OAuth provider, for the Google apps (Gmail, Calendar, Drive...): one Web
 * application client registered in Google Cloud, set on the Worker as `GOOGLE_CLIENT_ID` and
 * `GOOGLE_CLIENT_SECRET`. The account is named by the email in the ID token. Google does not
 * rotate refresh tokens.
 */

export const GOOGLE_REVOKE_URL = "https://oauth2.googleapis.com/revoke";
const ISSUERS = new Set(["https://accounts.google.com", "accounts.google.com"]);
const TIMEOUT_MS = 15_000;

export type GoogleClient = OAuthClient;
export type GoogleGrant = OAuthGrant;

const idTokenSchema = z.object({
  iss: z.string(),
  aud: z.string(),
  email: z.string().max(320).optional(),
  email_verified: z.boolean().optional(),
});

/** The client from the Worker's environment, or null when this deployment has none. */
export function googleClient(env: { GOOGLE_CLIENT_ID?: string; GOOGLE_CLIENT_SECRET?: string }): GoogleClient | null {
  if (!env.GOOGLE_CLIENT_ID || !env.GOOGLE_CLIENT_SECRET) return null;
  return { clientId: env.GOOGLE_CLIENT_ID, clientSecret: env.GOOGLE_CLIENT_SECRET };
}

export const googleProvider: OAuthProvider = {
  name: "google",
  title: "Google",
  authorizeUrl: "https://accounts.google.com/o/oauth2/v2/auth",
  tokenUrl: "https://oauth2.googleapis.com/token",
  env: { clientId: "GOOGLE_CLIENT_ID", clientSecret: "GOOGLE_CLIENT_SECRET" },
  scopeSeparator: " ",
  // A refresh token on every sign-in, so signing in again always replaces a spent grant; consent
  // every time (so Google returns one), and a choice of account (so a second one can be added).
  authorizeParams: { access_type: "offline", prompt: "consent select_account" },
  pkce: true,
  tokenAuth: "body",
  tokenParams: {},
  parseToken(json, client) {
    const answer = standardToken(json, "Google");
    const idToken = (json as { id_token?: unknown }).id_token;
    return { ...answer, email: typeof idToken === "string" ? emailOf(idToken, client) : undefined };
  },
  rotatesRefreshTokens: false,
  identify: async (grant) => grant.email,
  async revoke(grant, _client, fetcher) {
    const response = await fetcher(GOOGLE_REVOKE_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ token: grant.refreshToken ?? grant.accessToken }),
      redirect: "manual",
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    await response.body?.cancel();
  },
};

/**
 * The email in an ID token that came straight from Google's token endpoint over TLS, which is
 * enough to trust it without checking its signature (OpenID Connect Core 3.1.3.7). It is only
 * shown to the person; nothing is authorized by it.
 */
function emailOf(idToken: string, client: OAuthClient): string | null {
  try {
    const payload = idToken.split(".")[1] ?? "";
    const json = atob(payload.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(payload.length / 4) * 4, "="));
    const claims = idTokenSchema.parse(JSON.parse(new TextDecoder().decode(Uint8Array.from(json, (c) => c.charCodeAt(0)))));
    if (!ISSUERS.has(claims.iss) || claims.aud !== client.clientId) return null;
    return claims.email ?? null;
  } catch {
    return null;
  }
}
