import * as oauth from "oauth4webapi";
import { GrantRefused, OAuthError } from "../errors";
import type { ProviderApi } from "../app";

/**
 * The OAuth providers an app can sign in with (RFD0016, Apps): Google, GitHub, Spotify, Withings.
 * Each is a config: its endpoints and quirks, and how to name the account that signed in. The
 * token endpoint is spoken with oauth4webapi; a provider that answers it out of the standard
 * (GitHub's refusals with HTTP 200, Withings' `{ status, body }`) adapts its answers first.
 *
 * The client (its ID and secret) is not part of the config: the person registers one with the
 * provider, with the deployment's callback as its redirect URI, and enters it on the app's page.
 * The account's gateway keeps it sealed, so it can be changed or rotated at any time. A provider
 * without a client is not set up yet, and its apps say so.
 */

export const OAUTH_PROVIDERS = ["google", "github", "spotify", "withings"] as const;
export type OAuthProviderName = (typeof OAUTH_PROVIDERS)[number];

export type OAuthClient = { clientId: string; clientSecret: string };
/** The clients set up, by provider; a provider without one is left out. */
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

export type OAuthProvider = {
  name: OAuthProviderName;
  /** As shown: "Google", "GitHub". */
  title: string;
  /** The issuer its ID tokens name (Google's); the authorize URL's origin for the rest. */
  issuer: string;
  authorizeUrl: string;
  tokenUrl: string;
  /** Where the person registers a client with the provider, and finds its ID and secret. */
  consoleUrl: string;
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
  /**
   * Turns the token endpoint's answer into a standard one (RFC 6749, 5.1 and 5.2), for a provider
   * that answers out of the standard. Called on every answer.
   */
  adaptTokenResponse?(response: Response): Promise<Response>;
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

/** Where to send the browser to sign in, asking for `scopes`; the provider sends it back to `redirectUri`. */
export function authorizationUrl(provider: OAuthProvider, client: OAuthClient, scopes: readonly string[], challenge: string, state: string, redirectUri: string): string {
  const url = new URL(provider.authorizeUrl);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("client_id", client.clientId);
  url.searchParams.set("redirect_uri", redirectUri);
  url.searchParams.set("scope", scopes.join(provider.scopeSeparator));
  for (const [name, value] of Object.entries(provider.authorizeParams)) url.searchParams.set(name, value);
  if (provider.pkce) {
    url.searchParams.set("code_challenge", challenge);
    url.searchParams.set("code_challenge_method", "S256");
  }
  url.searchParams.set("state", state);
  return url.toString();
}

/** Redeems the code the provider sent the browser back with; `redirectUri` is the one the sign-in started with. */
export function redeemCode(provider: OAuthProvider, client: OAuthClient, code: string, verifier: string, redirectUri: string, fetcher: typeof fetch, now: number): Promise<OAuthGrant> {
  return token(provider, client, fetcher, now, null, async (as, oauthClient, auth, options) => {
    // The callback checked the state already; this only hands oauth4webapi the code.
    const callback = oauth.validateAuthResponse(as, oauthClient, new URLSearchParams({ code }), oauth.skipStateCheck);
    const response = await oauth.authorizationCodeGrantRequest(as, oauthClient, auth, callback, redirectUri, provider.pkce ? verifier : oauth.nopkce, options);
    return oauth.processAuthorizationCodeResponse(as, oauthClient, response);
  });
}

/** Renews a grant. What the answer leaves out (a refresh token that did not rotate, the scopes, the account) carries over. */
export function refreshGrant(provider: OAuthProvider, client: OAuthClient, grant: OAuthGrant, fetcher: typeof fetch, now: number): Promise<OAuthGrant> {
  const refreshToken = grant.refreshToken;
  if (!refreshToken) throw new GrantRefused("the grant has no refresh token");
  return token(provider, client, fetcher, now, grant, async (as, oauthClient, auth, options) => {
    const response = await oauth.refreshTokenGrantRequest(as, oauthClient, auth, refreshToken, options);
    return oauth.processRefreshTokenResponse(as, oauthClient, response);
  });
}

type Exchange = (as: oauth.AuthorizationServer, client: oauth.Client, auth: oauth.ClientAuth, options: oauth.TokenEndpointRequestOptions) => Promise<oauth.TokenEndpointResponse>;

/**
 * One token request. A 4xx answer is a refusal (GrantRefused: the code or refresh token is
 * spent); a 5xx or an answer out of the standard is a failure (OAuthError), and no answer at all
 * throws as fetch did.
 */
async function token(provider: OAuthProvider, client: OAuthClient, fetcher: typeof fetch, now: number, previous: OAuthGrant | null, exchange: Exchange): Promise<OAuthGrant> {
  const as: oauth.AuthorizationServer = { issuer: provider.issuer, authorization_endpoint: provider.authorizeUrl, token_endpoint: provider.tokenUrl };
  const oauthClient: oauth.Client = { client_id: client.clientId };
  const auth = provider.tokenAuth === "basic" ? oauth.ClientSecretBasic(client.clientSecret) : oauth.ClientSecretPost(client.clientSecret);
  let status = 0;
  const adapted = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const response = await fetcher(input, init);
    const answer = provider.adaptTokenResponse ? await provider.adaptTokenResponse(response) : response;
    status = answer.status;
    return answer;
  }) as typeof fetch;
  let answer: oauth.TokenEndpointResponse;
  try {
    answer = await exchange(as, oauthClient, auth, {
      [oauth.customFetch]: adapted,
      signal: AbortSignal.timeout(TIMEOUT_MS),
      additionalParameters: provider.tokenParams,
    });
  } catch (error) {
    if (error instanceof oauth.ResponseBodyError || (status >= 400 && status < 500 && error instanceof oauth.OperationProcessingError)) {
      const code = error instanceof oauth.ResponseBodyError ? error.error.slice(0, 64) : `HTTP ${status}`;
      throw new GrantRefused(`${provider.title} refused: ${code}`);
    }
    if (error instanceof oauth.OperationProcessingError || error instanceof oauth.UnsupportedOperationError) {
      throw new OAuthError(`${provider.title} failed: ${status && status !== 200 ? `HTTP ${status}` : error.message}`);
    }
    throw error;
  }
  const claims = oauth.getValidatedIdTokenClaims(answer);
  const email = typeof claims?.email === "string" ? claims.email.slice(0, 320) : null;
  const userId = typeof answer.userid === "string" || typeof answer.userid === "number" ? String(answer.userid) : null;
  return {
    provider: provider.name,
    accessToken: answer.access_token,
    refreshToken: answer.refresh_token || previous?.refreshToken || null,
    expiresAt: answer.expires_in ? now + answer.expires_in * 1000 : null,
    // A renewal's answer may leave the scopes out, or send them empty (GitHub): they carry over.
    scopes: answer.scope ? answer.scope.split(/[ ,]+/).filter(Boolean) : previous?.scopes ?? [],
    email: email ?? previous?.email ?? null,
    userId: userId ?? previous?.userId ?? null,
  };
}

/** A JSON answer with this body and status, keeping nothing of the original but that it came. */
export function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
