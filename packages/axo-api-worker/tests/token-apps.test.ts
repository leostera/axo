import assert from "node:assert/strict";
import { test } from "node:test";
import { connectionSchema } from "@axo/protocol";
import { AppAccountRefused, AppConnections } from "../src/connections/apps";
import { FakeHetzner } from "./fake-hetzner";
import { sqlStorage } from "./sql-storage";

/**
 * RFD0016, token apps: an app whose account is a token the person pasted (Hetzner), sealed like a
 * grant, checked before it is stored, sent only to the app's own hosts, and dropped when the
 * service refuses it.
 */

function fixture() {
  const hetzner = new FakeHetzner();
  const sql = sqlStorage();
  const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(input, init);
    const answer = await hetzner.handle(request);
    if (!answer) throw new Error(`unexpected request to ${request.url}`);
    return answer;
  }) as typeof fetch;
  const apps = new AppConnections({ sql, secret: "test-secret-of-at-least-thirty-two-bytes", accountId: crypto.randomUUID(), google: null, fetcher, waitUntil: () => undefined });
  return { hetzner, sql, apps };
}

async function refused(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (error) {
    return (error as Error).message;
  }
  assert.fail("expected a refusal");
}

test("Hetzner is listed without any client of Axo's, asking for a token the person names, and its tools all need an account", () => {
  const { apps } = fixture();
  const [listed, ...rest] = apps.list();
  assert.equal(rest.length, 0, "only token apps are listed without a Google client");
  const parsed = connectionSchema.parse(listed);
  assert.ok(parsed.kind === "app");
  assert.deepEqual([parsed.name, parsed.provider, parsed.state, parsed.accounts], ["apps.hetzner", "Hetzner", "needsSignIn", []]);
  assert.deepEqual(parsed.signIn, {
    kind: "token",
    helpUrl: "https://console.hetzner.com/projects",
    named: true,
    fields: [{ name: "token", label: "API token", help: parsed.signIn.kind === "token" ? parsed.signIn.fields[0]!.help : "", secret: true }],
  });
  assert.deepEqual(parsed.tools, ["list_servers", "get_server", "server_action", "server_metrics", "get_action", "list_zones", "list_records", "set_records", "delete_records",
    "list_firewalls", "list_volumes", "list_storage_boxes", "request"]);
  const tools = apps.tools();
  assert.ok(tools.every((t) => (t.inputSchema.required as string[])[0] === "account"));
  assert.match(tools[0]!.description, /the person adds one at https:\/\/axo\.leostera\.dev\/app\/settings\/apps\/hetzner/);
});

test("a token is checked before it is stored; a refused one, or one without a name, is not stored", async () => {
  const { apps, hetzner } = fixture();
  assert.match(await refused(apps.addToken("hetzner", "personal", { token: "nope" })), /Hetzner did not accept this token/);
  assert.match(await refused(apps.addToken("hetzner", null, { token: "hz-personal-token" })), /Name this account/);
  assert.match(await refused(apps.addToken("hetzner", "personal", {})), /API token is missing/);
  assert.match(await refused(apps.addToken("hetzner", "personal", { token: "hz-personal-token", password: "x" })), /does not take password/);
  assert.match(await refused(apps.addToken("hetzner", "personal", { token: "a\nb" })), /line breaks/);
  await assert.rejects(apps.addToken("gmail", "personal", { token: "x" }), AppAccountRefused);
  assert.deepEqual(apps.accounts("hetzner"), []);
  assert.equal(hetzner.calls.length, 1, "only the well-formed token was tried");

  assert.deepEqual(await apps.addToken("hetzner", "Personal", { token: " hz-personal-token " }), { name: "apps.hetzner", account: "personal" });
  assert.deepEqual(apps.accounts("hetzner"), [{ account: "personal", state: "ready", lastError: null }]);
});

test("each call acts as the project it names; the token is sealed, goes only to Hetzner, and cannot be overridden", async () => {
  const { apps, hetzner, sql } = fixture();
  await apps.addToken("hetzner", "personal", { token: "hz-personal-token" });
  await apps.addToken("hetzner", "work", { token: "hz-work-token" });

  const personal = (await apps.call("hetzner", "list_servers", { account: "personal" })) as { servers: Array<{ id: number; city: string }> };
  assert.equal(personal.servers.length, 60, "every page is read");
  assert.equal(personal.servers[0]!.city, "Falkenstein");
  const work = (await apps.call("hetzner", "list_servers", { account: "WORK" })) as { servers: Array<{ name: string }> };
  assert.deepEqual(work.servers.map((s) => s.name), ["ci"]);
  assert.match(await refused(apps.call("hetzner", "list_servers", {})), /account/);
  assert.match(await refused(apps.call("hetzner", "list_servers", { account: "eve" })), /no Hetzner account eve; signed in: personal, work/);

  const rebooted = (await apps.call("hetzner", "server_action", { account: "personal", id: 2, action: "reboot" })) as { action: { command: string } };
  assert.equal(rebooted.action.command, "reboot_server");
  const boxes = (await apps.call("hetzner", "list_storage_boxes", { account: "personal" })) as { storageBoxes: Array<{ usedGb: number; sizeGb: number }> };
  assert.deepEqual(boxes.storageBoxes.map((b) => [b.usedGb, b.sizeGb]), [[25, 1000]]);

  // `request` reaches any endpoint on Hetzner's hosts, with the token Axo holds and no other.
  const raw = (await apps.call("hetzner", "request", { account: "work", method: "GET", path: "/v1/servers", headers: { "X-Trace": "1" } })) as { json: { servers: unknown[] } };
  assert.equal(raw.json.servers.length, 1);
  assert.match(await refused(apps.call("hetzner", "request", { account: "work", method: "GET", path: "https://evil.example/v1/servers" })), /only reach api\.hetzner\.cloud, api\.hetzner\.com/);
  assert.match(await refused(apps.call("hetzner", "request", { account: "work", method: "GET", path: "/v1/servers", headers: { authorization: "Bearer hz-personal-token" } })), /set by Axo/);
  assert.ok(hetzner.calls.every((c) => c.headers.get("Authorization")?.startsWith("Bearer hz-")), "every call carries a project token");
  assert.equal(hetzner.calls.at(-1)!.project, "work");

  const stored = JSON.stringify(sql.exec("SELECT * FROM app_accounts").toArray());
  assert.equal(hetzner.leaks(stored), false, "tokens are stored sealed");
  assert.equal(hetzner.leaks(JSON.stringify([apps.list(), apps.tools()])), false);
});

test("set_records creates a record set when there is none, and otherwise replaces its records", async () => {
  const { apps, hetzner } = fixture();
  await apps.addToken("hetzner", "personal", { token: "hz-personal-token" });
  const created = await apps.call("hetzner", "set_records", { account: "personal", zone: "example.com", name: "api", type: "A", records: [{ value: "198.51.100.7" }] });
  assert.deepEqual(created, { records: { name: "api", type: "A", ttl: null, records: [{ value: "198.51.100.7", comment: null }] } });
  const replaced = await apps.call("hetzner", "set_records", { account: "personal", zone: "example.com", name: "www", type: "A", records: [{ value: "198.51.100.9", comment: "new" }], ttl: 300 });
  assert.deepEqual(replaced, { records: { name: "www", type: "A", ttl: 300, records: [{ value: "198.51.100.9", comment: "new" }] } });
  const listed = (await apps.call("hetzner", "list_records", { account: "personal", zone: "example.com" })) as { records: Array<{ name: string }> };
  assert.deepEqual(listed.records.map((r) => r.name), ["www", "api"]);
  assert.deepEqual(await apps.call("hetzner", "delete_records", { account: "personal", zone: "example.com", name: "api", type: "A" }), { deleted: true });
  assert.deepEqual(hetzner.rrsets.get("example.com")!.map((r) => r.name), ["www"]);
  assert.match(await refused(apps.call("hetzner", "set_records", { account: "personal", zone: "example.com", name: "WWW", type: "A", records: [{ value: "x" }] })), /lowercase/);
});

test("a token Hetzner refuses is dropped: the project stays listed, needing a new token, until one is added", async () => {
  const { apps, hetzner } = fixture();
  await apps.addToken("hetzner", "personal", { token: "hz-personal-token" });
  hetzner.revoke("hz-personal-token");
  const message = await refused(apps.call("hetzner", "list_zones", { account: "personal" }));
  assert.match(message, /personal: Hetzner refused the token; add a new one at https:\/\/axo\.leostera\.dev\/app\/settings\/apps\/hetzner/);
  assert.deepEqual(apps.accounts("hetzner"), [{ account: "personal", state: "needsSignIn", lastError: "Hetzner refused the token" }]);
  assert.match(await refused(apps.call("hetzner", "list_zones", { account: "personal" })), /needs adding again/);

  hetzner.tokens.set("hz-new-token", "personal");
  await apps.addToken("hetzner", "personal", { token: "hz-new-token" });
  assert.deepEqual(apps.accounts("hetzner"), [{ account: "personal", state: "ready", lastError: null }]);
  const zones = (await apps.call("hetzner", "list_zones", { account: "personal" })) as { zones: Array<{ name: string }> };
  assert.deepEqual(zones.zones.map((z) => z.name), ["example.com"]);

  assert.equal(await apps.disconnect("hetzner", "personal"), true);
  assert.deepEqual(apps.accounts("hetzner"), []);
});
