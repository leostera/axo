import { authExports, json, requireAccount } from "../auth/account-access";
import { pushRegistrationSchema } from "../push/registration";
import { deviceProofSchema } from "@axo/protocol";
import { hostDOName } from "../host-do";
import { z } from "zod";

/** Person-owned native registration only. No token-bearing URLs, response bodies or error text. */
export async function registerPush(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const caller = await requireAccount(request, env, authExports(ctx.exports), "change");
  if (caller instanceof Response) return caller;
  if (caller.via !== "bearer") return json({ error: "Native sign-in required" }, 403);
  const body = await boundedBody(request);
  const parsed = pushRegistrationSchema.safeParse(body);
  if (!parsed.success) return json({ error: "Invalid notification registration" }, 400);
  const result = await ctx.exports.AxoPushRegistry.getByName("sandbox-v1").register({
    accountId: caller.accountId, sessionDigest: caller.sessionDigest, expiresAt: caller.expiresAt,
  }, parsed.data);
  if (result === "limited") return json({ error: "Notification registration limit" }, 429);
  if (result !== "saved") return json({ error: "Notification registration changed" }, 409);
  return json({ revision: parsed.data.revision });
}

export async function notificationHistory(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  if (request.method !== "GET") return json({ error: "Method not allowed" }, 405);
  const caller = await requireAccount(request, env, authExports(ctx.exports), "read");
  if (caller instanceof Response) return caller;
  return json({ notifications: await ctx.exports.AxoPushRegistry.getByName("sandbox-v1").notifications(caller.accountId) });
}

export async function notificationRequest(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const caller = await requireAccount(request, env, authExports(ctx.exports), "change");
  if (caller instanceof Response) return caller;
  if (caller.via !== "bearer" || !await ctx.exports.AxoAccountDirectory.getByName(caller.accountId).verifyPushSession(caller.sessionDigest, Date.now()))
    return json({ error: "Native sign-in required" }, 403);
  const common = { hostId: z.uuid(), requestId: z.uuid() };
  const parsed = z.discriminatedUnion("operation", [
    z.strictObject({ ...common, operation: z.literal("read") }),
    z.strictObject({ ...common, operation: z.literal("answer"), action: z.enum(["accept", "decline"]),
      digest: z.string().regex(/^[a-f0-9]{64}$/), expiresAt: z.number().int().positive(), device: deviceProofSchema.optional() }),
  ]).safeParse(await boundedBody(request));
  if (!parsed.success) return json({ error: "Invalid notification request" }, 400);
  const { hostId, requestId } = parsed.data;
  const host = ctx.exports.AxoHostDO.getByName(hostDOName(caller.accountId, hostId));
  if (parsed.data.operation === "read") {
    const current = await host.notificationQuestion(requestId);
    return current ? json(current) : json({ error: "Request is no longer pending" }, 409);
  }
  const { operation: _operation, hostId: _host, ...answer } = parsed.data;
  const outcome = await host.answerNotification(answer);
  if ("result" in outcome) return json(outcome.result);
  const settled = [-32011, -32002, -32005].includes(outcome.error.code);
  return json({ error: settled ? "Request changed or is no longer pending" : "Answer was not confirmed; review in Axo" }, settled ? 409 : 422);
}

async function boundedBody(request: Request): Promise<unknown> {
  if (!request.body) return null;
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.length;
      if (length > 8192) { await reader.cancel(); return null; }
      if (value.length > 0) chunks.push(value);
    }
    const bytes = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch { return null; }
  finally { reader.releaseLock(); }
}
