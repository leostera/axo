import { clientIdSchema, uuid } from "@axo/protocol";
import { hostIdSchema, hostListResultSchema } from "@axo/protocol/v1";
import { clientDOName, peerClientId } from "../client-do";
import { hostDOName } from "../host-do";
import { DIRECT_CLIENT_ROLE } from "../host-clients";
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

/**
 * The host's socket (RFD0018): authenticated with the host credential, and served by that host's
 * HostDO, which checks the credential with the account before it upgrades.
 */
export async function upgradeHostDaemon(
  request: Request,
  ctx: ExecutionContext,
  rawAccountId: string,
  rawHostId: string,
): Promise<Response> {
  if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket")
    return new Response("WebSocket required", { status: 426, headers: privateHeaders });
  if (request.headers.has("Origin")) return json({ error: "Origin not allowed" }, 403);
  const hostId = hostIdSchema.safeParse(rawHostId);
  const accountId = uuid.safeParse(rawAccountId);
  if (!hostId.success) return json({ error: "Invalid host" }, 400);
  if (!accountId.success) return json({ error: "Invalid account" }, 400);
  const credential = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(request.headers.get("Authorization") ?? "")?.[1];
  const credentialId = request.headers.get("X-Axo-Credential-Id") ?? "";
  if (!credential || !uuid.safeParse(credentialId).success) return json({ error: "Host authentication required" }, 401);
  return ctx.exports.AxoHostDO.getByName(hostDOName(accountId.data, hostId.data)).fetch(new Request("https://host.internal/daemon", {
    headers: {
      Upgrade: "websocket",
      "X-Axo-Role": "daemon",
      "X-Axo-Identity": accountId.data,
      "X-Axo-Expiry": String(Date.now() + 24 * 60 * 60 * 1000),
      "X-Axo-Machine": hostId.data,
      "X-Axo-Credential": credential,
      "X-Axo-Credential-Id": credentialId,
    },
  }));
}

/** How long a Mac's peers socket stays signed in; it signs in again with its credential, so a revoked Mac is refused within this. */
const PEERS_SIGN_IN_MS = 60 * 60 * 1000;

type HostAuthorizer = { authorizeHost(hostId: string, credentialId: string, credential: string): Promise<boolean> };

/**
 * A paired Mac following the account's other Macs (RFD0022): the same client socket a browser
 * tab opens, served by a ClientDO named for the Mac, but signed in with the host credential.
 * Pairing is the sign-in; a Mac can already run commands on the others through apps.
 */
export async function upgradeHostPeers(
  request: Request,
  ctx: ExecutionContext,
  rawAccountId: string,
  rawHostId: string,
): Promise<Response> {
  if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket")
    return new Response("WebSocket required", { status: 426, headers: privateHeaders });
  if (request.headers.has("Origin")) return json({ error: "Origin not allowed" }, 403);
  const hostId = hostIdSchema.safeParse(rawHostId);
  const accountId = uuid.safeParse(rawAccountId);
  if (!hostId.success) return json({ error: "Invalid host" }, 400);
  if (!accountId.success) return json({ error: "Invalid account" }, 400);
  const credential = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(request.headers.get("Authorization") ?? "")?.[1];
  const credentialId = request.headers.get("X-Axo-Credential-Id") ?? "";
  if (!credential || !uuid.safeParse(credentialId).success) return json({ error: "Host authentication required" }, 401);
  try {
    const account = ctx.exports.AxoAccountDirectory.getByName(accountId.data) as unknown as HostAuthorizer;
    if (!(await account.authorizeHost(hostId.data, credentialId, credential))) return json({ error: "Host authentication required" }, 401);
  } catch {
    return unavailable();
  }
  const clientId = peerClientId(hostId.data);
  return ctx.exports.AxoClientDO.getByName(clientDOName(accountId.data, clientId)).fetch(new Request("https://client.internal/", {
    headers: {
      Upgrade: "websocket",
      "X-Axo-Account": accountId.data,
      "X-Axo-Client": clientId,
      "X-Axo-Expiry": String(Date.now() + PEERS_SIGN_IN_MS),
    },
  }));
}

/**
 * A client's one socket (RFD0018): signed in to the account, and served by the ClientDO named by
 * the account and the client's own id (one per browser tab or app instance).
 */
export async function upgradeAccountClient(
  request: Request,
  env: PairingEnvironment,
  exports: AuthExports,
  ctx: ExecutionContext,
): Promise<Response> {
  if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket")
    return new Response("WebSocket required", { status: 426, headers: privateHeaders });
  const clientId = clientIdSchema.safeParse(new URL(request.url).searchParams.get("clientId"));
  if (!clientId.success) return json({ error: "Valid clientId required" }, 400);
  // The socket acts on the account's hosts, so it is held to the same rule as a change.
  const caller = await requireAccount(request, env, exports, "change");
  if (caller instanceof Response) return caller;
  return ctx.exports.AxoClientDO.getByName(clientDOName(caller.accountId, clientId.data)).fetch(new Request("https://client.internal/", {
    headers: {
      Upgrade: "websocket",
      "X-Axo-Account": caller.accountId,
      "X-Axo-Client": clientId.data,
      "X-Axo-Expiry": String(caller.expiresAt),
    },
  }));
}

/**
 * A paired Mac's socket on one of its account's hosts (RFD0032, protocol 3), for following that
 * host's Sessions (RFD0022) or reading back its own (RFD0027). Signed in with the Mac's host
 * credential, as `/peers` is; it is not a person, so it neither sees nor answers what a Mac asks.
 */
export async function upgradePeerHostClient(
  request: Request,
  ctx: ExecutionContext,
  rawAccountId: string,
  rawHostId: string,
  rawTargetId: string,
): Promise<Response> {
  if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket")
    return new Response("WebSocket required", { status: 426, headers: privateHeaders });
  if (request.headers.has("Origin")) return json({ error: "Origin not allowed" }, 403);
  const hostId = hostIdSchema.safeParse(rawHostId);
  const targetId = hostIdSchema.safeParse(rawTargetId);
  const accountId = uuid.safeParse(rawAccountId);
  if (!hostId.success || !targetId.success) return json({ error: "Invalid host" }, 400);
  if (!accountId.success) return json({ error: "Invalid account" }, 400);
  const credential = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(request.headers.get("Authorization") ?? "")?.[1];
  const credentialId = request.headers.get("X-Axo-Credential-Id") ?? "";
  if (!credential || !uuid.safeParse(credentialId).success) return json({ error: "Host authentication required" }, 401);
  try {
    const account = ctx.exports.AxoAccountDirectory.getByName(accountId.data) as unknown as HostAuthorizer & { clientHosts(): Promise<Array<{ hostId: string }>> };
    if (!(await account.authorizeHost(hostId.data, credentialId, credential))) return json({ error: "Host authentication required" }, 401);
    if (!(await account.clientHosts()).some((host) => host.hostId === targetId.data)) return json({ error: "Unknown host" }, 404);
  } catch {
    return unavailable();
  }
  return ctx.exports.AxoHostDO.getByName(hostDOName(accountId.data, targetId.data)).fetch(new Request("https://host.internal/", {
    headers: {
      Upgrade: "websocket",
      "X-Axo-Role": DIRECT_CLIENT_ROLE,
      "X-Axo-Account": accountId.data,
      "X-Axo-Machine": targetId.data,
      "X-Axo-Client": peerClientId(hostId.data),
      "X-Axo-Person": "0",
      "X-Axo-Expiry": String(Date.now() + PEERS_SIGN_IN_MS),
    },
  }));
}

/**
 * A client's socket on one of the account's hosts (RFD0032, protocol 3), signed in like the
 * account socket, and served by that host's HostDO. A host the account doesn't own, or revoked,
 * is refused.
 */
export async function upgradeHostClient(
  request: Request,
  env: PairingEnvironment,
  exports: AuthExports,
  ctx: ExecutionContext,
  rawHostId: string,
): Promise<Response> {
  if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket")
    return new Response("WebSocket required", { status: 426, headers: privateHeaders });
  const clientId = clientIdSchema.safeParse(new URL(request.url).searchParams.get("clientId"));
  if (!clientId.success) return json({ error: "Valid clientId required" }, 400);
  const hostId = uuid.safeParse(rawHostId);
  if (!hostId.success) return json({ error: "Invalid host" }, 400);
  const caller = await requireAccount(request, env, exports, "change");
  if (caller instanceof Response) return caller;
  try {
    const hosts = await exports.AxoAccountManager?.getByName(caller.accountId).clientHosts?.();
    if (!hosts) return unavailable();
    if (!hosts.some((host) => host.hostId === hostId.data)) return json({ error: "Unknown host" }, 404);
  } catch {
    return unavailable();
  }
  return ctx.exports.AxoHostDO.getByName(hostDOName(caller.accountId, hostId.data)).fetch(new Request("https://host.internal/", {
    headers: {
      Upgrade: "websocket",
      "X-Axo-Role": DIRECT_CLIENT_ROLE,
      "X-Axo-Account": caller.accountId,
      "X-Axo-Machine": hostId.data,
      "X-Axo-Client": clientId.data,
      "X-Axo-Person": "1",
      "X-Axo-Expiry": String(caller.expiresAt),
    },
  }));
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
