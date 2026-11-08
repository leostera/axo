/**
 * The Worker as it is, but with a HostDO that can be handed a socket another release accepted,
 * and woken again on the same storage and sockets (RFD0032, Release P). A test reaches it with
 * `X-Test-Foreign: <attachment JSON>` (accepts a socket with that attachment) and `X-Test-Wake`
 * (runs the constructor again, as a wake from hibernation does, and answers each socket's
 * `readyState` and attachment: Miniflare doesn't pass a close on to the test's end of the socket).
 */
import { AxoHostDO as ReleaseHostDO } from "../../src/host-do";

export * from "../../src/index";
export { default } from "../../src/index";

export class AxoHostDO extends ReleaseHostDO {
  override async fetch(request: Request): Promise<Response> {
    const foreign = request.headers.get("X-Test-Foreign");
    if (foreign !== null) {
      const [client, server] = Object.values(new WebSocketPair());
      this.ctx.acceptWebSocket(server!);
      server!.serializeAttachment(JSON.parse(foreign));
      return new Response(null, { status: 101, webSocket: client });
    }
    if (request.headers.get("X-Test-Wake") !== null) {
      new AxoHostDO(this.ctx, this.env);
      return Response.json(this.ctx.getWebSockets().map((socket) => ({ state: socket.readyState, attachment: socket.deserializeAttachment() })));
    }
    return super.fetch(request);
  }
}
