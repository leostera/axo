import { z } from "zod";
import { APP_ORIGIN, type AuthConfiguration } from "./config";

/** Cloudflare as the identity provider: authorization code with PKCE, then the user's profile. */
export const CLOUDFLARE_ISSUER = "https://dash.cloudflare.com";
export const CALLBACK_URL = `${APP_ORIGIN}/api/auth/cloudflare/callback`;
const AUTHORIZATION_URL = `${CLOUDFLARE_ISSUER}/oauth2/auth`;
const TOKEN_URL = `${CLOUDFLARE_ISSUER}/oauth2/token`;
const USERINFO_URL = `${CLOUDFLARE_ISSUER}/oauth2/userinfo`;
/** Only who the person is; Axo never asks to act on their Cloudflare account. */
const SCOPE = "user-details.read";
const MAX_RESPONSE_BYTES = 16_384;

/** A person as the provider vouches for them. The subject, not the email, identifies them. */
export type ProviderIdentity = {
  readonly issuer: string;
  readonly subject: string;
  readonly email: string | null;
  readonly name: string | null;
};

export function authorizationUrl(config: AuthConfiguration, state: string, challenge: string): URL {
  const url = new URL(AUTHORIZATION_URL);
  url.searchParams.set("client_id", config.clientId);
  url.searchParams.set("redirect_uri", CALLBACK_URL);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("scope", SCOPE);
  url.searchParams.set("state", state);
  url.searchParams.set("code_challenge", challenge);
  url.searchParams.set("code_challenge_method", "S256");
  return url;
}

/** The provider refused, or answered with something unusable. Says where; never says what. */
export class ProviderFailure extends Error {
  constructor(readonly stage: "token" | "profile") {
    super(`Cloudflare ${stage} request failed`);
  }
}

const tokenSchema = z.object({ access_token: z.string().min(1).max(8192), token_type: z.string() });
const profileSchema = z.object({
  sub: z.string().min(1).max(512),
  email: z.string().max(320).nullish(),
  name: z.string().max(256).nullish(),
});

export async function fetchIdentity(
  config: AuthConfiguration,
  code: string,
  verifier: string,
  fetcher: typeof fetch = fetch,
): Promise<ProviderIdentity> {
  const form = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    redirect_uri: CALLBACK_URL,
    code_verifier: verifier,
  });
  const headers = new Headers({ "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" });
  if (config.clientSecret) headers.set("Authorization", `Basic ${btoa(`${config.clientId}:${config.clientSecret}`)}`);
  else form.set("client_id", config.clientId);

  const token = tokenSchema.safeParse(await getJson("token", () =>
    fetcher(TOKEN_URL, { method: "POST", headers, body: form, redirect: "manual" })));
  if (!token.success || token.data.token_type.toLowerCase() !== "bearer") throw new ProviderFailure("token");

  const profile = profileSchema.safeParse(await getJson("profile", () =>
    fetcher(USERINFO_URL, {
      headers: { Authorization: `Bearer ${token.data.access_token}`, Accept: "application/json" },
      redirect: "manual",
    })));
  if (!profile.success) throw new ProviderFailure("profile");
  return {
    issuer: CLOUDFLARE_ISSUER,
    subject: profile.data.sub,
    email: profile.data.email ?? null,
    name: profile.data.name ?? null,
  };
}

async function getJson(stage: "token" | "profile", request: () => Promise<Response>): Promise<unknown> {
  try {
    const response = await request();
    if (!response.ok || Number(response.headers.get("Content-Length") ?? "0") > MAX_RESPONSE_BYTES)
      throw new ProviderFailure(stage);
    const body = await response.text();
    if (new TextEncoder().encode(body).byteLength > MAX_RESPONSE_BYTES) throw new ProviderFailure(stage);
    return JSON.parse(body) as unknown;
  } catch {
    throw new ProviderFailure(stage);
  }
}
