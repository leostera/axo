import { parseAccessConfiguration, verifyAccessIdentity, type AccessEnvironment } from "./access-identity";
import { sha256 } from "./crypto";

/** The web app's origin. Browser requests that change state or open a relay must come from it. */
export const APP_ORIGIN = "https://axo.leostera.dev";

export type AccountProfile = { email: string | null; name: string | null };

/** A request from a person Access verified, resolved to their Axo account. */
export type AccountCaller = {
  readonly accountId: string;
  readonly profile: AccountProfile;
  /** When the Access assertion expires; relay connections end by then. */
  readonly expiresAt: number;
};

type IdentityStub = { resolveAccount(): Promise<string> };
type AccountStub = {
  recordSignIn(accountId: string, profile: AccountProfile): Promise<void>;
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

/**
 * Browsers attach cookies to cross-site requests, so a request that changes state or opens a
 * relay must prove it came from the app: browsers always send `Origin` on such requests, and
 * it must be the app's. Native clients send no `Origin`, and must then carry no cookies either,
 * so a cookie can never authorize a request whose origin is unknown.
 */
export function isCrossSiteRequest(request: Request): boolean {
  const origin = request.headers.get("Origin");
  if (origin !== null) return origin !== APP_ORIGIN;
  return request.headers.has("Cookie");
}

export type CallerRequirement = "read" | "change";

/** The account behind a request, or the response that refuses it. */
export async function requireAccount(
  request: Request,
  env: AccessEnvironment,
  exports: AuthExports,
  requirement: CallerRequirement,
): Promise<AccountCaller | Response> {
  if (requirement === "change" && isCrossSiteRequest(request))
    return json({ error: "Origin not allowed" }, 403);
  const configuration = parseAccessConfiguration(env);
  if (!configuration || !exports.AxoIdentityIndex || !exports.AxoAccountManager)
    return json({ error: "Sign-in is unavailable" }, 503);
  const identity = await verifyAccessIdentity(request, configuration);
  if (!identity) return json({ error: "Sign in required" }, 401);
  try {
    // Accounts are keyed by the issuer-qualified subject, never by email.
    const identityKey = await sha256(`${identity.issuer}\0${identity.subject}`);
    const accountId = await exports.AxoIdentityIndex.getByName(identityKey).resolveAccount();
    const profile = { email: identity.email, name: null };
    await exports.AxoAccountManager.getByName(accountId).recordSignIn(accountId, profile);
    return { accountId, profile, expiresAt: identity.expiresAt };
  } catch {
    return json({ error: "Sign-in is unavailable" }, 503);
  }
}

/** `GET /api/auth/me`: who the app is signed in as. */
export async function currentAccount(request: Request, env: AccessEnvironment, exports: AuthExports): Promise<Response> {
  if (request.method !== "GET") return methodNotAllowed("GET");
  const caller = await requireAccount(request, env, exports, "read");
  if (caller instanceof Response) return caller;
  return json({
    authenticated: true,
    accountId: caller.accountId,
    profile: caller.profile,
    expiresAt: new Date(caller.expiresAt).toISOString(),
  });
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
  return Boolean(record && typeof record.recordSignIn === "function");
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

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Cache-Control": "private, no-store",
      Pragma: "no-cache",
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

function methodNotAllowed(allow: string): Response {
  const response = json({ error: "Method not allowed" }, 405);
  response.headers.set("Allow", allow);
  return response;
}
