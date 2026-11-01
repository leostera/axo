import * as oauth from "oauth4webapi";
import { ProviderError, type MacSignIn } from "../app";

/**
 * Kraken's sign-in, for the Kraken app's "Sign in with Kraken" (RFD0016). Kraken lets only
 * approved partners register an OAuth client, so this uses kraken-cli's public client, which
 * Kraken publishes in kraken-cli's source: a PKCE client with no secret, whose redirects are
 * registered only as `http://localhost:27461` to `27463` `/callback`. So the sign-in ends on the
 * person's Mac (axod's loopback sign-in), and the Worker, which keeps the PKCE verifier, redeems
 * the code and creates a Fast API key: an ordinary Kraken API key with the permissions the person
 * chose, for at most 90 days, which the app's tools sign with as they do a pasted one. Kraken
 * gives no withdrawal permission this way.
 */

export const KRAKEN_CLI_CLIENT_ID = "230dc4f672711a31e0ae01db611cf68c";
export const KRAKEN_AUTHORIZE_URL = "https://www.kraken.com/oauth/authorize";
export const KRAKEN_REDIRECT_PORTS = [27461, 27462, 27463] as const;
export const KRAKEN_REDIRECT_PATH = "/callback";
const TOKEN_URL = "https://api.kraken.com/oauth/token";
const FAST_API_KEY_URL = "https://api.kraken.com/oauth/fast-api-key";
/** The longest Kraken lets a Fast API key live. */
export const KRAKEN_KEY_MAX_DAYS = 90;

/** A Fast API key permission: its OAuth scope's last part and the key's flag. */
const PERMISSIONS = {
  "funds-query": "funds_query",
  "funds-add": "funds_add",
  "funds-earn": "funds_earn",
  "trades-query-open": "trades_query_open",
  "trades-query-closed": "trades_query_closed",
  "trades-modify": "trades_modify",
  "trades-close": "trades_close",
  "ledger-query": "ledger_query",
  "export-data": "export_data",
} as const;
type Permission = keyof typeof PERMISSIONS;

/** What the person chooses the key may do. */
export const KRAKEN_PRESETS = [
  {
    id: "read",
    label: "Read only",
    description: "See balances, orders, trades and the ledger, and export data.",
    permissions: ["funds-query", "trades-query-open", "trades-query-closed", "ledger-query", "export-data"] satisfies Permission[],
  },
  {
    id: "trade",
    label: "Read and trade",
    description: "Everything Read only does, and place, change and cancel orders.",
    permissions: ["funds-query", "trades-query-open", "trades-query-closed", "ledger-query", "export-data", "trades-modify", "trades-close"] satisfies Permission[],
  },
] as const;
export type KrakenPreset = (typeof KRAKEN_PRESETS)[number]["id"];

const scopesOf = (preset: KrakenPreset): string[] => [
  "account.fast-api-key:write",
  ...presetOf(preset).permissions.map((p) => `account.fast-api-key:${p}`),
];

function presetOf(preset: string): (typeof KRAKEN_PRESETS)[number] {
  const found = KRAKEN_PRESETS.find((p) => p.id === preset);
  if (!found) throw new ProviderError(400, `no Kraken permission set named ${preset}`);
  return found;
}

/** The sign-in page, with every parameter but `redirect_uri`, which axod adds for the port it gets. */
export function krakenAuthorizeUrl(preset: KrakenPreset, state: string, challenge: string): string {
  presetOf(preset);
  const url = new URL(KRAKEN_AUTHORIZE_URL);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("client_id", KRAKEN_CLI_CLIENT_ID);
  url.searchParams.set("scope", scopesOf(preset).join(" "));
  url.searchParams.set("state", state);
  url.searchParams.set("code_challenge", challenge);
  url.searchParams.set("code_challenge_method", "S256");
  return url.toString();
}

/** The OAuth tokens a sign-in gave; kept only to delete the key when the account is removed. */
export type KrakenOAuth = { accessToken: string; refreshToken: string | null; expiresAt: number };

/** A Fast API key, as the app's tools sign with it. */
export type KrakenKey = { name: string; key: string; secret: string; validUntil: number };

type Envelope<T> = { error?: string[]; result?: T };

/** Kraken's `{ error: [...], result }`: the codes, or the result. */
async function envelope<T>(response: Response, what: string): Promise<T | null> {
  const text = await response.text();
  let body: Envelope<T> | null = null;
  try {
    body = JSON.parse(text) as Envelope<T>;
  } catch {
    // Not JSON: handled below.
  }
  if (body?.error?.length) throw new ProviderError(response.status === 200 ? 400 : response.status, `Kraken ${what}: ${body.error.join("; ")}`);
  if (!response.ok || !body) throw new ProviderError(response.status, `Kraken ${what} failed (HTTP ${response.status})`);
  return body.result ?? null;
}

const AS: oauth.AuthorizationServer = { issuer: "https://www.kraken.com", authorization_endpoint: KRAKEN_AUTHORIZE_URL, token_endpoint: TOKEN_URL };
const CLIENT: oauth.Client = { client_id: KRAKEN_CLI_CLIENT_ID };

/** oauth4webapi's failures, as the ProviderError a sign-in reports. */
function refused(error: unknown, what: string): never {
  if (error instanceof oauth.ResponseBodyError) throw new ProviderError(error.status, `Kraken ${what}: ${error.error_description ?? error.error}`);
  if (error instanceof oauth.AuthorizationResponseError) throw new ProviderError(400, `Kraken ${what}: ${error.error_description ?? error.error}`);
  if (error instanceof oauth.OperationProcessingError) throw new ProviderError(502, `Kraken ${what}: ${error.message}`);
  throw error;
}

function grantOf(token: oauth.TokenEndpointResponse, now: number, previous: string | null): KrakenOAuth {
  return { accessToken: token.access_token, refreshToken: token.refresh_token ?? previous, expiresAt: now + (token.expires_in ?? 4 * 3600) * 1000 };
}

/** Redeems the sign-in's code, and checks Kraken granted what was asked, no more and no less. */
export async function krakenRedeem(input: { code: string; state: string; redirectUri: string; verifier: string; preset: KrakenPreset }, fetcher: typeof fetch, now: number): Promise<KrakenOAuth> {
  let token: oauth.TokenEndpointResponse;
  try {
    // The Mac checked the redirect's state already; this only brands the parameters for the exchange.
    const callback = oauth.validateAuthResponse(AS, CLIENT, new URLSearchParams({ code: input.code, state: input.state }), input.state);
    const response = await oauth.authorizationCodeGrantRequest(AS, CLIENT, oauth.None(), callback, input.redirectUri, input.verifier, { [oauth.customFetch]: fetcher });
    token = await oauth.processAuthorizationCodeResponse(AS, CLIENT, response);
  } catch (error) {
    refused(error, "did not finish the sign-in");
  }
  // An absent scope is the one asked for.
  if (token.scope !== undefined) {
    const granted = new Set(token.scope.split(/\s+/).filter(Boolean));
    const wanted = scopesOf(input.preset);
    const missing = wanted.filter((s) => !granted.has(s));
    const extra = [...granted].filter((s) => !wanted.includes(s));
    if (missing.length || extra.length) {
      throw new ProviderError(403, `Kraken granted other permissions than asked for${missing.length ? `; missing ${missing.join(", ")}` : ""}${extra.length ? `; extra ${extra.join(", ")}` : ""}`);
    }
  }
  return grantOf(token, now, null);
}

/**
 * Creates the Fast API key. A key whose name, expiry or permissions differ from the request is
 * refused (and deleted), so a defect cannot leave a wider or longer-lived key than the person chose.
 */
export async function krakenCreateKey(oauth: KrakenOAuth, preset: KrakenPreset, fetcher: typeof fetch, now: number): Promise<KrakenKey> {
  const name = `axo-${[...crypto.getRandomValues(new Uint8Array(4))].map((b) => b.toString(16).padStart(2, "0")).join("")}`;
  const validUntil = Math.floor(now / 1000) + KRAKEN_KEY_MAX_DAYS * 86_400;
  const permissions = Object.fromEntries(presetOf(preset).permissions.map((p) => [PERMISSIONS[p], true]));
  const response = await fetcher(FAST_API_KEY_URL, {
    method: "POST",
    headers: { Authorization: `Bearer ${oauth.accessToken}`, "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ api_key_name: name, permissions, valid_until: validUntil }),
  });
  const created = await envelope<{ api_key_name?: string; api_key?: string; secret?: string; valid_until?: number; permissions?: Record<string, boolean> }>(response, "would not create the key");
  if (!created?.api_key || !created.secret) throw new ProviderError(502, "Kraken created the key but did not send it; delete any key named axo-… in Kraken's API settings and try again");
  const flags = new Set(Object.entries(created.permissions ?? {}).filter(([, on]) => on).map(([flag]) => flag));
  const wider = [...flags].filter((f) => !Object.hasOwn(permissions, f));
  if (created.api_key_name !== name || (created.valid_until ?? 0) > validUntil || wider.length) {
    await krakenDeleteKey(oauth, created.api_key_name ?? name, fetcher).catch(() => undefined);
    throw new ProviderError(502, "Kraken created a different key than asked for, so Axo deleted it");
  }
  return { name, key: created.api_key, secret: created.secret, validUntil: (created.valid_until ?? validUntil) * 1000 };
}

/** Renews the OAuth tokens, to delete a key after the 4-hour access token has expired. */
export async function krakenRefresh(grant: KrakenOAuth, fetcher: typeof fetch, now: number): Promise<KrakenOAuth | null> {
  if (!grant.refreshToken) return null;
  try {
    const response = await oauth.refreshTokenGrantRequest(AS, CLIENT, oauth.None(), grant.refreshToken, { [oauth.customFetch]: fetcher });
    return grantOf(await oauth.processRefreshTokenResponse(AS, CLIENT, response), now, grant.refreshToken);
  } catch {
    return null;
  }
}

/** Deletes a Fast API key at Kraken. */
export async function krakenDeleteKey(oauth: KrakenOAuth, name: string, fetcher: typeof fetch): Promise<void> {
  const response = await fetcher(FAST_API_KEY_URL, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${oauth.accessToken}`, "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ api_key_name: name }),
  });
  await envelope(response, "would not delete the key");
}

/** The Kraken app's sign-in on the person's Mac. */
export const krakenMacSignIn: MacSignIn = {
  title: "Sign in with Kraken",
  presets: KRAKEN_PRESETS.map(({ id, label, description }) => ({ id, label, description })),
  ports: KRAKEN_REDIRECT_PORTS,
  path: KRAKEN_REDIRECT_PATH,
  authorizeUrl: (preset, state, challenge) => krakenAuthorizeUrl(preset as KrakenPreset, state, challenge),
  async complete(input, fetcher, now) {
    const preset = presetOf(input.preset).id;
    const oauth = await krakenRedeem({ ...input, preset }, fetcher, now);
    const key = await krakenCreateKey(oauth, preset, fetcher, now);
    return { fields: { key: key.key, secret: key.secret }, expiresAt: key.validUntil, revocation: { oauth, name: key.name } };
  },
  async revoke(revocation, _fields, fetcher, now) {
    const { oauth, name } = revocation as { oauth: KrakenOAuth; name: string };
    const fresh = oauth.expiresAt > now + 60_000 ? oauth : await krakenRefresh(oauth, fetcher, now);
    if (fresh) await krakenDeleteKey(fresh, name, fetcher);
  },
};
