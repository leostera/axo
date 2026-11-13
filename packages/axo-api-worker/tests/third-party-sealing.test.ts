import assert from "node:assert/strict";
import { test } from "node:test";
import { ThirdPartyApps } from "../src/apps/third-party";
import { seal, unseal } from "../src/auth/crypto";
import { FakeMcp } from "./fake-mcp";
import { sqlStorage } from "./sql-storage";

const secret = "test-secret-of-at-least-thirty-two-bytes";

async function fixture() {
  const server = new FakeMcp();
  const sql = sqlStorage();
  const accountId = crypto.randomUUID();
  const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) =>
    (await server.handle(new Request(input, init))) ?? new Response("not found", { status: 404 })) as typeof fetch;
  const apps = new ThirdPartyApps({ sql, secret, accountId, fetcher, waitUntil: () => undefined });
  await apps.add("linear", server.url);
  const sealed = () => sql.exec<{ client_sealed: string | null }>("SELECT client_sealed FROM third_party_connections WHERE name = 'linear'").toArray()[0]!.client_sealed;
  const opens = async () => {
    const nonce = new URL(await apps.signInLink("linear")).searchParams.get("flow")!;
    return apps.openFlow(nonce);
  };
  return { server, sql, accountId, apps, sealed, opens };
}

test("a client sealed before connections were apps still signs in, and is sealed again under today's name", async () => {
  const { sql, accountId, sealed, opens } = await fixture();
  const client = await unseal(secret, `apps-client\0${accountId}`, sealed()!, 65_536);
  assert.ok(client);
  sql.exec("UPDATE third_party_connections SET client_sealed = ?", await seal(secret, `connections-client\0${accountId}`, client));

  const opened = await opens();
  assert.ok(opened, "the sign-in starts");
  assert.equal(new URL(opened.authorizeUrl).searchParams.get("client_id"), (client as { clientId: string }).clientId);
  assert.deepEqual(await unseal(secret, `apps-client\0${accountId}`, sealed()!, 65_536), client);
});

test("a client Axo cannot read is registered again, so signing in never dead-ends", async () => {
  const { server, sql, sealed, opens } = await fixture();
  assert.equal(server.clients.size, 1);
  sql.exec("UPDATE third_party_connections SET client_sealed = 'v1.unreadable.garbage'");

  const opened = await opens();
  assert.ok(opened, "the sign-in starts");
  assert.equal(server.clients.size, 2);
  assert.notEqual(sealed(), "v1.unreadable.garbage");
});
