import { authExports, json, requireAccount } from "../auth/account-access";
import { pushRegistrationSchema } from "../push/registration";

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
