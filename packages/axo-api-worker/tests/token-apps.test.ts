import { createHash, createHmac } from "node:crypto";
import assert from "node:assert/strict";
import { test } from "node:test";
import { connectionSchema } from "@axo/protocol";
import { AppAccountRefused, BuiltinApps } from "../src/apps/builtin";
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
  const apps = new BuiltinApps({ sql, secret: "test-secret-of-at-least-thirty-two-bytes", accountId: crypto.randomUUID(), fetcher, waitUntil: () => undefined });
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
  const all = apps.list();
  assert.deepEqual(apps.tools().map((t) => t.service).filter((s, i, all) => all.indexOf(s) === i), ["apps.hetzner", "apps.chatgpt", "apps.octopus", "apps.wise", "apps.kraken", "apps.discord", "apps.unifi"],
    "without any OAuth client set up, only apps that need none have tools");
  const listed = all.find((c) => c.name === "apps.hetzner");
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
  const tools = apps.tools().filter((t) => t.service === "apps.hetzner");
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
  // A refused input says what the tool takes, and the input a wrong name most likely meant.
  assert.equal(await refused(apps.call("hetzner", "server_metrics", { account: "personal", server: 1, type: "cpu", start: "2026-10-01T00:00:00Z", end: "2026-10-02T00:00:00Z" })),
    'invalid input: "server" is not an input. It takes { account, id, type, start, end, step? }. ✖ Unrecognized key: "server"\n✖ Invalid input: expected number, received undefined\n  → at id');
  assert.match(await refused(apps.call("hetzner", "list_servers", { account: "personal", label: "x" })), /^invalid input: "label" is not an input: did you mean "labelSelector"\? It takes \{ account, /);

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

/** Octopus and Wise as their apps see them: Octopus's key as basic auth's user, Wise's token as a bearer. */
function services() {
  const seen: Array<{ url: URL; auth: string | null; body: string }> = [];
  const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
  const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(input, init);
    const url = new URL(request.url);
    const auth = request.headers.get("Authorization");
    seen.push({ url, auth, body: request.body ? await request.text() : "" });
    if (url.origin === "https://api.octopus.energy") {
      if (auth !== `Basic ${btoa("sk_live_octo:")}`) return json({ detail: "Authentication credentials were not provided." }, 401);
      if (url.pathname === "/v1/accounts/A-1234ABCD/")
        return json({ number: "A-1234ABCD", properties: [{ id: 1, address_line_1: "1 Road", town: "London", postcode: "E1 1AA", moved_in_at: "2024-01-01T00:00:00Z", moved_out_at: null,
          electricity_meter_points: [{ mpan: "1012345678901", is_export: false, meters: [{ serial_number: "21L123" }], agreements: [{ tariff_code: "E-1R-OLD-22-C", valid_from: "2022-01-01", valid_to: "2024-01-01" }, { tariff_code: "E-1R-AGILE-24-10-01-C", valid_from: "2024-01-01", valid_to: null }] }],
          gas_meter_points: [] }] });
      if (url.pathname === "/v1/accounts/A-00000000/") return json({ detail: "Not found." }, 404);
      if (url.pathname === "/v1/electricity-meter-points/1012345678901/meters/21L123/consumption/") {
        const page = url.searchParams.get("page") ?? "1";
        return json({ count: 3, next: page === "1" ? "https://api.octopus.energy/v1/electricity-meter-points/1012345678901/meters/21L123/consumption/?page=2" : null,
          results: page === "1"
            ? [{ consumption: 0.2, interval_start: "2026-10-03T00:00:00+01:00" }, { consumption: 0.3, interval_start: "2026-10-30T00:00:00Z" }]
            : [{ consumption: 0.1, interval_start: "2026-10-02T00:00:00+01:00" }] });
      }
      if (url.pathname === "/v1/products/AGILE-24-10-01/electricity-tariffs/E-1R-AGILE-24-10-01-C/standard-unit-rates/") return json({ results: [{ value_inc_vat: 21.5 }] });
    }
    if (url.origin === "https://api.wise.com") {
      if (auth !== "Bearer wise-token") return json({ error: "invalid_token" }, 401);
      if (url.pathname === "/v1/me") return json({ id: 1, email: "Ada@Example.com" });
      if (url.pathname === "/v2/profiles") return json([{ id: 10, type: "PERSONAL", fullName: "Ada Lovelace" }, { id: 11, type: "BUSINESS", fullName: "Engines Ltd" }]);
      if (url.pathname === "/v4/profiles/10/balances") return json([{ id: 5, currency: "EUR", type: "STANDARD", amount: { value: 120.5 }, reservedAmount: { value: 0 } }]);
      if (url.pathname === "/v3/profiles/10/quotes") return json({ id: "q1", rate: 0.85, ...JSON.parse(seen.at(-1)!.body) });
    }
    return json({ error: "not found" }, 404);
  }) as typeof fetch;
  const apps = new BuiltinApps({ sql: sqlStorage(), secret: "test-secret-of-at-least-thirty-two-bytes", accountId: crypto.randomUUID(), fetcher, waitUntil: () => undefined });
  return { apps, seen };
}

test("Octopus is named by its account number, checked with Octopus, and reads meters, usage across pages, and Agile prices", async () => {
  const { apps, seen } = services();
  assert.match(await refused(apps.addToken("octopus", null, { number: "A-1234ABCD", key: "wrong" })), /Octopus Energy did not accept this token/);
  assert.match(await refused(apps.addToken("octopus", null, { number: "A-00000000", key: "sk_live_octo" })), /did not accept/);
  assert.match(await refused(apps.addToken("octopus", null, { number: "1234", key: "sk_live_octo" })), /A-1234ABCD/);
  assert.deepEqual(await apps.addToken("octopus", null, { number: "a-1234abcd", key: "sk_live_octo" }), { name: "apps.octopus", account: "a-1234abcd" });
  const account = (await apps.call("octopus", "get_account", { account: "A-1234ABCD" })) as { properties: Array<{ address: string; electricity: Array<{ tariff: string; meters: string[] }> }> };
  assert.deepEqual(account.properties[0], { address: "1 Road, London, E1 1AA", movedIn: "2024-01-01T00:00:00Z", electricity: [{ mpan: "1012345678901", export: false, meters: ["21L123"], tariff: "E-1R-AGILE-24-10-01-C" }], gas: [] });
  const usage = (await apps.call("octopus", "get_consumption", { account: "a-1234abcd", fuel: "electricity", meterPoint: "1012345678901", serial: "21L123", from: "2026-10-01T00:00:00Z" })) as { results: unknown[] };
  assert.deepEqual((usage.results as Array<{ consumption: number }>).map((r) => r.consumption), [0.1, 0.2, 0.3], "every page is read, and the readings come oldest first whatever order Octopus sent");
  assert.deepEqual(await apps.call("octopus", "get_unit_rates", { account: "a-1234abcd", fuel: "electricity", tariff: "E-1R-AGILE-24-10-01-C" }), { results: [{ value_inc_vat: 21.5 }] });
  assert.ok(seen.every((s) => s.url.origin === "https://api.octopus.energy"));
});

test("Wise is named by the token's email, and reads profiles and balances and prices transfers", async () => {
  const { apps } = services();
  assert.deepEqual(await apps.addToken("wise", "ignored", { token: "wise-token" }), { name: "apps.wise", account: "ada@example.com" });
  assert.deepEqual(await apps.call("wise", "list_profiles", { account: "ada@example.com" }), { profiles: [{ id: 10, type: "personal", name: "Ada Lovelace" }, { id: 11, type: "business", name: "Engines Ltd" }] });
  assert.deepEqual(await apps.call("wise", "list_balances", { account: "ada@example.com", profile: 10 }), { balances: [{ id: 5, currency: "EUR", amount: 120.5, reserved: 0, name: null, type: "standard" }] });
  assert.deepEqual(await apps.call("wise", "create_quote", { account: "ada@example.com", profile: 10, sourceCurrency: "EUR", targetCurrency: "GBP", sourceAmount: 100 }),
    { id: "q1", rate: 0.85, sourceCurrency: "EUR", targetCurrency: "GBP", sourceAmount: 100 });
  assert.match(await refused(apps.call("wise", "create_quote", { account: "ada@example.com", profile: 10, sourceCurrency: "EUR", targetCurrency: "GBP" })), /sourceAmount or targetAmount/);
});

/** Kraken's API, which checks each request's signature and nonce as Kraken does. */
function signedServices() {
  const krakenSecret = Buffer.from("kraken-private-key-of-some-length").toString("base64");
  const seen: Array<{ url: URL; headers: Headers; body: string }> = [];
  const nonces: bigint[] = [];
  const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
  const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(input, init);
    const url = new URL(request.url);
    const body = request.body ? await request.text() : "";
    seen.push({ url, headers: request.headers, body });
    if (url.origin === "https://api.kraken.com") {
      if (url.pathname.startsWith("/0/public/")) return json({ error: [], result: { XXBTZEUR: { c: ["60000.0", "0.1"] } } });
      const form = new URLSearchParams(body);
      const nonce = form.get("nonce") ?? "";
      const expected = createHmac("sha512", Buffer.from(krakenSecret, "base64"))
        .update(Buffer.concat([Buffer.from(url.pathname), createHash("sha256").update(nonce + body).digest()])).digest("base64");
      if (request.headers.get("API-Key") !== "kraken-key" || request.headers.get("API-Sign") !== expected) return json({ error: ["EAPI:Invalid key"], result: {} });
      if (nonces.length && BigInt(nonce) <= nonces.at(-1)!) return json({ error: ["EAPI:Invalid nonce"], result: {} });
      nonces.push(BigInt(nonce));
      if (url.pathname === "/0/private/BalanceEx") return json({ error: [], result: { ZEUR: { balance: "120.50" } } });
      if (url.pathname === "/0/private/AddOrder") return json({ error: [], result: { descr: { order: `${form.get("type")} ${form.get("volume")} ${form.get("pair")} @ ${form.get("ordertype")}` }, validate: form.get("validate") } });
    }
    return json({ error: ["not found"] }, 404);
  }) as typeof fetch;
  const apps = new BuiltinApps({ sql: sqlStorage(), secret: "test-secret-of-at-least-thirty-two-bytes", accountId: crypto.randomUUID(), fetcher, waitUntil: () => undefined });
  return { apps, seen, krakenSecret };
}

test("Kraken signs every private call with an increasing nonce, and checks the key before keeping it", async () => {
  const { apps, krakenSecret } = signedServices();
  assert.match(await refused(apps.addToken("kraken", "main", { key: "kraken-key", secret: Buffer.from("wrong").toString("base64") })), /Kraken did not accept this token: Kraken: EAPI:Invalid key/);
  assert.match(await refused(apps.addToken("kraken", null, { key: "kraken-key", secret: krakenSecret })), /Name this account/);
  assert.deepEqual(await apps.addToken("kraken", "Main", { key: "kraken-key", secret: krakenSecret }), { name: "apps.kraken", account: "main" });
  assert.deepEqual(await apps.call("kraken", "get_balance", { account: "main" }), { ZEUR: { balance: "120.50" } });
  assert.deepEqual(await apps.call("kraken", "get_balance", { account: "main" }), { ZEUR: { balance: "120.50" } }, "a second call's nonce is larger");
  assert.deepEqual(await apps.call("kraken", "add_order", { account: "main", pair: "XBTEUR", side: "buy", type: "market", volume: "0.001", validate: true }),
    { descr: { order: "buy 0.001 XBTEUR @ market" }, validate: "true" });
  assert.deepEqual(await apps.call("kraken", "get_ticker", { account: "main", pairs: ["XBTEUR"] }), { XXBTZEUR: { c: ["60000.0", "0.1"] } });
});

/** Discord and UniFi as they check their credentials: a Bot token, and an X-API-KEY. */
function moreServices() {
  const seen: Array<{ url: URL; headers: Headers; body: string }> = [];
  const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
  const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(input, init);
    const url = new URL(request.url);
    const body = request.body ? await request.text() : "";
    seen.push({ url, headers: request.headers, body });
    if (url.origin === "https://discord.com") {
      if (request.headers.get("Authorization") !== "Bot discord-token") return json({ message: "401: Unauthorized", code: 0 }, 401);
      if (url.pathname === "/api/v10/users/@me") return json({ id: "1", username: "AdaBot" });
      if (url.pathname === "/api/v10/channels/123456789012345678/messages" && request.method === "POST") return json({ id: "999999999999999999", content: JSON.parse(body).content });
      return json({ message: "Unknown Channel", code: 10003 }, 404);
    }
    if (url.origin === "https://api.ui.com") {
      if (request.headers.get("X-API-KEY") !== "ui-key") return json({ code: "unauthorized", message: "unauthorized" }, 401);
      if (url.pathname === "/v1/hosts") return url.searchParams.get("nextToken") ? json({ data: [{ id: "h2" }] }) : json({ data: [{ id: "h1" }], nextToken: "t" });
      if (url.pathname === "/v1/devices") return json({ data: [{ hostId: url.searchParams.getAll("hostIds[]").join("+"), devices: [] }] });
      const proxy = "/v1/connector/consoles/h2/proxy/network";
      if (url.pathname === `${proxy}/api/s/default/stat/sta`) return json({ meta: { rc: "ok" }, data: [
        { mac: "aa:aa", hostname: "Galaxy-A54", name: "Phone", last_ip: "192.168.0.84", is_wired: false, essid: "Home", last_uplink_name: "Express 7", first_seen: 1_773_232_249, last_seen: 1_793_494_577 },
        { mac: "bb:bb", ip: "192.168.0.9", is_wired: true },
      ] });
      if (url.pathname === `${proxy}/integration/v1/dpi/applications`) {
        // Two pages, and IDs both ways: category << 16 | app, and the app's number alone.
        const offset = Number(url.searchParams.get("offset"));
        return json({ offset, totalCount: 2, data: offset === 0 ? [{ id: 5 * 65_536 + 132, name: "YouTube" }] : offset === 1 ? [{ id: 7, name: "QUIC" }] : [] });
      }
      if (url.pathname === `${proxy}/v2/api/site/default/traffic`) {
        if (!url.searchParams.get("start") || url.searchParams.get("includeUnidentified") !== "true") return json({ error: "bad query" }, 400);
        return json({
          total_usage_by_app: [
            { application: 7, category: 13, bytes_received: 1, bytes_transmitted: 1, total_bytes: 2, client_count: 1 },
            { application: 132, category: 5, bytes_received: 90, bytes_transmitted: 10, total_bytes: 100, client_count: 2 },
            { application: 65_535, category: 255, total_bytes: 50, client_count: 1 },
          ],
          client_usage_by_app: [
            { client: { mac: "aa:aa", name: "Phone" }, usage_by_app: [{ application: 132, category: 5, total_bytes: 30 }] },
            { client: { mac: "bb:bb", hostname: "studio" }, usage_by_app: [{ application: 132, category: 5, total_bytes: 70 }, { application: 65_535, category: 255, total_bytes: 50 }, { application: 7, category: 13, total_bytes: 2 }] },
          ],
        });
      }
    }
    return json({ message: "not found" }, 404);
  }) as typeof fetch;
  const apps = new BuiltinApps({ sql: sqlStorage(), secret: "test-secret-of-at-least-thirty-two-bytes", accountId: crypto.randomUUID(), fetcher, waitUntil: () => undefined });
  return { apps, seen };
}

test("a Discord bot goes as `Bot <token>`, is named by its username, and posts without pinging anyone", async () => {
  const { apps, seen } = moreServices();
  assert.deepEqual(await apps.addToken("discord", null, { token: "discord-token" }), { name: "apps.discord", account: "adabot" });
  assert.deepEqual(await apps.call("discord", "send_message", { account: "adabot", channel: "123456789012345678", content: "hi @everyone" }), { id: "999999999999999999" });
  assert.deepEqual(JSON.parse(seen.at(-1)!.body).allowed_mentions, { parse: [] });
  assert.match(await refused(apps.call("discord", "read_messages", { account: "adabot", channel: "123456789012345679" })), /Discord: Unknown Channel/);
});

test("UniFi takes its key as X-API-KEY, needs a name, and reads every page", async () => {
  const { apps } = moreServices();
  assert.match(await refused(apps.addToken("unifi", "home", { key: "nope" })), /UniFi did not accept this token/);
  assert.deepEqual(await apps.addToken("unifi", "Home", { key: "ui-key" }), { name: "apps.unifi", account: "home" });
  assert.deepEqual(await apps.call("unifi", "list_hosts", { account: "home" }), { hosts: [{ id: "h1" }, { id: "h2" }] });
  assert.deepEqual(await apps.call("unifi", "list_devices", { account: "home", hostIds: ["a", "b"] }), { hosts: [{ hostId: "a+b", devices: [] }] });
});

test("UniFi lists a console's clients and what the network was used for, by app and device, with the apps named", async () => {
  const { apps } = moreServices();
  await apps.addToken("unifi", "Home", { key: "ui-key" });
  assert.match(await refused(apps.call("unifi", "get_traffic", { account: "home" })), /has 2 consoles: pass `host`, one of h1 .*h2/);
  assert.deepEqual(await apps.call("unifi", "list_clients", { account: "home", host: "h2" }), { clients: [
    { name: "Phone", hostname: "Galaxy-A54", mac: "aa:aa", ip: "192.168.0.84", wired: false, network: "Home", uplink: "Express 7", firstSeen: "2026-03-11T12:30:49.000Z", lastSeen: "2026-11-01T00:56:17.000Z", receivedBytes: null, sentBytes: null, signal: null },
    { name: "bb:bb", hostname: null, mac: "bb:bb", ip: "192.168.0.9", wired: true, network: null, uplink: null, firstSeen: null, lastSeen: null, receivedBytes: null, sentBytes: null, signal: null },
  ] });
  const traffic = (await apps.call("unifi", "get_traffic", { account: "home", host: "h2", hours: 6, limit: 2 })) as { from: string; to: string; totalBytes: number; apps: unknown[]; devices: unknown[] };
  assert.equal(Date.parse(traffic.to) - Date.parse(traffic.from), 6 * 3_600_000);
  assert.equal(traffic.totalBytes, 152);
  assert.deepEqual(traffic.apps, [
    { app: "YouTube", bytes: 100, receivedBytes: 90, sentBytes: 10, devices: [{ device: "studio", bytes: 70 }, { device: "Phone", bytes: 30 }] },
    { app: "Unknown", bytes: 50, receivedBytes: 0, sentBytes: 0, devices: [{ device: "studio", bytes: 50 }] },
  ], "biggest first, named from the catalogue, cut at the limit");
  assert.deepEqual(traffic.devices, [
    { device: "studio", mac: "bb:bb", bytes: 122, apps: [{ app: "YouTube", bytes: 70 }, { app: "Unknown", bytes: 50 }, { app: "QUIC", bytes: 2 }] },
    { device: "Phone", mac: "aa:aa", bytes: 30, apps: [{ app: "YouTube", bytes: 30 }] },
  ]);
});
