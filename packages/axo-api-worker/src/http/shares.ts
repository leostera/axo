import { accountShareListSchema, shareIdSchema } from "@axo/protocol";
import { requireAccount, type AuthExports } from "../auth/account-access";
import type { AuthEnvironment } from "../auth/config";

/**
 * The account's published shares: `GET /api/v1/account/shares` lists them, and
 * `POST /api/v1/account/shares/:share/delete` unpublishes one, so its link answers 404.
 */

const privateHeaders = { "Cache-Control": "private, no-store", Pragma: "no-cache" };

export async function serveAccountShares(request: Request, env: AuthEnvironment, exports: AuthExports): Promise<Response> {
  if (request.method !== "GET") return new Response("Method not allowed", { status: 405, headers: { Allow: "GET" } });
  const caller = await requireAccount(request, env, exports, "read");
  if (caller instanceof Response) return caller;
  const manager = exports.AxoAccountManager?.getByName(caller.accountId);
  if (!manager?.listShares) return unavailable();
  return Response.json(accountShareListSchema.parse(await manager.listShares()), { headers: privateHeaders });
}

export async function deleteAccountShare(request: Request, env: AuthEnvironment, exports: AuthExports, rawShareId: string): Promise<Response> {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405, headers: { Allow: "POST" } });
  const caller = await requireAccount(request, env, exports, "change");
  if (caller instanceof Response) return caller;
  const shareId = shareIdSchema.safeParse(rawShareId);
  if (!shareId.success) return Response.json({ error: "Not found" }, { status: 404, headers: privateHeaders });
  const manager = exports.AxoAccountManager?.getByName(caller.accountId);
  if (!manager?.deleteShare) return unavailable();
  // Another account's share is answered as a missing one: share IDs are public, ownership is not.
  return (await manager.deleteShare(shareId.data))
    ? new Response(null, { status: 204, headers: privateHeaders })
    : Response.json({ error: "Not found" }, { status: 404, headers: privateHeaders });
}

function unavailable(): Response {
  return Response.json({ error: "Account service unavailable" }, { status: 503, headers: privateHeaders });
}
