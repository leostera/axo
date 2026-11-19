import { authExports, json, requireAccount } from "../auth/account-access";
import { deviceLinkCommandSchema } from "../devices/linking";
import { hostDOName } from "../host-do";
import { boundedBody } from "./push";

/** An opaque exchange channel. The camera secret stays on the two devices. */
export async function deviceLinkMailbox(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const caller = await requireAccount(request, env, authExports(ctx.exports), "change");
  if (caller instanceof Response) return caller;
  if (caller.via !== "bearer") return json({ error: "Native sign-in required" }, 403);
  const result = await ctx.exports.AxoAccountDirectory.getByName(caller.accountId).deviceLinkMailbox(
    { accountId: caller.accountId, sessionDigest: caller.sessionDigest }, await boundedBody(request));
  return json(result.value, result.status);
}

/** Transport only: sign-in cannot grant a device approval or management authority. */
export async function linkDevice(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const caller = await requireAccount(request, env, authExports(ctx.exports), "change");
  if (caller instanceof Response) return caller;
  if (caller.via !== "bearer" || !await ctx.exports.AxoAccountDirectory.getByName(caller.accountId).verifyPushSession(caller.sessionDigest, Date.now()))
    return json({ error: "Native sign-in required" }, 403);
  const command = deviceLinkCommandSchema.safeParse(await boundedBody(request));
  if (!command.success) return json({ error: "Invalid device linking request" }, 400);
  const binding = command.data.operation === "redeem" ? command.data.claim
    : command.data.operation === "link" ? command.data.grant : command.data.revocation;
  if (binding.accountId !== caller.accountId) return json({ error: "Invalid device linking request" }, 403);
  const host = ctx.exports.AxoHostDO.getByName(hostDOName(caller.accountId, binding.hostId));
  const outcome = await host.linkDevice(command.data);
  if ("result" in outcome) return json(outcome.result);
  return json({ error: "Linking was not confirmed. Check the other device before trying again." }, 409);
}
