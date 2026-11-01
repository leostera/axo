import { discoverOAuthServerInfo, exchangeAuthorization, refreshAuthorization, registerClient } from "@modelcontextprotocol/sdk/client/auth.js";
import type { AuthorizationServerMetadata, OAuthClientInformation, OAuthTokens } from "@modelcontextprotocol/sdk/shared/auth.js";
import { pkceVerifier } from "@axo/apps";

/**
 * The account as an OAuth client of a third-party MCP server (RFD0016, Third-party connection
 * sign-in; modelled in specs/connection-sign-in.ts). Discovery follows the MCP authorization
 * spec: the server's protected resource metadata (RFC 9728) names its authorization server,
 * whose metadata (RFC 8414) names the endpoints. A client is registered dynamically (RFC 7591)
 * when the server allows it; otherwise the person enters one on the Connections page.
 *
 * Every step is the official MCP SDK's (`@modelcontextprotocol/sdk/client/auth`), the code the
 * MCP clients most servers are tried with run, so it bends where servers do. This file keeps
 * what is Axo's: the one callback, the resource indicator, and which failures are refusals.
 */

export const CALLBACK_PATH = "/api/v1/connections/oauth/callback";
export const CALLBACK_URL = `https://axo.leostera.dev${CALLBACK_PATH}`;
const TIMEOUT_MS = 15_000;

/** Where to sign in for one connection. Stored sealed with the connection. */
export type Discovery = {
  resource: string;
  authorizationEndpoint: string;
  tokenEndpoint: string;
  registrationEndpoint: string | null;
  scopes: string[];
  /** The authorization server's client authentication methods, when it lists them; absent in discoveries stored before. */
  authMethods?: string[];
};

export type Client = { clientId: string; clientSecret: string | null };

export type Grant = { accessToken: string; refreshToken: string | null; expiresAt: number | null };

export class OAuthError extends Error {}

/** The token endpoint answered: the grant is refused or the refresh token is spent. */
export class GrantRefused extends OAuthError {}

export async function discover(serverUrl: string, wwwAuthenticate: string | null, fetcher: typeof fetch = fetch): Promise<Discovery> {
  const hinted = /resource_metadata="([^"]+)"/.exec(wwwAuthenticate ?? "")?.[1];
  let info: Awaited<ReturnType<typeof discoverOAuthServerInfo>>;
  try {
    info = await discoverOAuthServerInfo(serverUrl, { resourceMetadataUrl: hinted ? new URL(hinted, serverUrl) : undefined, fetchFn: timed(fetcher) });
  } catch (error) {
    throw new OAuthError(`the server's OAuth metadata could not be read: ${message(error)}`);
  }
  const server = info.authorizationServerMetadata;
  if (!server) throw new OAuthError("the server asks for sign-in but publishes no OAuth metadata");
  if (server.code_challenge_methods_supported && !server.code_challenge_methods_supported.includes("S256"))
    throw new OAuthError("the server's sign-in does not support PKCE (S256)");
  return {
    resource: info.resourceMetadata?.resource ?? serverUrl,
    authorizationEndpoint: server.authorization_endpoint,
    tokenEndpoint: server.token_endpoint,
    registrationEndpoint: server.registration_endpoint ?? null,
    scopes: info.resourceMetadata?.scopes_supported ?? [],
    ...(server.token_endpoint_auth_methods_supported ? { authMethods: server.token_endpoint_auth_methods_supported } : {}),
  };
}

/** Registers Axo as a public client with the one callback it ever uses. */
export async function register(discovery: Discovery, fetcher: typeof fetch = fetch): Promise<Client> {
  if (!discovery.registrationEndpoint) throw new OAuthError("the server does not register clients itself; enter a client ID on the Connections page");
  try {
    const client = await registerClient(issuerOf(discovery), {
      metadata: metadataOf(discovery),
      clientMetadata: {
        client_name: "Axo",
        redirect_uris: [CALLBACK_URL],
        grant_types: ["authorization_code", "refresh_token"],
        response_types: ["code"],
        token_endpoint_auth_method: "none",
      },
      fetchFn: timed(fetcher),
    });
    return { clientId: client.client_id, clientSecret: client.client_secret ?? null };
  } catch (error) {
    throw new OAuthError(`client registration failed: ${message(error)}`);
  }
}

export type Pkce = { verifier: string };

export async function pkce(): Promise<Pkce> {
  return { verifier: pkceVerifier() };
}

export function authorizationUrl(discovery: Discovery, client: Client, challenge: string, state: string): string {
  const url = new URL(discovery.authorizationEndpoint);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("client_id", client.clientId);
  url.searchParams.set("redirect_uri", CALLBACK_URL);
  url.searchParams.set("code_challenge", challenge);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("state", state);
  url.searchParams.set("resource", discovery.resource);
  if (discovery.scopes.length) url.searchParams.set("scope", discovery.scopes.join(" "));
  return url.toString();
}

export async function redeemCode(discovery: Discovery, client: Client, code: string, verifier: string, fetcher: typeof fetch = fetch, now = Date.now()): Promise<Grant> {
  return token(fetcher, now, null, (fetchFn) => exchangeAuthorization(issuerOf(discovery), {
    metadata: metadataOf(discovery), clientInformation: clientOf(client), authorizationCode: code, codeVerifier: verifier,
    redirectUri: CALLBACK_URL, resource: new URL(discovery.resource), fetchFn,
  }));
}

/** Renews a grant. A provider that does not rotate refresh tokens keeps the old one. */
export async function refresh(discovery: Discovery, client: Client, refreshToken: string, fetcher: typeof fetch = fetch, now = Date.now()): Promise<Grant> {
  return token(fetcher, now, refreshToken, (fetchFn) => refreshAuthorization(issuerOf(discovery), {
    metadata: metadataOf(discovery), clientInformation: clientOf(client), refreshToken, resource: new URL(discovery.resource), fetchFn,
  }));
}

/**
 * One token request. A 4xx answer is a refusal (GrantRefused: the code or refresh token is spent);
 * a 5xx or an answer that is not a token is a failure (OAuthError); no answer throws as fetch did.
 */
async function token(fetcher: typeof fetch, now: number, previousRefresh: string | null, request: (fetchFn: typeof fetch) => Promise<OAuthTokens>): Promise<Grant> {
  let status = 0;
  let answered = false;
  const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const response = await timed(fetcher)(input, init);
    answered = true;
    status = response.status;
    return response;
  }) as typeof fetch;
  let tokens: OAuthTokens;
  try {
    tokens = await request(fetchFn);
  } catch (error) {
    if (!answered) throw error;
    if (status >= 400 && status < 500) throw new GrantRefused(`the provider refused: HTTP ${status}`);
    throw new OAuthError(status >= 500 ? `the provider failed: HTTP ${status}` : `the provider's answer was not a token: ${message(error)}`);
  }
  return {
    accessToken: tokens.access_token,
    refreshToken: tokens.refresh_token || previousRefresh,
    expiresAt: tokens.expires_in ? now + tokens.expires_in * 1000 : null,
  };
}

/** The authorization server's metadata, as discovered, for the SDK's token and registration requests. */
function metadataOf(discovery: Discovery): AuthorizationServerMetadata {
  return {
    issuer: issuerOf(discovery),
    authorization_endpoint: discovery.authorizationEndpoint,
    token_endpoint: discovery.tokenEndpoint,
    response_types_supported: ["code"],
    ...(discovery.registrationEndpoint ? { registration_endpoint: discovery.registrationEndpoint } : {}),
    ...(discovery.authMethods ? { token_endpoint_auth_methods_supported: discovery.authMethods } : {}),
  };
}

function issuerOf(discovery: Discovery): string {
  return new URL(discovery.tokenEndpoint).origin;
}

/** A client the person entered or registered: one with a secret authenticates, one without sends its ID. */
function clientOf(client: Client): OAuthClientInformation {
  return { client_id: client.clientId, ...(client.clientSecret ? { client_secret: client.clientSecret } : {}) };
}

/** Every request the SDK makes ends within the timeout and follows no redirect. */
function timed(fetcher: typeof fetch): typeof fetch {
  return ((input: RequestInfo | URL, init?: RequestInit) => fetcher(input, { ...init, redirect: "manual", signal: AbortSignal.timeout(TIMEOUT_MS) })) as typeof fetch;
}

function message(error: unknown): string {
  return (error instanceof Error ? error.message : String(error)).slice(0, 200);
}
