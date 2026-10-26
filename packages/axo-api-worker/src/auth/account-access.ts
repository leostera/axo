import { APP_ORIGIN, parseAuthConfiguration, type AuthEnvironment } from "./config";
import { cookieValue, parseSessionToken, sessionDigest, SESSION_COOKIE, type SessionKind } from "./session";

export { APP_ORIGIN };

export type AccountProfile = { email: string | null; name: string | null };

/** A request from a signed-in person, resolved to their Axo account. */
export type AccountCaller = {
  readonly accountId: string;
  readonly profile: AccountProfile;
  /** When this sign-in ends; relay connections end by then. */
  readonly expiresAt: number;
  /** Which credential carried the request: a browser's cookie or an app's bearer token. */
  readonly via: "cookie" | "bearer";
  /** The keyed hash identifying this sign-in, for revoking it. */
  readonly sessionDigest: string;
};

type IdentityStub = { resolveAccount(): Promise<string> };
type AccountStub = {
  establishSession(accountId: string, digest: string, kind: SessionKind, now: number, expiresAt: number, profile: AccountProfile): Promise<void>;
  verifySession(digest: string, now: number): Promise<{ profile: AccountProfile; expiresAt: number } | null>;
  revokeSession(digest: string): Promise<void>;
  createLoginCode(accountId: string, digest: string, challenge: string, now: number, expiresAt: number, profile: AccountProfile): Promise<void>;
  redeemLoginCode(digest: string, challenge: string, now: number): Promise<AccountProfile | null>;
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

export type CallerRequirement = "read" | "change";

/**
 * The account behind a request, or the response that refuses it.
 *
 * An app sends `Authorization: Bearer <token>`. A browser sends the session cookie, and browsers
 * attach cookies to cross-site requests too, so a cookie-authenticated request that changes
 * state or opens a relay must come from the app itself: browsers always send `Origin` on those,
 * and it must be the app's. A bearer token is never sent by a browser on its own, so it needs
 * no such check. If an `Authorization` header is present it alone decides: a bad one is refused,
 * never quietly replaced by a cookie.
 */
export async function requireAccount(
  request: Request,
  env: AuthEnvironment,
  exports: AuthExports,
  requirement: CallerRequirement,
): Promise<AccountCaller | Response> {
  const configuration = parseAuthConfiguration(env);
  if (!configuration || !exports.AxoAccountManager) return json({ error: "Sign-in is unavailable" }, 503);

  const header = request.headers.get("Authorization");
  const via = header !== null ? "bearer" : "cookie";
  const text = header !== null
    ? /^Bearer (\S+)$/.exec(header)?.[1] ?? null
    : cookieValue(request.headers.get("Cookie"), SESSION_COOKIE);
  const token = text === null ? null : parseSessionToken(text);
  if (!token) return json({ error: "Sign in required" }, 401);
  if (via === "cookie" && requirement === "change" && request.headers.get("Origin") !== APP_ORIGIN)
    return json({ error: "Origin not allowed" }, 403);

  try {
    const digest = await sessionDigest(configuration.sessionSecret, token);
    const session = await exports.AxoAccountManager.getByName(token.accountId).verifySession(digest, Date.now());
    if (!session) return json({ error: "Sign in required" }, 401);
    return { accountId: token.accountId, profile: session.profile, expiresAt: session.expiresAt, via, sessionDigest: digest };
  } catch {
    return json({ error: "Sign-in is unavailable" }, 503);
  }
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
    typeof record.verifySession === "function" && typeof record.redeemLoginCode === "function");
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

export function json(body: unknown, status = 200, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Cache-Control": "private, no-store",
      Pragma: "no-cache",
      "Content-Type": "application/json; charset=utf-8",
      ...extraHeaders,
    },
  });
}
