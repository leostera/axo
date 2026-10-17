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
