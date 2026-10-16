import { hostIdSchema, hostListResultSchema, hostRefSchema, hostSessionsListResultSchema } from "@axo/protocol/v1";
import { edgePrincipal, type Principal } from "../access";

const privateNoStore = { "Cache-Control": "private, no-store" };

export async function serveHosts(
  request: Request,
  principal: Principal,
  ctx: ExecutionContext,
): Promise<Response> {
  if (request.method !== "GET") return new Response("GET required", { status: 405 });
  if (principal.expiresAt <= Date.now()) return new Response("Access expired", { status: 401, headers: privateNoStore });
  const result = await ctx.exports.AxoHostDirectory.getByName("private-fleet").listHosts();
  return Response.json(hostListResultSchema.parse(result), { headers: privateNoStore });
}

export async function serveHostSessions(
  request: Request,
  principal: Principal,
  ctx: ExecutionContext,
  rawHostId: string,
): Promise<Response> {
  if (request.method !== "GET") return new Response("GET required", { status: 405 });
  if (principal.expiresAt <= Date.now()) return new Response("Access expired", { status: 401, headers: privateNoStore });
  const hostId = hostIdSchema.safeParse(rawHostId);
  const hostGeneration = new URL(request.url).searchParams.get("hostGeneration");
  const reference = hostRefSchema.safeParse({ hostId: rawHostId, hostGeneration });
  if (!hostId.success || !reference.success) return new Response("Valid hostId and hostGeneration required", { status: 400, headers: privateNoStore });

  try {
    const result = await ctx.exports.AxoHostDirectory.getByName("private-fleet").listHostSessions(reference.data);
    if (!result) return new Response("Host not found", { status: 404, headers: privateNoStore });
    return Response.json(hostSessionsListResultSchema.parse(result), { headers: privateNoStore });
  } catch (error) {
    if (error instanceof Error && error.message === "Host generation conflict") {
      return new Response("Host generation is stale", { status: 409, headers: privateNoStore });
    }
    throw error;
  }
}

export async function authorizeHttpHostClient(_request: Request, _env: Env): Promise<Principal | Response> {
  return edgePrincipal("client");
}
