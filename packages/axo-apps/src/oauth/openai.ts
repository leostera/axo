import { z } from "zod";
import { GrantRefused, OAuthError } from "../errors";

/**
 * Axo signed in to ChatGPT the way the Codex CLI is (openai/codex, `codex-rs/login`): as Codex's
 * public OAuth client at auth.openai.com, with PKCE, through its device sign-in, since its
 * browser sign-in only returns to `localhost`. Axo asks for a user code, the person enters it
 * at auth.openai.com/codex/device, and Axo polls until OpenAI hands over an authorization code
 * and the PKCE verifier it made, then redeems them. Refresh tokens rotate: each renewal spends
 * the old one.
 */

export const OPENAI_ISSUER = "https://auth.openai.com";
/** The Codex CLI's client ID, public: the CLI ships it. */
export const CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
export const DEVICE_VERIFICATION_URL = `${OPENAI_ISSUER}/codex/device`;
const USER_CODE_URL = `${OPENAI_ISSUER}/api/accounts/deviceauth/usercode`;
const DEVICE_TOKEN_URL = `${OPENAI_ISSUER}/api/accounts/deviceauth/token`;
const DEVICE_REDIRECT_URI = `${OPENAI_ISSUER}/deviceauth/callback`;
const TOKEN_URL = `${OPENAI_ISSUER}/oauth/token`;
const REVOKE_URL = `${OPENAI_ISSUER}/oauth/revoke`;
/** OpenAI lets a device code be entered for this long. */
export const DEVICE_CODE_LIFETIME_MS = 15 * 60_000;
const TIMEOUT_MS = 15_000;

/** A ChatGPT sign-in: the tokens, and which ChatGPT account (workspace) they act in. */
export type OpenAIGrant = {
  kind: "openai";
  accessToken: string;
  refreshToken: string;
  expiresAt: number | null;
  email: string | null;
  /** Sent as `chatgpt-account-id` on every call. */
  chatgptAccountId: string | null;
  plan: string | null;
};

export type DeviceCode = { deviceAuthId: string; userCode: string; intervalSeconds: number };

const userCodeSchema = z.object({
  device_auth_id: z.string().min(1).max(512),
  user_code: z.string().min(1).max(64),
  interval: z.union([z.number(), z.string()]).optional(),
});
const deviceTokenSchema = z.object({ authorization_code: z.string().min(1), code_verifier: z.string().min(1) });
const tokenSchema = z.object({
  access_token: z.string().min(1),
  refresh_token: z.string().min(1).optional(),
  id_token: z.string().optional(),
  expires_in: z.number().optional(),
});
const claimsSchema = z.object({
  email: z.string().max(320).optional(),
  "https://api.openai.com/profile": z.object({ email: z.string().max(320).optional() }).optional(),
  "https://api.openai.com/auth": z.object({
    chatgpt_account_id: z.string().max(256).optional(),
    chatgpt_plan_type: z.string().max(64).optional(),
  }).optional(),
});

/** Asks OpenAI for a user code the person enters at DEVICE_VERIFICATION_URL. */
export async function requestDeviceCode(fetcher: typeof fetch): Promise<DeviceCode> {
  const response = await fetcher(USER_CODE_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ client_id: CODEX_CLIENT_ID }),
    redirect: "manual",
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (response.status === 404) throw new OAuthError("OpenAI has device sign-in turned off");
  if (!response.ok) throw new OAuthError(`OpenAI did not start the sign-in (HTTP ${response.status})`);
  const answer = userCodeSchema.parse(await response.json());
  const interval = Number(answer.interval ?? 5);
  return { deviceAuthId: answer.device_auth_id, userCode: answer.user_code, intervalSeconds: Number.isFinite(interval) && interval > 0 ? interval : 5 };
}

/**
 * Asks once whether the person entered the code: null while they have not, the grant once they
 * have. Throws GrantRefused when OpenAI says the sign-in failed or was declined.
 */
export async function pollDeviceCode(device: DeviceCode, fetcher: typeof fetch, now: number): Promise<OpenAIGrant | null> {
  const response = await fetcher(DEVICE_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ device_auth_id: device.deviceAuthId, user_code: device.userCode }),
    redirect: "manual",
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  // OpenAI answers 403 or 404 until the code is entered.
  if (response.status === 403 || response.status === 404) {
    await response.body?.cancel();
    return null;
  }
  if (response.status >= 400 && response.status < 500) {
    const code = errorCode(await response.text());
    if (code === "deviceauth_authorization_pending" || code === "slow_down") return null;
    throw new GrantRefused(`OpenAI refused the sign-in${code ? ` (${code})` : ""}`);
  }
  if (!response.ok) throw new OAuthError(`OpenAI failed (HTTP ${response.status})`);
  const answer = deviceTokenSchema.parse(await response.json());
  return token({ grant_type: "authorization_code", code: answer.authorization_code, code_verifier: answer.code_verifier, redirect_uri: DEVICE_REDIRECT_URI }, fetcher, now, null);
}

/** Renews a grant, spending its refresh token: OpenAI rotates them. */
export async function refreshOpenAIGrant(grant: OpenAIGrant, fetcher: typeof fetch, now: number): Promise<OpenAIGrant> {
  return token({ grant_type: "refresh_token", refresh_token: grant.refreshToken }, fetcher, now, grant);
}

/** Tells OpenAI to forget a grant. Best effort: the grant is dropped here whatever OpenAI answers. */
export async function revokeOpenAIGrant(grant: OpenAIGrant, fetcher: typeof fetch): Promise<void> {
  const response = await fetcher(REVOKE_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ token: grant.refreshToken, token_type_hint: "refresh_token", client_id: CODEX_CLIENT_ID }),
    redirect: "manual",
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  await response.body?.cancel();
}

async function token(form: Record<string, string>, fetcher: typeof fetch, now: number, previous: OpenAIGrant | null): Promise<OpenAIGrant> {
  const response = await fetcher(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
    body: new URLSearchParams({ ...form, client_id: CODEX_CLIENT_ID }),
    redirect: "manual",
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (response.status >= 400 && response.status < 500) {
    await response.body?.cancel();
    throw new GrantRefused(`OpenAI refused: HTTP ${response.status}`);
  }
  if (!response.ok) throw new OAuthError(`OpenAI failed: HTTP ${response.status}`);
  const answer = tokenSchema.parse(await response.json());
  const refreshToken = answer.refresh_token ?? previous?.refreshToken;
  if (!refreshToken) throw new GrantRefused("OpenAI returned no refresh token");
  // The ID token names the account; the access token carries the same claims, for a renewal without one.
  const claims = claimsOf(answer.id_token) ?? claimsOf(answer.access_token);
  const auth = claims?.["https://api.openai.com/auth"];
  return {
    kind: "openai",
    accessToken: answer.access_token,
    refreshToken,
    expiresAt: answer.expires_in ? now + answer.expires_in * 1000 : expiryOf(answer.access_token),
    email: claims?.email ?? claims?.["https://api.openai.com/profile"]?.email ?? previous?.email ?? null,
    chatgptAccountId: auth?.chatgpt_account_id ?? previous?.chatgptAccountId ?? null,
    plan: auth?.chatgpt_plan_type ?? previous?.plan ?? null,
  };
}

/**
 * The claims of a token that came straight from OpenAI's token endpoint over TLS, which is
 * enough to trust them for naming the account (OpenID Connect Core 3.1.3.7); nothing is
 * authorized by them.
 */
function claimsOf(jwt: string | undefined): z.infer<typeof claimsSchema> | null {
  const payload = payloadOf(jwt);
  const parsed = claimsSchema.safeParse(payload);
  return parsed.success ? parsed.data : null;
}

function expiryOf(jwt: string): number | null {
  const exp = (payloadOf(jwt) as { exp?: unknown } | null)?.exp;
  return typeof exp === "number" ? exp * 1000 : null;
}

function payloadOf(jwt: string | undefined): unknown {
  const part = jwt?.split(".")[1];
  if (!part) return null;
  try {
    const binary = atob(part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "="));
    return JSON.parse(new TextDecoder().decode(Uint8Array.from(binary, (c) => c.charCodeAt(0))));
  } catch {
    return null;
  }
}

function errorCode(text: string): string | null {
  try {
    const error = (JSON.parse(text) as { error?: unknown }).error;
    const code = typeof error === "object" && error ? (error as { code?: unknown }).code : error;
    return typeof code === "string" ? code.slice(0, 64) : null;
  } catch {
    return null;
  }
}
