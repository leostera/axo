import { z } from "zod";
import {
  createProfileServer,
  serveProfileMessage,
  JSONRPCErrorException,
  type TypedJSONRPCServer,
  type ServiceMethods,
} from "@axo/protocol";
import type { Principal } from "../access";
import { boundedBody } from "./body";

export async function serveDiscovery(
  request: Request,
  principal: Principal,
  ctx: ExecutionContext,
): Promise<Response> {
  if (request.method !== "POST")
    return new Response("POST required", { status: 405 });
  const raw = await boundedBody(request);
  if (raw === null) return new Response("Frame limit", { status: 413 });
  const server = createProfileServer<Principal>();
  const typed: TypedJSONRPCServer<
    Pick<ServiceMethods, "axo.machine.list">,
    Principal
  > = server;
  typed.addMethod("axo.machine.list", async (params, caller) => {
    if (
      !z
        .object({})
        .strict()
        .safeParse(params ?? {}).success
    )
      throw new JSONRPCErrorException("Invalid params", -32602);
    const machines =
      await ctx.exports.AxoHostDirectory.getByName("private-fleet").list();
    if (caller.expiresAt <= Date.now())
      throw new JSONRPCErrorException("Access expired", -32002);
    return { machines };
  });
  const reply = await serveProfileMessage(server, raw, principal);
  return reply
    ? Response.json(reply, {
        headers: { "Cache-Control": "private, no-store" },
      })
    : new Response(null, { status: 204 });
}
