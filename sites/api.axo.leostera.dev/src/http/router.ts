import { Hono, type Context } from "hono";
import { uuid } from "@axo/protocol";
import { authorize, type Principal } from "../access";
import { recordApiEvent } from "../observability";
import { serveDiscovery } from "./rpc";
import { serveMachines } from "./machines";

type Api = { Bindings: Env };
const app = new Hono<Api>();

async function authorizeCaller(context: Context<Api>, role: "client" | "daemon"): Promise<Principal | Response> {
  try { return await authorize(context.req.raw, role, context.env); }
  catch {
    recordApiEvent({ event: "access_denied", role });
    return new Response("Access required", { status: 401, headers: { "Cache-Control": "private, no-store" } });
  }
}

app.all("/v1/rpc", async context => {
  const principal = await authorizeCaller(context, "client");
  if (principal instanceof Response) return principal;
  return serveDiscovery(context.req.raw, principal, context.executionCtx as ExecutionContext);
});

app.all("/v1/machines/", async context => {
  const principal = await authorizeCaller(context, "client");
  if (principal instanceof Response) return principal;
  return serveMachines(context.req.raw, principal, context.executionCtx as ExecutionContext);
});

app.all("/v1/machines/:machine/:role", async context => {
  const role = context.req.param("role");
  if (role !== "daemon" && role !== "client") return context.text("Not found", 404);
  const principal = await authorizeCaller(context, role);
  if (principal instanceof Response) return principal;
  const machine = uuid.safeParse(context.req.param("machine"));
  if (!machine.success) return context.text("Invalid machine", 400);
  const request = context.req.raw;
  if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
    return context.text("WebSocket required", 426);
  }
  if (request.headers.has("Origin")) return context.text("Native connections only", 403);
  const ctx = context.executionCtx as ExecutionContext;
  const admission = await ctx.exports.AxoHostDirectory.getByName("private-fleet").admit(machine.data, principal);
  if (admission !== "admitted") {
    return new Response(admission, { status: admission === "capacity" ? 429 : admission === "conflict" ? 403 : 404 });
  }
  if (principal.expiresAt <= Date.now()) return context.text("Access expired", 401);
  // Fresh headers only: public callers cannot spoof the trusted internal context.
  return ctx.exports.AxoHostRelay.getByName(machine.data).fetch(new Request("https://machine.internal/", {
    headers: {
      Upgrade: "websocket",
      "X-Axo-Role": role,
      "X-Axo-Identity": principal.identity,
      "X-Axo-Expiry": String(principal.expiresAt),
      "X-Axo-Machine": machine.data,
    },
  }));
});

app.notFound(context => context.text("Not found", 404));
// Hono's default exception logger is deliberately replaced: no payload-bearing stack traces.
app.onError(() => new Response("Service unavailable", { status: 503, headers: { "Cache-Control": "private, no-store" } }));
export default app;
