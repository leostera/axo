import { z } from "zod";
import { CALLBACK_URL, GrantRefused, OAuthError } from "../oauth";

/**
 * Axo as a Google OAuth client, for apps whose provider is Google (Gmail). Unlike a third-party
 * connection, the client is Axo's own: one Web application client registered in Google Cloud,
 * whose ID and secret are set on the Worker (`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`). It
 * uses the same callback as every other connection sign-in, so a sign-in lands through the same
 * flow cookie and sealed state checks (specs/connection-sign-in.ts).
 */

export const GOOGLE_AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth";
export const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
export const GOOGLE_REVOKE_URL = "https://oauth2.googleapis.com/revoke";
const ISSUERS = new Set(["https://accounts.google.com", "accounts.google.com"]);
const TIMEOUT_MS = 15_000;

export type GoogleClient = { clientId: string; clientSecret: string };

/** A grant for one Google account, with the scopes Google actually granted. */
export type GoogleGrant = {
  accessToken: string;
  refreshToken: string | null;
  expiresAt: number | null;
  scopes: string[];
  /** The Google account's email, from the ID token the token endpoint returned. */
  email: string | null;
};

const tokenSchema = z.object({
  access_token: z.string().min(1),
  refresh_token: z.string().optional(),
  expires_in: z.number().optional(),
  scope: z.string().optional(),
  id_token: z.string().optional(),
});

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

/**
 * Where to send the browser. `access_type=offline` with `prompt=consent` makes Google return a
 * refresh token on every sign-in, so signing in again always replaces a spent grant.
 */
export function googleAuthorizationUrl(client: GoogleClient, scopes: readonly string[], challenge: string, state: string): string {
  const url = new URL(GOOGLE_AUTHORIZE_URL);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("client_id", client.clientId);
  url.searchParams.set("redirect_uri", CALLBACK_URL);
  url.searchParams.set("scope", scopes.join(" "));
  url.searchParams.set("access_type", "offline");
  // Consent every time (so Google returns a refresh token), and a choice of account (so a second one can be added).
  url.searchParams.set("prompt", "consent select_account");
  url.searchParams.set("code_challenge", challenge);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("state", state);
  return url.toString();
}

export async function redeemGoogleCode(client: GoogleClient, code: string, verifier: string, fetcher: typeof fetch, now: number): Promise<GoogleGrant> {
  return token(client, { grant_type: "authorization_code", code, code_verifier: verifier, redirect_uri: CALLBACK_URL }, fetcher, now, null);
}

/** Renews a grant. Google keeps the refresh token; the email and scopes carry over unless it says otherwise. */
export async function refreshGoogleGrant(client: GoogleClient, grant: GoogleGrant, fetcher: typeof fetch, now: number): Promise<GoogleGrant> {
  if (!grant.refreshToken) throw new GrantRefused("the grant has no refresh token");
  return token(client, { grant_type: "refresh_token", refresh_token: grant.refreshToken }, fetcher, now, grant);
}

/** Tells Google to forget a grant. Best effort: the grant is dropped here whatever Google answers. */
export async function revokeGoogleGrant(grant: GoogleGrant, fetcher: typeof fetch): Promise<void> {
  const body = new URLSearchParams({ token: grant.refreshToken ?? grant.accessToken });
  const response = await fetcher(GOOGLE_REVOKE_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
    redirect: "manual",
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  await response.body?.cancel();
}

async function token(client: GoogleClient, form: Record<string, string>, fetcher: typeof fetch, now: number, previous: GoogleGrant | null): Promise<GoogleGrant> {
  const body = new URLSearchParams({ ...form, client_id: client.clientId, client_secret: client.clientSecret });
  const response = await fetcher(GOOGLE_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
    body,
    redirect: "manual",
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (response.status >= 400 && response.status < 500) {
    await response.body?.cancel();
    throw new GrantRefused(`Google refused: HTTP ${response.status}`);
  }
  if (!response.ok) throw new OAuthError(`Google failed: HTTP ${response.status}`);
  const answer = tokenSchema.parse(await response.json());
  return {
    accessToken: answer.access_token,
    refreshToken: answer.refresh_token ?? previous?.refreshToken ?? null,
    expiresAt: answer.expires_in ? now + answer.expires_in * 1000 : null,
    scopes: answer.scope ? answer.scope.split(" ").filter(Boolean) : previous?.scopes ?? [],
    email: answer.id_token ? emailOf(answer.id_token, client) : previous?.email ?? null,
  };
}

/**
 * The email in an ID token that came straight from Google's token endpoint over TLS, which is
 * enough to trust it without checking its signature (OpenID Connect Core 3.1.3.7). It is only
 * shown to the person; nothing is authorized by it.
 */
function emailOf(idToken: string, client: GoogleClient): string | null {
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
