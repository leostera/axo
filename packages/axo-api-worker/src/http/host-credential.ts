import { uuid } from "@axo/protocol";
import { hostIdSchema } from "@axo/protocol/v1";

/** What this route needs from the account's directory: the checks a Mac's sockets use. */
type HostRevoker = {
  authorizeHost(hostId: string, credentialId: string, credential: string): Promise<boolean>;
  revokeHost(hostId: string, now?: number): Promise<void> | void;
};
type Exports = { AxoAccountDirectory: { getByName(name: string): unknown } };

const privateHeaders = { "Cache-Control": "private, no-store", Pragma: "no-cache" };

function json(body: unknown, status: number): Response {
  return Response.json(body, { status, headers: privateHeaders });
}

/**
 * `POST /api/v1/accounts/:account/hosts/:host/credential/revoke` (RFD0074): a Mac that stops
 * using its credential, because it was unlinked or linked to another account, revokes it with the
 * credential itself, as the person's revoke would. `204` once revoked; `401` when the credential
 * is not the host's current one (replaced by a later link, revoked already, or wrong), which the
 * Mac takes as done. The Mac serializes this against its own redemptions, which are the only
 * ones that replace this host's credential.
 */
export async function revokeHostCredential(
  request: Request,
  ctx: ExecutionContext,
  rawAccountId: string,
  rawHostId: string,
): Promise<Response> {
  if (request.method !== "POST")
    return new Response(null, { status: 405, headers: { ...privateHeaders, Allow: "POST" } });
  if (request.headers.has("Origin")) return json({ error: "Origin not allowed" }, 403);
  const accountId = uuid.safeParse(rawAccountId);
  const hostId = hostIdSchema.safeParse(rawHostId);
  if (!accountId.success || !hostId.success) return json({ error: "Invalid host" }, 400);
  const credential = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(request.headers.get("Authorization") ?? "")?.[1];
  const credentialId = request.headers.get("X-Axo-Credential-Id") ?? "";
  if (!credential || !uuid.safeParse(credentialId).success) return json({ error: "Host authentication required" }, 401);
  const account = (ctx.exports as unknown as Exports).AxoAccountDirectory.getByName(accountId.data) as HostRevoker;
  if (!(await account.authorizeHost(hostId.data, credentialId, credential)))
    return json({ error: "Host authentication required" }, 401);
  await account.revokeHost(hostId.data, Date.now());
  console.log(JSON.stringify({ event: "host.credential_revoked", accountId: accountId.data, hostId: hostId.data }));
  return new Response(null, { status: 204, headers: privateHeaders });
}
