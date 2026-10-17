import { recordApiEvent } from "../observability";
import { loadCloudflareProfile, OAuthProviderFailure } from "./provider";
import { constantTimeEqual, hmac, openCookie, randomToken, sealCookie, sha256 } from "./crypto";

const AUTH_ORIGIN = "https://axo.leostera.dev";
const CALLBACK_URL = `${AUTH_ORIGIN}/api/auth/cloudflare/callback`;
const AUTHORIZATION_URL = "https://dash.cloudflare.com/oauth2/auth";
const CLOUDFLARE_ISSUER = "https://dash.cloudflare.com";
const USERINFO_SCOPE = "user-details.read";
const OAUTH_COOKIE = "__Host-axo_oauth";
const SESSION_COOKIE = "__Host-axo_session";
const FLOW_LIFETIME_SECONDS = 600;
const SESSION_LIFETIME_SECONDS = 60 * 60 * 24 * 30;

type OAuthEnvironment = Env & {
  OAUTH_CLIENT_ID?: string;
  OAUTH_CLIENT_SECRET?: string;
  SESSION_SECRET?: string;
};

type FlowCookie = { state: string; verifier: string; createdAt: number };
type SessionCookie = {
  accountId: string;
  sessionId: string;
  csrf: string;
  expiresAt: number;
};
type IdentityStub = { resolveAccount(): Promise<string> };
type AccountStub = {
  establishSession(accountId: string, sessionDigest: string, expiresAt: number, profile: { email: string | null; name: string | null }): Promise<void>;
  sessionProfile(accountId: string, sessionDigest: string, now: number): Promise<{ email: string | null; name: string | null } | null>;
  revokeSession(sessionDigest: string, now: number): Promise<void>;
  listHosts?(): Promise<unknown>;
  listHostSessions?(reference: unknown): Promise<unknown>;
  listPiEvents?(request: unknown): Promise<unknown>;
  revokeHost?(hostId: string, now?: number): Promise<void>;
  fetch?(request: Request): Promise<Response>;
  createPairing?(codeVerifier: string, pairingId: string, now: number, expiresAt: number): Promise<"created" | "collision" | "limited">;
  cancelPairing?(codeVerifier: string, pairingId: string): Promise<void>;
  redeemPairing?(input: {
    codeVerifier: string;
    pairingId: string;
    hostId: string;
    hostGeneration: string;
    credentialId: string;
    credentialVerifier: string;
    label: string;
    hostKind: string;
    now: number;
  }): Promise<{
    status: "invalid";
  } | {
    status: "linked";
    hostId: string;
    hostGeneration: string;
    credentialId: string;
    linkedAt: number;
  }>;
};
type PairingIndexStub = {
  reserve(verifier: string, accountId: string, pairingId: string, expiresAt: number, now: number): Promise<boolean>;
  lookup(verifier: string, now: number): Promise<{ accountId: string; pairingId: string; expiresAt: number } | null>;
};
type RateLimitStub = { consume(now: number, windowMs: number, maximum: number): Promise<boolean> };
export type AuthExports = Partial<{
  AxoIdentityIndex: { getByName(name: string): IdentityStub };
  AxoAccountManager: { getByName(name: string): AccountStub };
  AxoPairingIndex: { getByName(name: string): PairingIndexStub };
  AxoPairingRateLimit: { getByName(name: string): RateLimitStub };
}>;

export function authExports(value: unknown): AuthExports {
  const record = asRecord(value);
  if (!record) return {};
  return {
    AxoIdentityIndex: namespace(record.AxoIdentityIndex, isIdentityStub),
    AxoAccountManager: namespace(record.AxoAccountManager ?? record.AxoAccountDirectory, isAccountStub),
    AxoPairingIndex: namespace(record.AxoPairingIndex, isPairingIndexStub),
    AxoPairingRateLimit: namespace(record.AxoPairingRateLimit, isRateLimitStub),
  };
}

export async function startCloudflareLogin(
  request: Request,
  env: OAuthEnvironment,
): Promise<Response> {
  if (request.method !== "GET") return methodNotAllowed("GET");
  if (!configured(env)) return unavailable();

  const state = randomToken();
  const verifier = randomToken(48);
  const challenge = await sha256(verifier);
  const location = new URL(AUTHORIZATION_URL);
  location.searchParams.set("client_id", env.OAUTH_CLIENT_ID!);
  location.searchParams.set("redirect_uri", CALLBACK_URL);
  location.searchParams.set("response_type", "code");
  location.searchParams.set("scope", USERINFO_SCOPE);
  location.searchParams.set("state", state);
  location.searchParams.set("code_challenge", challenge);
  location.searchParams.set("code_challenge_method", "S256");

  const cookie = await sealCookie<FlowCookie>(env.SESSION_SECRET!, "oauth-flow", {
    state,
    verifier,
    createdAt: Date.now(),
  });
  return redirect(location.toString(), [
    `${OAUTH_COOKIE}=${cookie}; Path=/; Max-Age=${FLOW_LIFETIME_SECONDS}; Secure; HttpOnly; SameSite=Lax`,
  ]);
}

export async function completeCloudflareLogin(
  request: Request,
  env: OAuthEnvironment,
  exports: AuthExports,
  fetcher: typeof fetch = fetch,
): Promise<Response> {
  if (request.method !== "GET") return methodNotAllowed("GET");
  const cookiesToClear = [clearCookie(OAUTH_COOKIE)];
  if (!configured(env)) {
    recordApiEvent({ event: "oauth_callback_failure", stage: "configuration", reason: "configuration" });
    return unavailable(cookiesToClear, "oauth_configuration");
  }
  if (!exports.AxoIdentityIndex || !exports.AxoAccountManager) {
    recordApiEvent({ event: "oauth_callback_failure", stage: "durable_object_exports", reason: "configuration" });
    return unavailable(cookiesToClear, "oauth_durable_object_exports");
  }

  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const returnedState = url.searchParams.get("state");
  const flowToken = cookieValue(request.headers.get("Cookie"), OAUTH_COOKIE);
  if (!code || code.length > 4096 || !returnedState || returnedState.length > 256 || !flowToken)
    return unauthorized(cookiesToClear);

  const flow = await openCookie<FlowCookie>(env.SESSION_SECRET!, "oauth-flow", flowToken);
  if (!flow || Date.now() - flow.createdAt > FLOW_LIFETIME_SECONDS * 1000 || flow.createdAt > Date.now() + 60_000)
    return unauthorized(cookiesToClear);
  if (!constantTimeEqual(flow.state, returnedState)) return unauthorized(cookiesToClear);

  let failureStage:
    | "token_exchange"
    | "identity_resolve"
    | "session_persist"
    | "session_cookie_seal" = "token_exchange";
  try {
    const profile = await loadCloudflareProfile(code, flow.verifier, env, fetcher);
    failureStage = "identity_resolve";
    const identityKey = await sha256(`${CLOUDFLARE_ISSUER}\0${profile.subject}`);
    const accountId = await exports.AxoIdentityIndex.getByName(identityKey).resolveAccount();
    const sessionId = randomToken();
    const expiresAt = Date.now() + SESSION_LIFETIME_SECONDS * 1000;
    const digest = await hmac(env.SESSION_SECRET!, `session\0${sessionId}`);
    const account = exports.AxoAccountManager.getByName(accountId);
    failureStage = "session_persist";
    await account.establishSession(accountId, digest, expiresAt, {
      email: profile.email,
      name: profile.name,
    });

    failureStage = "session_cookie_seal";
    const sessionCookie = await sealCookie<SessionCookie>(env.SESSION_SECRET!, "web-session", {
      accountId,
      sessionId,
      csrf: randomToken(),
      expiresAt,
    });
    const response = redirect(`${AUTH_ORIGIN}/app`, [
      clearCookie(OAUTH_COOKIE),
      `${SESSION_COOKIE}=${sessionCookie}; Path=/; Max-Age=${SESSION_LIFETIME_SECONDS}; Secure; HttpOnly; SameSite=Lax`,
    ]);
    return response;
  } catch (error) {
    if (error instanceof OAuthProviderFailure) {
      recordApiEvent({
        event: "oauth_callback_failure",
        stage: error.stage,
        reason: error.reason,
        ...(error.status === undefined ? {} : { status: error.status }),
        ...(error.providerCode === undefined ? {} : { providerCode: error.providerCode }),
      });
      return unavailable(cookiesToClear, diagnosticCode(error));
    }

    recordApiEvent({ event: "oauth_callback_failure", stage: failureStage, reason: "operation_failed" });
    return unavailable(cookiesToClear, `oauth_${failureStage}_operation_failed`);
  }
}

export type AxoWebSession = { accountId: string; expiresAt: number; sessionDigest: string };

export async function requireAxoSession(
  request: Request,
  env: OAuthEnvironment,
  exports: AuthExports,
  requireCsrf: boolean,
): Promise<AxoWebSession | Response> {
  if (requireCsrf && request.headers.get("Origin") !== AUTH_ORIGIN)
    return json({ error: "Origin not allowed" }, 403);

  const session = await readSession(request, env);
  if (!session) return json({ error: "Sign in required" }, 401);
  if (requireCsrf && !constantTimeEqual(session.csrf, request.headers.get("X-Axo-CSRF") ?? ""))
    return json({ error: "CSRF check failed" }, 403);

  if (!exports.AxoAccountManager) return unavailable();
  try {
    const sessionDigest = await hmac(env.SESSION_SECRET!, `session\0${session.sessionId}`);
    const account = exports.AxoAccountManager.getByName(session.accountId);
    const profile = await account.sessionProfile(session.accountId, sessionDigest, Date.now());
    return profile
      ? { accountId: session.accountId, expiresAt: session.expiresAt, sessionDigest }
      : json({ error: "Sign in required" }, 401, [clearCookie(SESSION_COOKIE)]);
  } catch {
    return unavailable();
  }
}

export async function requireAxoAccount(
  request: Request,
  env: OAuthEnvironment,
  exports: AuthExports,
  requireCsrf: boolean,
): Promise<string | Response> {
  const session = await requireAxoSession(request, env, exports, requireCsrf);
  return session instanceof Response ? session : session.accountId;
}

export async function currentAxoSession(
  request: Request,
  env: OAuthEnvironment,
  exports: AuthExports,
): Promise<Response> {
  if (request.method !== "GET") return methodNotAllowed("GET");
  const session = await readSession(request, env);
  if (!session) return json({ authenticated: false }, 200);

  if (!exports.AxoAccountManager) return unavailable();
  const account = exports.AxoAccountManager.getByName(session.accountId);
  const profile = await account.sessionProfile(
    session.accountId,
    await hmac(env.SESSION_SECRET!, `session\0${session.sessionId}`),
    Date.now(),
  );
  if (!profile) return json({ authenticated: false }, 200, [clearCookie(SESSION_COOKIE)]);
  return json({
    authenticated: true,
    profile,
    csrfToken: session.csrf,
    expiresAt: new Date(session.expiresAt).toISOString(),
  });
}

export async function logoutAxoSession(
  request: Request,
  env: OAuthEnvironment,
  exports: AuthExports,
): Promise<Response> {
  if (request.method !== "POST") return methodNotAllowed("POST");
  const origin = request.headers.get("Origin");
  if (origin !== AUTH_ORIGIN) return json({ error: "Origin not allowed" }, 403, [clearCookie(SESSION_COOKIE)]);
  const session = await readSession(request, env);
  if (session) {
    if (!exports.AxoAccountManager) return unavailable();
    const csrf = request.headers.get("X-Axo-CSRF") ?? "";
    if (!constantTimeEqual(session.csrf, csrf))
      return json({ error: "CSRF check failed" }, 403);
    const digest = await hmac(env.SESSION_SECRET!, `session\0${session.sessionId}`);
    await exports.AxoAccountManager.getByName(session.accountId).revokeSession(digest, Date.now());
  }
  return new Response(null, {
    status: 204,
    headers: privateHeaders([clearCookie(SESSION_COOKIE)]),
  });
}

async function readSession(request: Request, env: OAuthEnvironment): Promise<SessionCookie | null> {
  if (!env.SESSION_SECRET) return null;
  const token = cookieValue(request.headers.get("Cookie"), SESSION_COOKIE);
  if (!token) return null;
  const session = await openCookie<SessionCookie>(env.SESSION_SECRET, "web-session", token);
  if (!session || !session.accountId || !session.sessionId || !session.csrf ||
      !Number.isSafeInteger(session.expiresAt) || session.expiresAt <= Date.now()) return null;
  return session;
}

function configured(env: OAuthEnvironment): boolean {
  return Boolean(env.OAUTH_CLIENT_ID && env.SESSION_SECRET &&
    new TextEncoder().encode(env.SESSION_SECRET).byteLength >= 32);
}

function namespace<T>(
  value: unknown,
  isStub: (candidate: unknown) => candidate is T,
): { getByName(name: string): T } | undefined {
  const record = asRecord(value);
  if (!record || typeof record.getByName !== "function") return undefined;
  const getByName = record.getByName;
  return {
    getByName(name) {
      const stub: unknown = Reflect.apply(getByName, value, [name]);
      if (!isStub(stub)) throw new Error("Missing Durable Object export");
      return stub;
    },
  };
}

function isIdentityStub(value: unknown): value is IdentityStub {
  return Boolean(asRecord(value) && typeof asRecord(value)!.resolveAccount === "function");
}

function isAccountStub(value: unknown): value is AccountStub {
  const record = asRecord(value);
  return Boolean(record && typeof record.establishSession === "function" &&
    typeof record.sessionProfile === "function" && typeof record.revokeSession === "function");
}

function isPairingIndexStub(value: unknown): value is PairingIndexStub {
  const record = asRecord(value);
  return Boolean(record && typeof record.reserve === "function" && typeof record.lookup === "function");
}

function isRateLimitStub(value: unknown): value is RateLimitStub {
  return Boolean(asRecord(value) && typeof asRecord(value)!.consume === "function");
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return (typeof value === "object" || typeof value === "function") && value !== null
    ? value as Record<string, unknown>
    : null;
}

function cookieValue(header: string | null, name: string): string | null {
  if (!header) return null;
  for (const part of header.split(";")) {
    const separator = part.indexOf("=");
    if (separator < 0 || part.slice(0, separator).trim() !== name) continue;
    return part.slice(separator + 1).trim() || null;
  }
  return null;
}

function clearCookie(name: string): string {
  return `${name}=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax`;
}

function redirect(location: string, cookies: string[]): Response {
  const headers = privateHeaders(cookies);
  headers.set("Location", location);
  return new Response(null, { status: 302, headers });
}

function json(body: unknown, status = 200, cookies: string[] = []): Response {
  const headers = privateHeaders(cookies);
  headers.set("Content-Type", "application/json; charset=utf-8");
  return new Response(JSON.stringify(body), { status, headers });
}

function unauthorized(cookies: string[]): Response {
  return json({ error: "Cloudflare sign-in could not be completed" }, 400, cookies);
}

function diagnosticCode(error: OAuthProviderFailure): string {
  return ["oauth", error.stage, error.reason, error.status, error.providerCode]
    .filter((part): part is string | number => part !== undefined)
    .join("_");
}

function unavailable(cookies: string[] = [], diagnostic?: string): Response {
  return json({
    error: "Cloudflare sign-in is unavailable",
    ...(diagnostic ? { diagnostic } : {}),
  }, 503, cookies);
}

function methodNotAllowed(allow: string): Response {
  const response = json({ error: "Method not allowed" }, 405);
  response.headers.set("Allow", allow);
  return response;
}

function privateHeaders(cookies: string[] = []): Headers {
  const headers = new Headers({ "Cache-Control": "private, no-store", "Pragma": "no-cache" });
  for (const cookie of cookies) headers.append("Set-Cookie", cookie);
  return headers;
}
