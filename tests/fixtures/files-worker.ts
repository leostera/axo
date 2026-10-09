// Test-only entrypoint: never bundled into or exported by the production service.
import { Relay as ProductionRelay } from "../../service/src/index";
import { handleFiles } from "../../service/src/files";
export class Relay extends ProductionRelay {
  async writeOutstandingForTest(id: string, content: string) {
    const row = this.ctx.storage.sql.exec<{ object_key: string; metadata: string }>("SELECT object_key,metadata FROM shared_files WHERE id=?", id).one();
    if (!row.object_key) throw new Error("Attempt key was released prematurely");
    await this.env.FILES.put(row.object_key, content, { sha256: JSON.parse(row.metadata).sha256 });
  }
  async expireAttemptForTest(id: string) {
    this.ctx.storage.sql.exec("UPDATE shared_files SET lease_until=? WHERE id=?", Date.now() - 61_000, id);
    await this.alarm();
  }
}
export default {
  async fetch(request: Request, env: { TEST_RELAY: DurableObjectNamespace<Relay>; FILES: R2Bucket }) {
    const relay = env.TEST_RELAY.getByName("file-tests");
    const path = new URL(request.url).pathname;
    if (path === "/start-without-write") {
      const { id } = await request.json<{ id: string }>();
      await relay.beginFileUpload("session", id);
      return Response.json({ started: true });
    }
    if (path === "/late-write") {
      const { id, content } = await request.json<{ id: string; content: string }>();
      await relay.writeOutstandingForTest(id, content);
      return Response.json({ written: true });
    }
    if (path === "/stage-without-commit") {
      const { id, content } = await request.json<{ id: string; content: string }>();
      const lease = await relay.beginFileUpload("session", id);
      if (!("key" in lease)) throw new Error("Expected pending upload");
      await env.FILES.put(lease.key, content, { sha256: lease.file.sha256 });
      return Response.json({ staged: true });
    }
    if (path === "/expire-attempt") {
      const { id } = await request.json<{ id: string }>();
      await relay.expireAttemptForTest(id);
      return Response.json({ reconciled: true });
    }
    if (path === "/host") return relay.fetch(new Request("https://internal/", { headers: {
      Upgrade: "websocket", "X-Axo-Role": "host", "X-Axo-Expiry": String(Date.now() + 60_000),
    } }));
    return handleFiles(request, { role: "phone", expiresAt: Date.now() + 60_000 }, relay, env.FILES, { writesEnabled: request.headers.get("X-Test-Writes") !== "off" });
  },
};
