/**
 * The Worker as released before Macs followed each other's HostDOs (RFD0032): no route for a Mac
 * on another Mac's HostDO, so a Mac opening one is answered 404 and must follow over protocol 2.
 */
import worker from "../../src/index";

export * from "../../src/index";

export default {
  ...worker,
  fetch(request: Request, env: unknown, ctx: ExecutionContext) {
    if (/^\/api\/v1\/accounts\/[^/]+\/hosts\/[^/]+\/peers\/[^/]+\/client$/.test(new URL(request.url).pathname)) {
      return new Response("Not found", { status: 404 });
    }
    return (worker.fetch as (request: Request, env: unknown, ctx: ExecutionContext) => Response | Promise<Response>)(request, env, ctx);
  },
};
