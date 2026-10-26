import { z } from "zod";
import { recordApiEvent } from "../observability";
import {
  json,
  requireAccount,
  type AccountProfile,
  type AuthExports,
} from "./account-access";
import { APP_ORIGIN, parseAuthConfiguration, type AuthConfiguration, type AuthEnvironment } from "./config";
import { constantTimeEqual, hmac, randomToken, seal, sha256, unseal } from "./crypto";
import { authorizationUrl, fetchIdentity, ProviderFailure } from "./oauth-cloudflare";
import { attempt } from "./rate-limit";
import {
  clearCookie,
  cookieValue,
  formatSessionToken,
  newSessionToken,
  SESSION_COOKIE,
  SESSION_LIFETIME_MS,
  sessionDigest,
  setCookie,
  } from "./session";

/** Where the phone app receives its one-time code. Fixed: no caller chooses a redirect. */
export const NATIVE_REDIRECT = "axo://auth/callback";
const LOGIN_COOKIE = "__Host-axo_login";
const FLOW_LIFETIME_MS = 10 * 60_000;
const LOGIN_CODE_LIFETIME_MS = 60_000;
const BODY_LIMIT_BYTES = 1024;

/** What sign-in remembers across the trip to Cloudflare; sealed into the OAuth `state`. */
const flowSchema = z.object({
  nonce: z.string().min(16).max(64),
  verifier: z.string().min(43).max(128),
  expiresAt: z.number().int(),
  client: z.discriminatedUnion("kind", [
    z.object({ kind: z.literal("web") }),
    z.object({ kind: z.literal("native"), challenge: z.string().regex(/^[A-Za-z0-9_-]{43}$/) }),
  ]),
});
type Flow = z.infer<typeof flowSchema>;

const exchangeSchema = z.object({
  code: z.string().min(1).max(256),
  verifier: z.string().regex(/^[A-Za-z0-9._~-]{43,128}$/),
}).strict();

/** `GET /api/auth/cloudflare/start`: sends the person to Cloudflare to prove who they are. */
export async function startLogin(request: Request, env: AuthEnvironment, exports: AuthExports): Promise<Response> {
  if (request.method !== "GET") return methodNotAllowed("GET");
  const config = parseAuthConfiguration(env);
  if (!config || !exports.AxoAccountManager || !exports.AxoIdentityIndex) return unavailable();

  const url = new URL(request.url);
  const kind = url.searchParams.get("client") ?? "web";
  const challenge = url.searchParams.get("challenge");
  const flowClient: Flow["client"] | null =
    kind === "web" && challenge === null ? { kind: "web" }
    : kind === "native" && challenge !== null && /^[A-Za-z0-9_-]{43}$/.test(challenge) ? { kind: "native", challenge }
    : null;
  if (!flowClient) return json({ error: "Invalid sign-in request" }, 400);

  const limited = await throttle(request, config, exports, "login-start", 20, 600);
  if (limited) return limited;

  const nonce = randomToken(16);
  const verifier = randomToken(48);
  const state = await seal(config.sessionSecret, "oauth-flow", {
    nonce, verifier, expiresAt: Date.now() + FLOW_LIFETIME_MS, client: flowClient,
  } satisfies Flow);
  recordApiEvent({ event: "sign_in", client: flowClient.kind, outcome: "started" });
  return redirect(authorizationUrl(config, state, await sha256(verifier)).toString(), [
    setCookie(LOGIN_COOKIE, nonce, FLOW_LIFETIME_MS / 1000),
  ]);
}

/** `GET /api/auth/cloudflare/callback`: Cloudflare sends the person back with a code. */
export async function completeLogin(
  request: Request,
  env: AuthEnvironment,
  exports: AuthExports,
  fetcher: typeof fetch = fetch,
): Promise<Response> {
  if (request.method !== "GET") return methodNotAllowed("GET");
  const config = parseAuthConfiguration(env);
  if (!config || !exports.AxoAccountManager || !exports.AxoIdentityIndex) return unavailable([clearCookie(LOGIN_COOKIE)]);

  const url = new URL(request.url);
  const flow = await openFlow(config, url.searchParams.get("state"), cookieValue(request.headers.get("Cookie"), LOGIN_COOKIE));
  if (!flow) return refused("web", [clearCookie(LOGIN_COOKIE)]);
  const done = [clearCookie(LOGIN_COOKIE)];

  // The person said no, or Cloudflare did: tell the app that started this, without an account.
  const code = url.searchParams.get("code");
  if (url.searchParams.has("error") || !code || code.length > 4096) {
    recordApiEvent({ event: "sign_in", client: flow.client.kind, outcome: "refused" });
    return flow.client.kind === "native"
      ? redirect(`${NATIVE_REDIRECT}?error=cancelled`, done)
      : redirect(`${APP_ORIGIN}/app?signin=cancelled`, done);
  }

  const limited = await throttle(request, config, exports, "login-callback", 30, 600);
  if (limited) return limited;

  let identity;
  try {
    identity = await fetchIdentity(config, code, flow.verifier, fetcher);
  } catch (error) {
    const stage = error instanceof ProviderFailure ? error.stage : "unknown";
    recordApiEvent({ event: "sign_in", client: flow.client.kind, outcome: "failed", stage });
    return unavailable(done);
  }

  try {
    // Accounts are keyed by the provider-qualified subject, never by email.
    const identityKey = await sha256(`${identity.issuer}\0${identity.subject}`);
    const accountId = await exports.AxoIdentityIndex.getByName(identityKey).resolveAccount();
    const profile: AccountProfile = { email: identity.email, name: identity.name };
    const account = exports.AxoAccountManager.getByName(accountId);
    const now = Date.now();

    if (flow.client.kind === "web") {
      const token = newSessionToken(accountId);
      const expiresAt = now + SESSION_LIFETIME_MS.web;
      await account.establishSession(accountId, await sessionDigest(config.sessionSecret, token), "web", now, expiresAt, profile);
      recordApiEvent({ event: "sign_in", client: "web", outcome: "completed" });
      return redirect(`${APP_ORIGIN}/app`, [
        ...done,
        setCookie(SESSION_COOKIE, formatSessionToken(token), SESSION_LIFETIME_MS.web / 1000),
      ]);
    }

    // The app gets a code that is worthless without the secret it kept: the token never rides a URL.
    const loginCode = `${accountId}.${randomToken(32)}`;
    await account.createLoginCode(
      accountId, await loginCodeDigest(config, loginCode), flow.client.challenge, now, now + LOGIN_CODE_LIFETIME_MS, profile,
    );
    recordApiEvent({ event: "sign_in", client: "native", outcome: "completed" });
    return redirect(`${NATIVE_REDIRECT}?code=${encodeURIComponent(loginCode)}`, done);
  } catch {
    recordApiEvent({ event: "sign_in", client: flow.client.kind, outcome: "failed", stage: "account" });
    return unavailable(done);
  }
}

/** `POST /api/auth/token`: the app trades its one-time code and its secret for a session. */
export async function exchangeLoginCode(request: Request, env: AuthEnvironment, exports: AuthExports): Promise<Response> {
  if (request.method !== "POST") return methodNotAllowed("POST");
  const config = parseAuthConfiguration(env);
  if (!config || !exports.AxoAccountManager) return unavailable();
  const limited = await throttle(request, config, exports, "login-token", 20, 300);
  if (limited) return limited;

  const body = await boundedBody(request);
  const parsed = exchangeSchema.safeParse(body === null ? null : safeJson(body));
  const codeParts = parsed.success ? parsed.data.code.split(".") : [];
  const accountId = codeParts[0];
  if (!parsed.success || codeParts.length !== 2 || !z.uuid().safeParse(accountId).success)
    return json({ error: "invalid_grant" }, 400);

  try {
    const account = exports.AxoAccountManager.getByName(accountId!);
    // A wrong verifier burns the code too: a guess gets one try.
    const profile = await account.redeemLoginCode(await loginCodeDigest(config, parsed.data.code), await sha256(parsed.data.verifier), Date.now());
    if (!profile) return json({ error: "invalid_grant" }, 400);
    const token = newSessionToken(accountId!);
    const now = Date.now();
    const expiresAt = now + SESSION_LIFETIME_MS.native;
    await account.establishSession(accountId!, await sessionDigest(config.sessionSecret, token), "native", now, expiresAt, profile);
    return json({
      token: formatSessionToken(token),
      accountId,
      profile,
      expiresAt: new Date(expiresAt).toISOString(),
    });
  } catch {
    return unavailable();
  }
}

/** `GET /api/auth/me`: who the caller is signed in as. */
export async function currentAccount(request: Request, env: AuthEnvironment, exports: AuthExports): Promise<Response> {
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

/** `POST /api/auth/logout`: ends this sign-in, and only this one. */
export async function logout(request: Request, env: AuthEnvironment, exports: AuthExports): Promise<Response> {
  if (request.method !== "POST") return methodNotAllowed("POST");
  const caller = await requireAccount(request, env, exports, "change");
  if (caller instanceof Response) return caller;
  try {
    await exports.AxoAccountManager!.getByName(caller.accountId).revokeSession(caller.sessionDigest);
  } catch {
    return unavailable();
  }
  const headers = new Headers({ "Cache-Control": "private, no-store" });
  headers.append("Set-Cookie", clearCookie(SESSION_COOKIE));
  return new Response(null, { status: 204, headers });
}

async function openFlow(config: AuthConfiguration, state: string | null, cookieNonce: string | null): Promise<Flow | null> {
  if (!state || state.length > 1024 || !cookieNonce) return null;
  const parsed = flowSchema.safeParse(await unseal(config.sessionSecret, "oauth-flow", state));
  if (!parsed.success) return null;
  const now = Date.now();
  const flow = parsed.data;
  // Only the browser that started this sign-in holds the nonce, so a callback link an attacker
  // started cannot sign anyone else in.
  if (flow.expiresAt < now || flow.expiresAt > now + FLOW_LIFETIME_MS + 60_000) return null;
  return constantTimeEqual(flow.nonce, cookieNonce) ? flow : null;
}

function loginCodeDigest(config: AuthConfiguration, code: string): Promise<string> {
  return hmac(config.sessionSecret, `login-code\0${code}`);
}

/** Global and per-source limits for one kind of attempt; the refusal, or null to go on. */
async function throttle(
  request: Request,
  config: AuthConfiguration,
  exports: AuthExports,
  name: string,
  perSource: number,
  global: number,
): Promise<Response | null> {
  const now = Date.now();
  const source = request.headers.get("CF-Connecting-IP") ?? "";
  const sourceKey = await hmac(config.sessionSecret, `source\0${source.length > 0 && source.length <= 64 ? source : "unknown"}`);
  for (const [key, maximum] of [[`${name}-global`, global], [`${name}-source-${sourceKey}`, perSource]] as const) {
    const result = await attempt(exports, key, now, maximum);
    if (result === "unavailable") return unavailable();
    if (result === "limited") return json({ error: "Too many sign-in attempts" }, 429, { "Retry-After": "60" });
  }
  return null;
}

async function boundedBody(request: Request): Promise<string | null> {
  if (Number(request.headers.get("Content-Length") ?? "0") > BODY_LIMIT_BYTES) return null;
  try {
    const body = await request.text();
    return new TextEncoder().encode(body).byteLength <= BODY_LIMIT_BYTES ? body : null;
  } catch {
    return null;
  }
}

function safeJson(text: string): unknown {
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return null;
  }
}

function redirect(location: string, cookies: string[]): Response {
  const headers = new Headers({ Location: location, "Cache-Control": "private, no-store", Pragma: "no-cache" });
  for (const cookie of cookies) headers.append("Set-Cookie", cookie);
  return new Response(null, { status: 302, headers });
}

function refused(client: "web" | "native", cookies: string[]): Response {
  recordApiEvent({ event: "sign_in", client, outcome: "refused" });
  const headers = new Headers({ "Content-Type": "application/json; charset=utf-8", "Cache-Control": "private, no-store" });
  for (const cookie of cookies) headers.append("Set-Cookie", cookie);
  return new Response(JSON.stringify({ error: "Sign-in could not be completed" }), { status: 400, headers });
}

function unavailable(cookies: string[] = []): Response {
  const headers = new Headers({ "Content-Type": "application/json; charset=utf-8", "Cache-Control": "private, no-store" });
  for (const cookie of cookies) headers.append("Set-Cookie", cookie);
  return new Response(JSON.stringify({ error: "Sign-in is unavailable" }), { status: 503, headers });
}

function methodNotAllowed(allow: string): Response {
  const response = json({ error: "Method not allowed" }, 405);
  response.headers.set("Allow", allow);
  return response;
}
