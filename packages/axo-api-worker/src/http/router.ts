import { Hono, type Context } from "hono";
import { uuid } from "@axo/protocol";
import { edgePrincipal, type Principal } from "../access";
import { serveDiscovery } from "./rpc";
import { authExports } from "../auth/account-access";
import { completeLogin, currentAccount, exchangeLoginCode, logout, startLogin } from "../auth/login";
import { serveMachines } from "./machines";
import { authorizeHttpHostClient, serveHostSessions, serveHosts } from "./hosts";
import { createHostPairing, redeemHostPairing } from "../auth/pairing";
import { revokeAccountHost, serveAccountHosts, upgradeAccountClient, upgradeHostClient, upgradeHostDaemon, upgradeHostPeers, upgradePeerHostClient } from "./account-hosts";
import { serveAccountAssets, serveHostAssets, type AssetRoute } from "./assets";
import { completeConnectionSignIn, serveApps, startConnectionSignIn, type AppsRoute } from "./apps";

type Api = { Bindings: Env };
const app = new Hono<Api>();
const APP_ORIGIN = "https://axo.leostera.dev";
const CORS_METHODS = "GET, POST, OPTIONS";
const CORS_HEADERS = "Content-Type";

const corsMiddleware = async (context: Context<Api>, next: () => Promise<void>) => {
  const origin = context.req.header("Origin");
  if (context.req.method === "OPTIONS") {
    if (origin !== APP_ORIGIN) return new Response(null, { status: 403 });
    const requestedMethod = context.req.header("Access-Control-Request-Method");
    if (!requestedMethod || !CORS_METHODS.split(", ").includes(requestedMethod))
      return new Response(null, { status: 405 });
    const requestedHeaders = context.req.header("Access-Control-Request-Headers");
    if (requestedHeaders && requestedHeaders.split(",").some((header) =>
      !CORS_HEADERS.toLowerCase().split(", ").includes(header.trim().toLowerCase()),
    )) return new Response(null, { status: 403 });
    return new Response(null, {
      status: 204,
      headers: {
        "Access-Control-Allow-Origin": APP_ORIGIN,
        "Access-Control-Allow-Credentials": "true",
        "Access-Control-Allow-Methods": CORS_METHODS,
        "Access-Control-Allow-Headers": CORS_HEADERS,
        "Access-Control-Max-Age": "600",
        "Vary": "Origin, Access-Control-Request-Method, Access-Control-Request-Headers",
      },
    });
  }

  await next();
  if (origin !== APP_ORIGIN || context.res.status === 101) return;
  const response = context.res;
  const headers = new Headers(response.headers);
  headers.set("Access-Control-Allow-Origin", APP_ORIGIN);
  headers.set("Access-Control-Allow-Credentials", "true");
  const vary = new Set((headers.get("Vary") ?? "").split(",").map((value) => value.trim()).filter(Boolean));
  vary.add("Origin");
  headers.set("Vary", [...vary].join(", "));
  context.res = new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
};

app.use("/v1/*", corsMiddleware);
app.use("/api/v1/*", corsMiddleware);

async function authorizeCaller(_context: Context<Api>, role: "client" | "daemon"): Promise<Principal | Response> {
  return edgePrincipal(role);
}

app.all("/api/auth/cloudflare/start", context =>
  startLogin(
    context.req.raw,
    context.env,
    authExports((context.executionCtx as ExecutionContext).exports),
  ),
);

app.all("/api/auth/cloudflare/callback", context =>
  completeLogin(
    context.req.raw,
    context.env,
    authExports((context.executionCtx as ExecutionContext).exports),
  ),
);

app.all("/api/auth/token", context =>
  exchangeLoginCode(
    context.req.raw,
    context.env,
    authExports((context.executionCtx as ExecutionContext).exports),
  ),
);

app.all("/api/auth/me", context =>
  currentAccount(
    context.req.raw,
    context.env,
    authExports((context.executionCtx as ExecutionContext).exports),
  ),
);

app.all("/api/auth/logout", context =>
  logout(
    context.req.raw,
    context.env,
    authExports((context.executionCtx as ExecutionContext).exports),
  ),
);

app.all("/api/v1/account/host-pairings", context =>
  createHostPairing(
    context.req.raw,
    context.env,
    authExports((context.executionCtx as ExecutionContext).exports),
  ),
);

app.all("/api/v1/host-pairings/redeem", context =>
  redeemHostPairing(
    context.req.raw,
    context.env,
    authExports((context.executionCtx as ExecutionContext).exports),
  ),
);

app.all("/api/v1/account/hosts", context =>
  serveAccountHosts(
    context.req.raw,
    context.env,
    authExports((context.executionCtx as ExecutionContext).exports),
  ),
);

app.all("/api/v1/account/hosts/:host/revoke", context =>
  revokeAccountHost(
    context.req.raw,
    context.env,
    authExports((context.executionCtx as ExecutionContext).exports),
    context.req.param("host"),
  ),
);

// Apps (RFD0016): the Apps page, and the browser side of a third-party sign-in.
const appsRoute = (route: AppsRoute) => (context: Context<Api>) =>
  serveApps(
    context.req.raw,
    context.env,
    authExports((context.executionCtx as ExecutionContext).exports),
    context.executionCtx as ExecutionContext,
    route,
    context.req.param("name"),
  );
app.get("/api/v1/account/apps", appsRoute("list"));
app.post("/api/v1/account/apps", appsRoute("add"));
app.get("/api/v1/account/apps/log", appsRoute("log"));
app.get("/api/v1/account/apps/log/integrity", appsRoute("integrity"));
app.post("/api/v1/account/apps/:name/remove", appsRoute("remove"));
app.post("/api/v1/account/apps/:name/client", appsRoute("client"));
app.post("/api/v1/account/apps/:name/sign-in", appsRoute("signIn"));
app.post("/api/v1/account/apps/:name/token", appsRoute("token"));
app.post("/api/v1/account/apps/:name/device", appsRoute("device"));
app.post("/api/v1/account/apps/:name/device/poll", appsRoute("devicePoll"));
app.post("/api/v1/account/apps/:name/mac-sign-in", appsRoute("macSignIn"));
app.post("/api/v1/account/apps/:name/mac-sign-in/poll", appsRoute("macSignInPoll"));
app.post("/api/v1/account/apps/:name/phone-sign-in", appsRoute("phoneSignIn"));
// Assets (RFD0030): a person's, and a Mac's with its host credential.
const assetsRoute = (route: AssetRoute) => (context: Context<Api>) =>
  serveAccountAssets(
    context.req.raw,
    context.env,
    authExports((context.executionCtx as ExecutionContext).exports),
    context.executionCtx as ExecutionContext,
    route,
    context.req.param("hash"),
  );
app.all("/api/v1/account/assets", assetsRoute("list"));
app.all("/api/v1/account/assets/:hash", assetsRoute("asset"));
app.all("/api/v1/account/assets/:hash/delete", assetsRoute("delete"));
app.all("/api/v1/accounts/:account/hosts/:host/assets/:hash", context =>
  serveHostAssets(
    context.req.raw,
    context.env,
    context.executionCtx as ExecutionContext,
    context.req.param("account"),
    context.req.param("host"),
    context.req.param("hash"),
  ),
);
app.all("/api/v1/connections/oauth/start", context =>
  startConnectionSignIn(context.req.raw, context.env, authExports((context.executionCtx as ExecutionContext).exports), context.executionCtx as ExecutionContext),
);
app.all("/api/v1/connections/oauth/callback", context =>
  completeConnectionSignIn(context.req.raw, context.env, authExports((context.executionCtx as ExecutionContext).exports), context.executionCtx as ExecutionContext),
);

app.all("/api/v1/account/client", context =>
  upgradeAccountClient(
    context.req.raw,
    context.env,
    authExports((context.executionCtx as ExecutionContext).exports),
    context.executionCtx as ExecutionContext,
  ),
);

app.all("/api/v1/account/hosts/:host/client", context =>
  upgradeHostClient(
    context.req.raw,
    context.env,
    authExports((context.executionCtx as ExecutionContext).exports),
    context.executionCtx as ExecutionContext,
    context.req.param("host"),
  ),
);

app.all("/api/v1/accounts/:account/hosts/:host/peers", context =>
  upgradeHostPeers(
    context.req.raw,
    context.executionCtx as ExecutionContext,
    context.req.param("account"),
    context.req.param("host"),
  ),
);

app.all("/api/v1/accounts/:account/hosts/:host/peers/:target/client", context =>
  upgradePeerHostClient(
    context.req.raw,
    context.executionCtx as ExecutionContext,
    context.req.param("account"),
    context.req.param("host"),
    context.req.param("target"),
  ),
);

app.all("/api/v1/accounts/:account/hosts/:host/daemon", context =>
  upgradeHostDaemon(
    context.req.raw,
    context.executionCtx as ExecutionContext,
    context.req.param("account"),
    context.req.param("host"),
  ),
);

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

app.all("/v1/hosts", async context => {
  const principal = await authorizeHttpHostClient(context.req.raw, context.env);
  if (principal instanceof Response) return principal;
  return serveHosts(context.req.raw, principal, context.executionCtx as ExecutionContext);
});

app.all("/v1/hosts/", async context => {
  const principal = await authorizeHttpHostClient(context.req.raw, context.env);
  if (principal instanceof Response) return principal;
  return serveHosts(context.req.raw, principal, context.executionCtx as ExecutionContext);
});

app.all("/v1/hosts/:host/sessions", async context => {
  const principal = await authorizeHttpHostClient(context.req.raw, context.env);
  if (principal instanceof Response) return principal;
  return serveHostSessions(
    context.req.raw,
    principal,
    context.executionCtx as ExecutionContext,
    context.req.param("host"),
  );
});

app.all("/v1/hosts/:host/:role", async context => {
  const role = context.req.param("role");
  if (role !== "daemon" && role !== "client") return context.text("Not found", 404);
  const principal = await authorizeCaller(context, role);
  if (principal instanceof Response) return principal;
  const host = uuid.safeParse(context.req.param("host"));
  if (!host.success) return context.text("Invalid host", 400);
  const request = context.req.raw;
  if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
    return context.text("WebSocket required", 426);
  }
  if (!isAllowedWebSocketOrigin(request, role)) return context.text("Origin not allowed", 403);
  const ctx = context.executionCtx as ExecutionContext;
  const directory = ctx.exports.AxoHostDirectory.getByName("private-fleet");
  const admission = await directory.admitHost(host.data, principal);
  if (admission !== "admitted") {
    return new Response(admission, { status: admission === "capacity" ? 429 : admission === "conflict" ? 403 : 404 });
  }
  if (principal.expiresAt <= Date.now()) return context.text("Access expired", 401);
  return ctx.exports.AxoHostRelay.getByName(host.data).fetch(new Request("https://host.internal/", {
    headers: {
      Upgrade: "websocket",
      "X-Axo-Role": role,
      "X-Axo-Identity": principal.identity,
      "X-Axo-Expiry": String(principal.expiresAt),
      "X-Axo-Machine": host.data,
    },
  }));
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
  if (!isAllowedWebSocketOrigin(request, role)) return context.text("Origin not allowed", 403);
  const ctx = context.executionCtx as ExecutionContext;
  const admission = await ctx.exports.AxoHostDirectory.getByName("private-fleet").admit(machine.data, principal);
  if (admission !== "admitted") {
    return new Response(admission, { status: admission === "capacity" ? 429 : admission === "conflict" ? 403 : 404 });
  }
  if (principal.expiresAt <= Date.now()) return context.text("Access expired", 401);
  // Fresh headers only: caller-supplied headers never reach the Durable Object.
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

function isAllowedWebSocketOrigin(request: Request, role: "client" | "daemon"): boolean {
  const origin = request.headers.get("Origin");
  return origin === null || (role === "client" && origin === APP_ORIGIN);
}

app.notFound(context => context.text("Not found", 404));
// Hono's default exception logger is deliberately replaced: no payload-bearing stack traces.
app.onError(() => new Response("Service unavailable", { status: 503, headers: { "Cache-Control": "private, no-store" } }));
export default app;
