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
import { hostV1Methods, hostV1Results } from "@axo/protocol/v1";

type HostDiscoveryMethods = {
  "axo.host.list": (
    params: z.input<typeof hostV1Methods["axo.host.list"]>,
  ) => z.output<typeof hostV1Results["axo.host.list"]>;
  "axo.host.sessions.list": (
    params: z.input<typeof hostV1Methods["axo.host.sessions.list"]>,
  ) => z.output<typeof hostV1Results["axo.host.sessions.list"]>;
};

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
    Pick<ServiceMethods, "axo.machine.list"> & HostDiscoveryMethods,
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
  typed.addMethod("axo.host.list", async (params, caller) => {
    if (!hostV1Methods["axo.host.list"].safeParse(params ?? {}).success)
      throw new JSONRPCErrorException("Invalid params", -32602);
    if (caller.expiresAt <= Date.now())
      throw new JSONRPCErrorException("Access expired", -32002);
    return ctx.exports.AxoHostDirectory.getByName("private-fleet").listHosts();
  });
  typed.addMethod("axo.host.sessions.list", async (params, caller) => {
    const parsed = hostV1Methods["axo.host.sessions.list"].safeParse(params);
    if (!parsed.success) throw new JSONRPCErrorException("Invalid params", -32602);
    if (caller.expiresAt <= Date.now())
      throw new JSONRPCErrorException("Access expired", -32002);
    try {
      const result = await ctx.exports.AxoHostDirectory
        .getByName("private-fleet")
        .listHostSessions(parsed.data);
      if (!result) throw new JSONRPCErrorException("Host not found", -32004);
      return result;
    } catch (error) {
      if (error instanceof JSONRPCErrorException) throw error;
      if (error instanceof Error && error.message === "Host generation conflict")
        throw new JSONRPCErrorException("Host generation conflict", -32002);
      throw error;
    }
  });
  const reply = await serveProfileMessage(server, raw, principal);
  return reply
    ? Response.json(reply, {
        headers: { "Cache-Control": "private, no-store" },
      })
    : new Response(null, { status: 204 });
}
