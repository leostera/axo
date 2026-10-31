import { z } from "zod";
import { connectionNameSchema, serviceSchema, type CallRecord, type Connection } from "@axo/protocol";
import { json, requireAccount, type AuthExports } from "../auth/account-access";
import { parseAuthConfiguration, type AuthEnvironment } from "../auth/config";
import { unseal } from "../auth/crypto";
import { clearCookie, cookieValue, setCookie } from "../auth/session";
import type { CallOutcome } from "../connections/account";
import { FLOW_LIFETIME_MS } from "../connections/third-party";

/**
 * Connections over HTTPS (RFD0016): the web Connections page, and the browser side of a
 * third-party sign-in. A person signs in to a connection only in a browser signed in to the
 * account the connection belongs to, and the provider's answer is accepted only with the flow
 * cookie that browser was given (specs/connection-sign-in.ts).
 */

const FLOW_COOKIE = "__Host-axo_connection";
const privateHeaders = { "Cache-Control": "private, no-store", Pragma: "no-cache" };
const APP = "https://axo.leostera.dev";

type ConnectionsStub = {
  listConnections(): Promise<{ connections: Connection[] }>;
  addConnection(name: string, url: string): Promise<CallOutcome>;
  removeConnection(name: string, account?: string): Promise<CallOutcome>;
  setConnectionClient(name: string, clientId: string, clientSecret: string | null): Promise<{ signInUrl: string }>;
  connectionSignInLink(name: string): Promise<string>;
  openConnectionFlow(nonce: string): Promise<{ authorizeUrl: string; name: string } | null>;
  completeConnectionFlow(nonce: string, code: string): Promise<{ name: string } | { error: string }>;
  connectionsLog(limit?: number, before?: string, service?: string): Promise<{ records: CallRecord[] }>;
};

export type ConnectionsRoute = "list" | "add" | "remove" | "client" | "signIn" | "log";

const addBody = z.object({ name: connectionNameSchema, url: z.url({ protocol: /^https$/ }) }).strict();
const removeBody = z.object({ account: z.string().min(3).max(320).optional() }).strict();
const clientBody = z.object({ clientId: z.string().min(1).max(512), clientSecret: z.string().min(1).max(2048).nullable().optional() }).strict();

function account(ctx: ExecutionContext, accountId: string): ConnectionsStub {
  return ctx.exports.AxoAccountDirectory.getByName(accountId) as unknown as ConnectionsStub;
}

/** The Connections page's API: every route needs a signed-in account; changes need the app's Origin. */
export async function serveConnections(
  request: Request,
  env: AuthEnvironment,
  exports: AuthExports,
  ctx: ExecutionContext,
  route: ConnectionsRoute,
  rawName?: string,
): Promise<Response> {
  const reads = route === "list" || route === "log";
  if (request.method !== (reads ? "GET" : "POST")) return json({ error: "Method not allowed" }, 405, { Allow: reads ? "GET" : "POST" });
  const caller = await requireAccount(request, env, exports, reads ? "read" : "change");
  if (caller instanceof Response) return caller;
  const stub = account(ctx, caller.accountId);
  // Signing in and removing also take an app, `apps.<app>`; a client is only ever a third party's.
  const names = route === "signIn" || route === "remove" ? serviceSchema : connectionNameSchema;
  const name = rawName === undefined ? null : names.safeParse(rawName);
  if (name && !name.success) return json({ error: "Invalid connection name" }, 400);
  try {
    switch (route) {
      case "list":
        return json(plain(await stub.listConnections()));
      case "log": {
        const url = new URL(request.url);
        const limit = Number(url.searchParams.get("limit") ?? "") || undefined;
        // `?service=apps.gmail` keeps one app's or server's calls.
        const service = url.searchParams.get("service");
        if (service !== null && !serviceSchema.safeParse(service).success) return json({ error: "Invalid service" }, 400);
        return json(plain(await stub.connectionsLog(limit, url.searchParams.get("before") ?? undefined, service ?? undefined)));
      }
      case "add": {
        const body = addBody.safeParse(await request.json().catch(() => null));
        if (!body.success) return json({ error: "Expected { name, url } with an https URL" }, 400);
        return outcome(plain(await stub.addConnection(body.data.name, body.data.url)));
      }
      case "remove": {
        // Signing out of an app names the account: { account }.
        const body = removeBody.safeParse(await request.json().catch(() => ({})));
        if (!body.success) return json({ error: "Expected { account? }" }, 400);
        return outcome(plain(await stub.removeConnection(name!.data!, body.data.account)));
      }
      case "client": {
        const body = clientBody.safeParse(await request.json().catch(() => null));
        if (!body.success) return json({ error: "Expected { clientId, clientSecret? }" }, 400);
        return json(plain(await stub.setConnectionClient(name!.data!, body.data.clientId, body.data.clientSecret ?? null)));
      }
      case "signIn":
        return json({ signInUrl: plain(await stub.connectionSignInLink(name!.data!)) });
    }
  } catch (error) {
    return json({ error: error instanceof Error ? error.message.slice(0, 256) : "Connections are unavailable" }, 503);
  }
}

/** A sign-in link from `connections_add` or the Connections page: sends the browser to the provider, once. */
export async function startConnectionSignIn(request: Request, env: AuthEnvironment, exports: AuthExports, ctx: ExecutionContext): Promise<Response> {
  if (request.method !== "GET") return json({ error: "Method not allowed" }, 405, { Allow: "GET" });
  const caller = await requireAccount(request, env, exports, "read");
  if (caller instanceof Response) return page(401, "Sign in to Axo in this browser, then open the sign-in link again.");
  const nonce = new URL(request.url).searchParams.get("flow");
  if (!nonce || !z.uuid().safeParse(nonce).success) return page(400, "This sign-in link is not valid.");
  const opened = plain(await account(ctx, caller.accountId).openConnectionFlow(nonce));
  if (!opened) return page(410, "This sign-in link was already used, has expired, or belongs to another account. Ask for a new one.");
  return new Response(null, {
    status: 302,
    headers: { ...privateHeaders, Location: opened.authorizeUrl, "Set-Cookie": setCookie(FLOW_COOKIE, nonce, FLOW_LIFETIME_MS / 1000) },
  });
}

/** The provider sends the browser back here with a code. */
export async function completeConnectionSignIn(request: Request, env: AuthEnvironment, exports: AuthExports, ctx: ExecutionContext): Promise<Response> {
  if (request.method !== "GET") return json({ error: "Method not allowed" }, 405, { Allow: "GET" });
  const done = (query: Record<string, string>) => new Response(null, {
    status: 302,
    headers: { ...privateHeaders, Location: `${APP}/app/connections?${new URLSearchParams(query)}`, "Set-Cookie": clearCookie(FLOW_COOKIE) },
  });
  const configuration = parseAuthConfiguration(env);
  const caller = await requireAccount(request, env, exports, "read");
  if (!configuration || caller instanceof Response) return done({ error: "Sign in to Axo in this browser, then try again." });
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state") ?? "";
  if (url.searchParams.get("error") || !code) return done({ error: "The sign-in was cancelled or refused." });
  const sealed = state.length <= 2048 ? await unseal(configuration.sessionSecret, "connections-oauth-state", state) : null;
  const flow = z.object({ accountId: z.uuid(), nonce: z.uuid() }).safeParse(sealed);
  const cookie = cookieValue(request.headers.get("Cookie"), FLOW_COOKIE);
  // The answer counts only in the browser that started this sign-in, signed in to its account.
  if (!flow.success || flow.data.accountId !== caller.accountId || cookie !== flow.data.nonce)
    return done({ error: "This sign-in did not start in this browser, or belongs to another account." });
  const result = plain(await account(ctx, caller.accountId).completeConnectionFlow(flow.data.nonce, code));
  return "error" in result ? done({ error: result.error }) : done({ signedIn: result.name });
}

function outcome(result: CallOutcome): Response {
  if ("result" in result) return json(result.result);
  const status = result.error.code === -32022 ? 409 : result.error.code === -32021 ? 404 : 400;
  return json({ error: result.error.message, code: result.error.code }, status);
}

function page(status: number, message: string): Response {
  const html = `<!doctype html><meta charset="utf-8"><title>Axo</title><body style="font:16px system-ui;margin:4rem auto;max-width:32rem">${message}</body>`;
  return new Response(html, { status, headers: { ...privateHeaders, "Content-Type": "text/html; charset=utf-8" } });
}

/** RPC results arrive as proxies that hold resources; this keeps the plain value and lets them go. */
function plain<T>(value: T): T {
  const copy = JSON.parse(JSON.stringify(value)) as T;
  (value as Partial<Disposable>)?.[Symbol.dispose]?.();
  return copy;
}
