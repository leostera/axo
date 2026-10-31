import { CALLBACK_URL, GrantRefused, OAuthError } from "../oauth";
import type { ProviderApi } from "./app";

/**
 * The OAuth providers Axo has its own client with (RFD0016, Apps): Google, GitHub, Spotify,
 * Withings. Each is a config: where to send the browser, how to redeem a code and renew a grant,
 * how to read the provider's token answer, and how to name the account that signed in. Its
 * client's ID and secret are set on the Worker (`<PROVIDER>_CLIENT_ID`, `<PROVIDER>_CLIENT_SECRET`);
 * a provider without one is not set up, and its apps are not listed.
 *
 * Every sign-in goes through the connections callback (CALLBACK_URL), with its flow cookie and
 * sealed state checks (specs/connection-sign-in.ts).
 */

export const OAUTH_PROVIDERS = ["google", "github"] as const;
export type OAuthProviderName = (typeof OAUTH_PROVIDERS)[number];

export type OAuthClient = { clientId: string; clientSecret: string };
/** Axo's clients on this deployment, by provider; a provider without one is left out. */
export type OAuthClients = Partial<Record<OAuthProviderName, OAuthClient>>;

/** A grant for one provider account, with the scopes the provider actually granted. */
export type OAuthGrant = {
  /** Absent on grants sealed before there were other providers: those are Google's. */
  provider?: OAuthProviderName;
  accessToken: string;
  refreshToken: string | null;
  expiresAt: number | null;
  scopes: string[];
  /** Google's account email, from the ID token the token endpoint returned. */
  email: string | null;
  /** The provider's ID for the account, when its token answer has one (Withings' `userid`). */
  userId?: string | null;
};

/** A token endpoint's answer, as a provider reads it. */
export type TokenAnswer = {
  accessToken: string;
  refreshToken?: string;
  expiresIn?: number;
  /** As the provider sent it; split on spaces and commas. */
  scope?: string;
  email?: string | null;
  userId?: string | null;
};

export type OAuthProvider = {
  name: OAuthProviderName;
  /** As shown: "Google", "GitHub". */
  title: string;
  authorizeUrl: string;
  tokenUrl: string;
  /** The Worker's environment variables holding Axo's client. */
  env: { clientId: string; clientSecret: string };
  /** How the authorize URL joins scopes: Withings wants commas. */
  scopeSeparator: " " | ",";
  /** Sent on the authorize URL besides the standard ones, such as Google's `access_type=offline`. */
  authorizeParams: Readonly<Record<string, string>>;
  /** Whether the provider takes PKCE (S256). One that does not gets neither challenge nor verifier. */
  pkce: boolean;
  /** How the token request carries the client: HTTP basic, or `client_id` and `client_secret` in the form. */
  tokenAuth: "basic" | "body";
  /** Sent on every token request besides the standard ones (Withings' `action=requesttoken`). */
  tokenParams: Readonly<Record<string, string>>;
  /** Reads the token endpoint's JSON answer; throws GrantRefused when it is a refusal. */
  parseToken(json: unknown, client: OAuthClient): TokenAnswer;
  /**
   * Whether a renewal spends the refresh token. A renewal of one that does that and got no
   * answer may have spent the only one, so the grant is dropped and the person signs in again.
   */
  rotatesRefreshTokens: boolean;
  /**
   * The provider's name for the account that signed in, lowercased by the caller: an email, a
   * login, a user ID. `api` calls the provider's API with the new grant. Null when it says none.
   */
  identify(grant: OAuthGrant, api: ProviderApi): Promise<string | null>;
  /** Tells the provider to forget a grant, when it has a way to. Best effort. */
  revoke?(grant: OAuthGrant, client: OAuthClient, fetcher: typeof fetch): Promise<void>;
};

const TIMEOUT_MS = 15_000;

/** The clients set on the Worker. */
export function oauthClients(env: Record<string, unknown>, providers: readonly OAuthProvider[]): OAuthClients {
  const clients: OAuthClients = {};
  for (const provider of providers) {
    const clientId = env[provider.env.clientId];
    const clientSecret = env[provider.env.clientSecret];
    if (typeof clientId === "string" && clientId && typeof clientSecret === "string" && clientSecret) clients[provider.name] = { clientId, clientSecret };
  }
  return clients;
}

/** Where to send the browser to sign in, asking for `scopes`. */
export function authorizationUrl(provider: OAuthProvider, client: OAuthClient, scopes: readonly string[], challenge: string, state: string): string {
  const url = new URL(provider.authorizeUrl);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("client_id", client.clientId);
  url.searchParams.set("redirect_uri", CALLBACK_URL);
  url.searchParams.set("scope", scopes.join(provider.scopeSeparator));
  for (const [name, value] of Object.entries(provider.authorizeParams)) url.searchParams.set(name, value);
  if (provider.pkce) {
    url.searchParams.set("code_challenge", challenge);
    url.searchParams.set("code_challenge_method", "S256");
  }
  url.searchParams.set("state", state);
  return url.toString();
}

export function redeemCode(provider: OAuthProvider, client: OAuthClient, code: string, verifier: string, fetcher: typeof fetch, now: number): Promise<OAuthGrant> {
  const form: Record<string, string> = { grant_type: "authorization_code", code, redirect_uri: CALLBACK_URL };
  if (provider.pkce) form.code_verifier = verifier;
  return token(provider, client, form, fetcher, now, null);
}

/** Renews a grant. What the answer leaves out (a refresh token that did not rotate, the scopes, the account) carries over. */
export function refreshGrant(provider: OAuthProvider, client: OAuthClient, grant: OAuthGrant, fetcher: typeof fetch, now: number): Promise<OAuthGrant> {
  if (!grant.refreshToken) throw new GrantRefused("the grant has no refresh token");
  return token(provider, client, { grant_type: "refresh_token", refresh_token: grant.refreshToken }, fetcher, now, grant);
}

async function token(provider: OAuthProvider, client: OAuthClient, form: Record<string, string>, fetcher: typeof fetch, now: number, previous: OAuthGrant | null): Promise<OAuthGrant> {
  const body = new URLSearchParams({ ...provider.tokenParams, ...form });
  const headers: Record<string, string> = { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" };
  if (provider.tokenAuth === "basic") headers.Authorization = `Basic ${btoa(`${client.clientId}:${client.clientSecret}`)}`;
  else {
    body.set("client_id", client.clientId);
    body.set("client_secret", client.clientSecret);
  }
  const response = await fetcher(provider.tokenUrl, { method: "POST", headers, body, redirect: "manual", signal: AbortSignal.timeout(TIMEOUT_MS) });
  if (response.status >= 400 && response.status < 500) {
    await response.body?.cancel();
    throw new GrantRefused(`${provider.title} refused: HTTP ${response.status}`);
  }
  if (!response.ok) throw new OAuthError(`${provider.title} failed: HTTP ${response.status}`);
  let json: unknown;
  try {
    json = await response.json();
  } catch {
    throw new OAuthError(`${provider.title} answered with something other than JSON`);
  }
  const answer = provider.parseToken(json, client);
  return {
    provider: provider.name,
    accessToken: answer.accessToken,
    refreshToken: answer.refreshToken ?? previous?.refreshToken ?? null,
    expiresAt: answer.expiresIn ? now + answer.expiresIn * 1000 : null,
    // A renewal's answer may leave the scopes out, or send them empty (GitHub): they carry over.
    scopes: answer.scope ? answer.scope.split(/[ ,]+/).filter(Boolean) : previous?.scopes ?? [],
    email: answer.email ?? previous?.email ?? null,
    userId: answer.userId ?? previous?.userId ?? null,
  };
}

/** The common token answer (RFC 6749, 5.1). A provider that answers 200 with `{ error }` (GitHub) is refused. */
export function standardToken(json: unknown, title: string): TokenAnswer {
  const answer = (json ?? {}) as Record<string, unknown>;
  if (typeof answer.error === "string") throw new GrantRefused(`${title} refused: ${answer.error.slice(0, 64)}`);
  if (typeof answer.access_token !== "string" || !answer.access_token) throw new OAuthError(`${title} returned no access token`);
  return {
    accessToken: answer.access_token,
    refreshToken: typeof answer.refresh_token === "string" && answer.refresh_token ? answer.refresh_token : undefined,
    expiresIn: typeof answer.expires_in === "number" && answer.expires_in > 0 ? answer.expires_in : undefined,
    scope: typeof answer.scope === "string" ? answer.scope : undefined,
  };
}
