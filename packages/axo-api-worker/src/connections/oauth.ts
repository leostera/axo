import { z } from "zod";
import { base64Url, randomToken } from "../auth/crypto";

/**
 * The account as an OAuth client of a third-party MCP server (RFD0016, Third-party connection
 * sign-in; modelled in specs/connection-sign-in.ts). Discovery follows the MCP authorization
 * spec: the server's protected resource metadata (RFC 9728) names its authorization server,
 * whose metadata (RFC 8414) names the endpoints. A client is registered dynamically (RFC 7591)
 * when the server allows it; otherwise the person enters one on the Connections page.
 */

export const CALLBACK_PATH = "/api/v1/connections/oauth/callback";
export const CALLBACK_URL = `https://axo.leostera.dev${CALLBACK_PATH}`;
const TIMEOUT_MS = 15_000;

const resourceMetadataSchema = z.object({
  resource: z.string().optional(),
  authorization_servers: z.array(z.url()).min(1),
  scopes_supported: z.array(z.string()).optional(),
});

const serverMetadataSchema = z.object({
  issuer: z.string().optional(),
  authorization_endpoint: z.url(),
  token_endpoint: z.url(),
  registration_endpoint: z.url().optional(),
  code_challenge_methods_supported: z.array(z.string()).optional(),
  scopes_supported: z.array(z.string()).optional(),
});

const registrationSchema = z.object({ client_id: z.string().min(1), client_secret: z.string().optional() });

const tokenSchema = z.object({
  access_token: z.string().min(1),
  token_type: z.string().optional(),
  refresh_token: z.string().optional(),
  expires_in: z.number().optional(),
  scope: z.string().optional(),
});

/** Where to sign in for one connection. Stored sealed with the connection. */
export type Discovery = {
  resource: string;
  authorizationEndpoint: string;
  tokenEndpoint: string;
  registrationEndpoint: string | null;
  scopes: string[];
};

export type Client = { clientId: string; clientSecret: string | null };

export type Grant = { accessToken: string; refreshToken: string | null; expiresAt: number | null };

export class OAuthError extends Error {}

/** The token endpoint answered: the grant is refused or the refresh token is spent. */
export class GrantRefused extends OAuthError {}

export async function discover(serverUrl: string, wwwAuthenticate: string | null, fetcher: typeof fetch = fetch): Promise<Discovery> {
  const url = new URL(serverUrl);
  const hinted = /resource_metadata="([^"]+)"/.exec(wwwAuthenticate ?? "")?.[1];
  const candidates = [
    ...(hinted ? [hinted] : []),
    `${url.origin}/.well-known/oauth-protected-resource${url.pathname === "/" ? "" : url.pathname}`,
    `${url.origin}/.well-known/oauth-protected-resource`,
  ];
  let resource: z.infer<typeof resourceMetadataSchema> | null = null;
  for (const candidate of candidates) {
    resource = await getJson(candidate, resourceMetadataSchema, fetcher).catch(() => null);
    if (resource) break;
  }
  // A server without resource metadata is its own authorization server (MCP 2025-03-26).
  const issuer = new URL(resource?.authorization_servers[0] ?? url.origin);
  const path = issuer.pathname === "/" ? "" : issuer.pathname;
  let server: z.infer<typeof serverMetadataSchema> | null = null;
  for (const candidate of [
    `${issuer.origin}/.well-known/oauth-authorization-server${path}`,
    `${issuer.origin}/.well-known/openid-configuration${path}`,
    `${issuer.origin}${path}/.well-known/openid-configuration`,
  ]) {
    server = await getJson(candidate, serverMetadataSchema, fetcher).catch(() => null);
    if (server) break;
  }
  if (!server) throw new OAuthError("the server asks for sign-in but publishes no OAuth metadata");
  if (server.code_challenge_methods_supported && !server.code_challenge_methods_supported.includes("S256"))
    throw new OAuthError("the server's sign-in does not support PKCE (S256)");
  return {
    resource: resource?.resource ?? serverUrl,
    authorizationEndpoint: server.authorization_endpoint,
    tokenEndpoint: server.token_endpoint,
    registrationEndpoint: server.registration_endpoint ?? null,
    scopes: resource?.scopes_supported ?? [],
  };
}

/** Registers Axo as a public client with the one callback it ever uses. */
export async function register(discovery: Discovery, fetcher: typeof fetch = fetch): Promise<Client> {
  if (!discovery.registrationEndpoint) throw new OAuthError("the server does not register clients itself; enter a client ID on the Connections page");
  const response = await fetcher(discovery.registrationEndpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({
      client_name: "Axo",
      redirect_uris: [CALLBACK_URL],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: "none",
    }),
    redirect: "manual",
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!response.ok) throw new OAuthError(`client registration failed: HTTP ${response.status}`);
  const client = registrationSchema.parse(await response.json());
  return { clientId: client.client_id, clientSecret: client.client_secret ?? null };
}

export type Pkce = { verifier: string; challenge: string };

export async function pkce(): Promise<Pkce> {
  const verifier = randomToken(32);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  return { verifier, challenge: base64Url(digest) };
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
  return token(discovery, client, { grant_type: "authorization_code", code, redirect_uri: CALLBACK_URL, code_verifier: verifier }, fetcher, now, null);
}

/** Renews a grant. A provider that does not rotate refresh tokens keeps the old one. */
export async function refresh(discovery: Discovery, client: Client, refreshToken: string, fetcher: typeof fetch = fetch, now = Date.now()): Promise<Grant> {
  return token(discovery, client, { grant_type: "refresh_token", refresh_token: refreshToken }, fetcher, now, refreshToken);
}

async function token(
  discovery: Discovery,
  client: Client,
  form: Record<string, string>,
  fetcher: typeof fetch,
  now: number,
  previousRefresh: string | null,
): Promise<Grant> {
  const body = new URLSearchParams({ ...form, resource: discovery.resource });
  const headers: Record<string, string> = { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" };
  if (client.clientSecret) headers.Authorization = `Basic ${btoa(`${encodeURIComponent(client.clientId)}:${encodeURIComponent(client.clientSecret)}`)}`;
  else body.set("client_id", client.clientId);
  const response = await fetcher(discovery.tokenEndpoint, { method: "POST", headers, body, redirect: "manual", signal: AbortSignal.timeout(TIMEOUT_MS) });
  if (response.status >= 400 && response.status < 500) {
    await response.body?.cancel();
    throw new GrantRefused(`the provider refused: HTTP ${response.status}`);
  }
  if (!response.ok) throw new OAuthError(`the provider failed: HTTP ${response.status}`);
  const grant = tokenSchema.parse(await response.json());
  return {
    accessToken: grant.access_token,
    refreshToken: grant.refresh_token ?? previousRefresh,
    expiresAt: grant.expires_in ? now + grant.expires_in * 1000 : null,
  };
}

async function getJson<T>(url: string, schema: z.ZodType<T>, fetcher: typeof fetch): Promise<T> {
  const response = await fetcher(url, { headers: { Accept: "application/json" }, redirect: "manual", signal: AbortSignal.timeout(TIMEOUT_MS) });
  if (!response.ok) {
    await response.body?.cancel();
    throw new OAuthError(`${url}: HTTP ${response.status}`);
  }
  return schema.parse(await response.json());
}
