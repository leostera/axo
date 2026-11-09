/**
 * The Worker as it is, with a HostDO that fences a connection when a test asks:
 * `X-Test-Fence: <connection id>` does what an old socket's late close does (its route is let go
 * of), so a test can fence a connection other than the one serving the Mac now.
 */
import { AxoHostDO as ReleaseHostDO } from "../../src/host-do";

export * from "../../src/index";
export { default } from "../../src/index";

export class AxoHostDO extends ReleaseHostDO {
  override async fetch(request: Request): Promise<Response> {
    const connection = request.headers.get("X-Test-Fence");
    if (connection === null) return super.fetch(request);
    this.fence(connection);
    return new Response(null, { status: 204 });
  }
}
