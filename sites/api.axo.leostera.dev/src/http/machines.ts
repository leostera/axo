import { machineListResultSchema } from "@axo/protocol";
import type { Principal } from "../access";

/** Read the same live directory/presence projection as axo.machine.list, never an HTTP cache. */
export async function serveMachines(request: Request, principal: Principal, ctx: ExecutionContext): Promise<Response> {
  const headers = { "Cache-Control": "private, no-store", Vary: "Cookie, Authorization, CF-Access-Jwt-Assertion" };
  if (request.method !== "GET") return new Response("GET required", { status: 405, headers: { ...headers, Allow: "GET" } });
  const machines = await ctx.exports.AxoHostDirectory.getByName("private-fleet").list();
  if (principal.expiresAt <= Date.now()) return new Response("Access expired", { status: 401, headers });
  const result = machineListResultSchema.safeParse({ machines });
  if (!result.success) return new Response("Directory unavailable", { status: 503, headers });
  return Response.json(result.data, { headers });
}
