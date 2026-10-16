import { z } from "zod";

const CALLBACK_URL = "https://axo.leostera.dev/api/auth/cloudflare/callback";
const TOKEN_URL = "https://dash.cloudflare.com/oauth2/token";
const USERINFO_URL = "https://dash.cloudflare.com/oauth2/userinfo";

export type CloudflareProfile = {
  subject: string;
  email: string | null;
  name: string | null;
};

type OAuthEnvironment = {
  OAUTH_CLIENT_ID?: string;
  OAUTH_CLIENT_SECRET?: string;
};

export type OAuthProviderFailureStage =
  | "token_exchange"
  | "token_response"
  | "userinfo_request"
  | "userinfo_response";
export type OAuthProviderFailureReason = "configuration" | "network" | "http" | "invalid_response";
export type OAuthProviderErrorCode =
  | "access_denied"
  | "invalid_client"
  | "invalid_grant"
  | "invalid_request"
  | "invalid_scope"
  | "server_error"
  | "temporarily_unavailable"
  | "unauthorized_client"
  | "unsupported_grant_type";

export class OAuthProviderFailure extends Error {
  constructor(
    readonly stage: OAuthProviderFailureStage,
    readonly reason: OAuthProviderFailureReason,
    message: string,
    readonly status?: number,
    readonly providerCode?: OAuthProviderErrorCode,
  ) {
    super(message);
  }
}

const tokenResponseSchema = z.object({
  access_token: z.string().min(1).max(8192),
  token_type: z.string().min(1).max(64),
});
const userInfoSchema = z.object({
  sub: z.string().min(1).max(512),
  email: z.string().max(320).nullable().optional(),
  name: z.string().max(256).nullable().optional(),
});

export async function loadCloudflareProfile(
  code: string,
  verifier: string,
  env: OAuthEnvironment,
  fetcher: typeof fetch = fetch,
): Promise<CloudflareProfile> {
  if (!env.OAUTH_CLIENT_ID)
    throw new OAuthProviderFailure("token_exchange", "configuration", "OAuth client is not configured");
  const form = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    redirect_uri: CALLBACK_URL,
    code_verifier: verifier,
  });
  const headers = new Headers({ "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" });
  if (env.OAUTH_CLIENT_SECRET) {
    headers.set("Authorization", `Basic ${btoa(`${env.OAUTH_CLIENT_ID}:${env.OAUTH_CLIENT_SECRET}`)}`);
  } else {
    form.set("client_id", env.OAUTH_CLIENT_ID);
  }

  const tokenResponse = await fetchOAuthEndpoint(
    "token_exchange",
    () => fetcher(TOKEN_URL, {
      method: "POST",
      headers,
      body: form,
      redirect: "manual",
    }),
  );
  if (!tokenResponse.ok) {
    throw new OAuthProviderFailure(
      "token_exchange",
      "http",
      "OAuth code exchange failed",
      tokenResponse.status,
      await safeProviderErrorCode(tokenResponse),
    );
  }
  const tokenPayload = await responseJson(tokenResponse, "token_response");
  const token = tokenResponseSchema.safeParse(tokenPayload);
  if (!token.success || token.data.token_type.toLowerCase() !== "bearer")
    throw new OAuthProviderFailure("token_response", "invalid_response", "Invalid OAuth token response");

  const userInfoResponse = await fetchOAuthEndpoint("userinfo_request", () =>
    fetcher(USERINFO_URL, {
      headers: { Authorization: `Bearer ${token.data.access_token}`, Accept: "application/json" },
      redirect: "manual",
    }),
  );
  if (!userInfoResponse.ok) {
    throw new OAuthProviderFailure(
      "userinfo_request",
      "http",
      "OAuth userinfo request failed",
      userInfoResponse.status,
      await safeProviderErrorCode(userInfoResponse),
    );
  }
  const userInfoPayload = await responseJson(userInfoResponse, "userinfo_response");
  const userInfo = userInfoSchema.safeParse(userInfoPayload);
  if (!userInfo.success)
    throw new OAuthProviderFailure("userinfo_response", "invalid_response", "Invalid OAuth userinfo response");
  return {
    subject: userInfo.data.sub,
    email: userInfo.data.email ?? null,
    name: userInfo.data.name ?? null,
  };
}

const SAFE_PROVIDER_ERROR_CODES = new Set<OAuthProviderErrorCode>([
  "access_denied",
  "invalid_client",
  "invalid_grant",
  "invalid_request",
  "invalid_scope",
  "server_error",
  "temporarily_unavailable",
  "unauthorized_client",
  "unsupported_grant_type",
]);

async function safeProviderErrorCode(response: Response): Promise<OAuthProviderErrorCode | undefined> {
  try {
    const payload = await boundedJson(response);
    if (typeof payload !== "object" || payload === null) return undefined;
    const error = (payload as { error?: unknown }).error;
    return typeof error === "string" && SAFE_PROVIDER_ERROR_CODES.has(error as OAuthProviderErrorCode)
      ? error as OAuthProviderErrorCode
      : undefined;
  } catch {
    return undefined;
  }
}

async function fetchOAuthEndpoint(
  stage: "token_exchange" | "userinfo_request",
  request: () => Promise<Response>,
): Promise<Response> {
  try {
    return await request();
  } catch {
    throw new OAuthProviderFailure(stage, "network", "OAuth provider request failed");
  }
}

async function responseJson(
  response: Response,
  stage: "token_response" | "userinfo_response",
): Promise<unknown> {
  try {
    return await boundedJson(response);
  } catch (error) {
    const message = error instanceof Error && error.message === "OAuth response too large"
      ? error.message
      : stage === "token_response" ? "Invalid OAuth token response" : "Invalid OAuth userinfo response";
    throw new OAuthProviderFailure(stage, "invalid_response", message);
  }
}

async function boundedJson(response: Response): Promise<unknown> {
  const length = Number(response.headers.get("Content-Length") ?? "0");
  if (length > 16_384) throw new Error("OAuth response too large");
  const body = await response.text();
  if (new TextEncoder().encode(body).byteLength > 16_384) throw new Error("OAuth response too large");
  return JSON.parse(body) as unknown;
}
