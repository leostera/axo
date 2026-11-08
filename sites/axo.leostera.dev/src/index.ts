import api from "@axo/api-worker";
import { installScriptResponse, macAppManifestResponse, macAppResponse } from "./install.ts";
import { readSnapshot, sharePageHtml, shareRoute, transcriptResponse, type ShareRoute } from "./share-page.ts";

export {
  AxoAccountDirectory,
  AxoAssetCache,
  AxoAssetsDO,
  AxoClientDO,
  AxoHostDO,
  AxoIdentityIndex,
  AxoPairingIndex,
  AxoPairingRateLimit,
  AxoSessionDO,
} from "@axo/api-worker";

type WorkerEnvironment = Env & {
  ASSETS: Fetcher | undefined;
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

/**
 * A share's page, with its snapshot inlined, or its ATXF transcript. A share that is missing (or
 * that this version can't read) gets the app's page with a 404, which says so.
 */
async function sharePage(request: Request, env: WorkerEnvironment, route: ShareRoute): Promise<Response> {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
  }
  const stored = await env.PUBLIC_SESSIONS.get(`shares/${route.shareId}.json`);
  const snapshot = stored ? readSnapshot(await stored.text()) : null;
  if (route.kind === "transcript") {
    return snapshot
      ? transcriptResponse(route.shareId, snapshot, request.method)
      : new Response("Not found", { status: 404, headers: { "Cache-Control": "no-store" } });
  }
  const url = new URL(request.url);
  // Under `cf dev` Vite serves the page itself and there is no ASSETS binding to ask.
  const index = env.ASSETS ? await env.ASSETS.fetch(new Request(new URL("/", url))) : await fetch(new URL("/", url));
  if (!snapshot) {
    return new Response(index.body, { status: 404, headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" } });
  }
  if (!index.ok) return new Response("The page is unavailable", { status: 502, headers: { "Cache-Control": "no-store" } });
  const html = sharePageHtml(await index.text(), url.origin, route.shareId, snapshot);
  return new Response(request.method === "HEAD" ? null : html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": SHARE_CACHE_CONTROL,
      "X-Content-Type-Options": "nosniff",
      "Link": `<${url.origin}${url.pathname.replace(/\/$/, "")}.jsonl>; rel="alternate"; type="application/jsonl"`,
    },
  });
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
    if (pathname === "/install") return installScriptResponse(request);
    if (pathname === "/cdn/Axo.app" || pathname === "/cdn/Axo.app.zip")
      return await macAppResponse(request, env.CDN);
    if (pathname === "/cdn/Axo.app.json") return await macAppManifestResponse(request, env.CDN);
    const share = shareRoute(pathname);
    if (share) return await sharePage(request, env, share);
    if (pathname.startsWith("/api/public-sessions/")) {
      return await publicSessionSnapshot(request, env) ?? new Response("Not found", { status: 404 });
    }
    if (pathname === AUTH_PATH || pathname.startsWith(`${AUTH_PATH}/`) ||
        pathname.startsWith("/api/v1/account/") ||
        pathname.startsWith("/api/v1/accounts/") ||
        // A connection's OAuth sign-in: Axo's start page and the provider's callback (RFD0016).
        pathname.startsWith("/api/v1/connections/oauth/") ||
        pathname === "/api/v1/host-pairings/redeem")
      return await api.fetch(request, env, executionContext);
    if (pathname === "/api" || pathname.startsWith("/api/"))
      return unavailable();
    return await env.ASSETS!.fetch(request);
  },
};
