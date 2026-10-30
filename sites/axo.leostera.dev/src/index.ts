import api from "@axo/api-worker";

export {
  AxoAccountDirectory,
  AxoHostDirectory,
  AxoHostRelay,
  AxoIdentityIndex,
  AxoPairingIndex,
  AxoPairingRateLimit,
  AxoSessionDO,
} from "@axo/api-worker";

type WorkerEnvironment = Env & {
  ASSETS: Fetcher;
};

const SHARE_ID = /^[A-Za-z0-9_-]{22}$/;
const SHARE_CACHE_CONTROL = "public, max-age=60, s-maxage=300";

async function publicSessionSnapshot(request: Request, env: WorkerEnvironment): Promise<Response | null> {
  const { pathname } = new URL(request.url);
  const match = /^\/api\/public-sessions\/([^/]+)$/.exec(pathname);
  if (!match) return null;
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
  }
  const id = match[1];
  if (!SHARE_ID.test(id)) return new Response("Not found", { status: 404 });

  const snapshot = await env.PUBLIC_SESSIONS.get(`shares/${id}.json`);
  if (!snapshot) return new Response("Not found", { status: 404, headers: { "Cache-Control": "no-store" } });
  const headers = new Headers({
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": SHARE_CACHE_CONTROL,
    "X-Content-Type-Options": "nosniff",
    "Access-Control-Allow-Origin": "*",
  });
  return new Response(request.method === "HEAD" ? null : snapshot.body, { headers });
}

const AUTH_PATH = "/api/auth";
function unavailable(): Response {
  return new Response("Axo account-scoped API is not enabled yet", {
    status: 503,
    headers: { "Cache-Control": "private, no-store" },
  });
}

export default {
  async fetch(request: Request, env: WorkerEnvironment, executionContext: ExecutionContext): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (pathname.startsWith("/api/public-sessions/")) {
      return await publicSessionSnapshot(request, env) ?? new Response("Not found", { status: 404 });
    }
    if (pathname === AUTH_PATH || pathname.startsWith(`${AUTH_PATH}/`) ||
        pathname.startsWith("/api/v1/account/") ||
        pathname.startsWith("/api/v1/accounts/") ||
        pathname === "/api/v1/host-pairings/redeem")
      return await api.fetch(request, env, executionContext);
    if (pathname === "/api" || pathname.startsWith("/api/"))
      return unavailable();
    return await env.ASSETS.fetch(request);
  },
};
