import { uuid } from "@axo/protocol";
import { authorize, type Principal } from "../access";
import { recordApiEvent } from "../observability";
import { serveDiscovery } from "./rpc";

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const path = new URL(request.url).pathname;
    const match = /^\/v1\/machines\/([^/]+)\/(daemon|client)$/.exec(path);
    if (path !== "/v1/rpc" && !match)
      return new Response("Not found", { status: 404 });
    const role = match?.[2] === "daemon" ? "daemon" : "client";
    let principal: Principal;
    try {
      principal = await authorize(request, role, env);
    } catch {
      recordApiEvent({ event: "access_denied", role });
      return new Response("Access required", { status: 401 });
    }
    if (path === "/v1/rpc") return serveDiscovery(request, principal, ctx);
    const machine = uuid.safeParse(match![1]);
    if (!machine.success)
      return new Response("Invalid machine", { status: 400 });
    if (
      request.method !== "GET" ||
      request.headers.get("Upgrade")?.toLowerCase() !== "websocket"
    )
      return new Response("WebSocket required", { status: 426 });
    if (request.headers.has("Origin"))
      return new Response("Native connections only", { status: 403 });
    const admission = await ctx.exports.AxoHostDirectory.getByName(
      "private-fleet",
    ).admit(machine.data, principal);
    if (admission !== "admitted")
      return new Response(admission, {
        status:
          admission === "capacity" ? 429 : admission === "conflict" ? 403 : 404,
      });
    if (principal.expiresAt <= Date.now())
      return new Response("Access expired", { status: 401 });
    // Construct fresh headers: public callers cannot spoof internal caller context.
    return ctx.exports.AxoHostRelay.getByName(machine.data).fetch(
      new Request("https://machine.internal/", {
        headers: {
          Upgrade: "websocket",
          "X-Axo-Role": role,
          "X-Axo-Identity": principal.identity,
          "X-Axo-Expiry": String(principal.expiresAt),
          "X-Axo-Machine": machine.data,
        },
      }),
    );
  },
} satisfies ExportedHandler<Env>;
