import { uuid } from "@axo/protocol";
import {
  hostIdSchema,
  sessionIdSchema,
  hostRefSchema,
  hostListResultSchema,
  hostSessionsListResultSchema,
} from "@axo/protocol/v1";
import { sessionEventPageResultSchema } from "../session-history";
import { requireAccount, type AuthExports } from "../auth/account-access";
import type { AuthEnvironment } from "../auth/config";

const privateHeaders = { "Cache-Control": "private, no-store", Pragma: "no-cache" };
type PairingEnvironment = AuthEnvironment;

export async function serveAccountHosts(request: Request, env: PairingEnvironment, exports: AuthExports): Promise<Response> {
  if (request.method !== "GET") return methodNotAllowed("GET");
  const caller = await requireAccount(request, env, exports, "read");
  if (caller instanceof Response) return caller;
  const { accountId } = caller;
  try {
    const manager = exports.AxoAccountManager?.getByName(accountId);
    if (!manager?.listHosts) return unavailable();
    return Response.json(hostListResultSchema.parse(await manager.listHosts()), { headers: privateHeaders });
  } catch {
    return unavailable();
  }
}

export async function serveAccountHostSessions(
  request: Request,
  env: PairingEnvironment,
  exports: AuthExports,
  rawHostId: string,
): Promise<Response> {
  if (request.method !== "GET") return methodNotAllowed("GET");
  const caller = await requireAccount(request, env, exports, "read");
  if (caller instanceof Response) return caller;
  const { accountId } = caller;
  const hostId = hostIdSchema.safeParse(rawHostId);
  const hostGeneration = new URL(request.url).searchParams.get("hostGeneration");
  const reference = hostRefSchema.safeParse({ hostId: rawHostId, hostGeneration });
  if (!hostId.success || !reference.success)
    return json({ error: "Valid hostId and hostGeneration required" }, 400);
  try {
    const manager = exports.AxoAccountManager?.getByName(accountId);
    if (!manager?.listHostSessions) return unavailable();
    const result = await manager.listHostSessions(reference.data);
    if (!result) return json({ error: "Host not found" }, 404);
    return Response.json(hostSessionsListResultSchema.parse(result), { headers: privateHeaders });
  } catch (error) {
    if (error instanceof Error && error.message === "Host generation conflict")
      return json({ error: "Host generation is stale" }, 409);
    return unavailable();
  }
}

export async function serveAccountHostEvents(
  request: Request,
  env: PairingEnvironment,
  exports: AuthExports,
  rawHostId: string,
  rawSessionId: string,
): Promise<Response> {
  if (request.method !== "GET") return methodNotAllowed("GET");
  const caller = await requireAccount(request, env, exports, "read");
  if (caller instanceof Response) return caller;
  const { accountId } = caller;
  const hostId = uuid.safeParse(rawHostId);
  const sessionId = sessionIdSchema.safeParse(rawSessionId);
  if (!hostId.success || !sessionId.success)
    return json({ error: "Valid host and Session IDs required" }, 400);

  const url = new URL(request.url);
  const allowed = new Set(["before", "limit"]);
  if ([...url.searchParams.keys()].some(key => !allowed.has(key)))
    return json({ error: "Unsupported query parameter" }, 400);
  const beforeText = url.searchParams.get("before");
  const limitText = url.searchParams.get("limit");
  const before = beforeText === null ? 0 : Number(beforeText);
  const limit = limitText === null ? 20 : Number(limitText);
  if (!Number.isSafeInteger(before) || before < 0 || String(before) !== (beforeText ?? "0") ||
      !Number.isSafeInteger(limit) || limit < 1 || limit > 50 || String(limit) !== (limitText ?? "20"))
    return json({ error: "Invalid event page cursor or limit" }, 400);

  try {
    const manager = exports.AxoAccountManager?.getByName(accountId);
    if (!manager?.listPiEvents) return unavailable();
    const page = sessionEventPageResultSchema.parse(await manager.listPiEvents({
      hostId: hostId.data,
      sessionId: sessionId.data,
      before,
      limit,
    }));
    return Response.json(page, { headers: privateHeaders });
  } catch (error) {
    if (error instanceof Error && error.message === "Host not found")
      return json({ error: "Host not found" }, 404);
    return unavailable();
  }
}

export async function revokeAccountHost(
  request: Request,
  env: PairingEnvironment,
  exports: AuthExports,
  rawHostId: string,
): Promise<Response> {
  if (request.method !== "POST") return methodNotAllowed("POST");
  const caller = await requireAccount(request, env, exports, "change");
  if (caller instanceof Response) return caller;
  const { accountId } = caller;
  const hostId = hostIdSchema.safeParse(rawHostId);
  if (!hostId.success) return json({ error: "Invalid host" }, 400);
  try {
    const manager = exports.AxoAccountManager?.getByName(accountId);
    if (!manager?.revokeHost) return unavailable();
    await manager.revokeHost(hostId.data, Date.now());
    return new Response(null, { status: 204, headers: privateHeaders });
  } catch {
    return unavailable();
  }
}

export async function upgradeAccountHostRelay(
  request: Request,
  env: PairingEnvironment,
  exports: AuthExports,
  role: "client" | "daemon",
  rawHostId: string,
  rawAccountId?: string,
): Promise<Response> {
  if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket")
    return new Response("WebSocket required", { status: 426, headers: privateHeaders });
  const hostId = hostIdSchema.safeParse(rawHostId);
  if (!hostId.success) return json({ error: "Invalid host" }, 400);

  let accountId: string;
  let expiresAt: number;
  let credential: string | undefined;
  let credentialId: string | undefined;
  if (role === "client") {
    // Opening a relay acts on the account's hosts, so it is held to the same rule as a change.
    const caller = await requireAccount(request, env, exports, "change");
    if (caller instanceof Response) return caller;
    accountId = caller.accountId;
    expiresAt = caller.expiresAt;
  } else {
    if (request.headers.has("Origin")) return json({ error: "Origin not allowed" }, 403);
    const parsedAccountId = uuid.safeParse(rawAccountId);
    if (!parsedAccountId.success) return json({ error: "Invalid account" }, 400);
    accountId = parsedAccountId.data;
    const authorization = request.headers.get("Authorization") ?? "";
    const match = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(authorization);
    credential = match?.[1];
    credentialId = request.headers.get("X-Axo-Credential-Id") ?? "";
    if (!credential || !uuid.safeParse(credentialId).success) return json({ error: "Host authentication required" }, 401);
    // The account manager checks revocation and the keyed credential verifier before upgrading.
    expiresAt = Date.now() + 24 * 60 * 60 * 1000;
  }

  const manager = exports.AxoAccountManager?.getByName(accountId);
  if (!manager?.fetch) return unavailable();
  const headers = new Headers({
    Upgrade: "websocket",
    "X-Axo-Role": role,
    "X-Axo-Identity": accountId,
    "X-Axo-Expiry": String(expiresAt),
    "X-Axo-Machine": hostId.data,
  });
  if (credential) headers.set("X-Axo-Credential", credential);
  if (credentialId) headers.set("X-Axo-Credential-Id", credentialId);
  return manager.fetch(new Request("https://account.internal/relay", { headers }));
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status, headers: privateHeaders });
}
function unavailable(): Response {
  return json({ error: "Account service is temporarily unavailable" }, 503);
}
function methodNotAllowed(allow: string): Response {
  const response = json({ error: "Method not allowed" }, 405);
  response.headers.set("Allow", allow);
  return response;
}
