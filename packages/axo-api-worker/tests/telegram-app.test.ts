import assert from "node:assert/strict";
import { test } from "node:test";
import { accountAppSchema } from "@axo/protocol";
import { PhoneRefused, ProviderOutcomeUnknown, type PhoneClient, type PhoneSignIn, type PhoneStep } from "@axo/apps";
import { BuiltinApps } from "../src/apps/builtin";
import { sqlStorage } from "./sql-storage";

/**
 * RFD0016, phone apps: the person's own Telegram account, signed in with their number, the code
 * Telegram sends and their password, through an API client of their own. The fake stands in for
 * GramJS and Telegram: it knows one account, +44 7700 900123 (@Ada), with the password "hunter2".
 */

const HASH = "0123456789abcdef0123456789abcdef";

class FakeTelegram implements PhoneSignIn {
  consoleUrl = "https://my.telegram.org/apps";
  clientHelp = "Create an app at my.telegram.org.";
  sessions = new Set<string>();
  loggedOut: string[] = [];
  clients: PhoneClient[] = [];
  /** The next call's failure: Telegram ended the session, or the connection dropped. */
  fail: "ended" | "dropped" | null = null;
  /** Telegram moves the session to another data centre during the next call. */
  move = false;
  sent: Array<{ chat: unknown; message: string }> = [];
  private next = 0;

  async sendCode(client: PhoneClient, phone: string): Promise<PhoneStep> {
    this.clients.push(client);
    if (client.apiHash !== HASH) throw new PhoneRefused("Telegram does not take that API ID and hash.", true);
    if (phone !== "+447700900123") throw new PhoneRefused("Telegram does not know that number.", true);
    return { step: "code", pending: "after-code", via: "app" };
  }
  async enterCode(_client: PhoneClient, pending: string, phone: string, code: string): Promise<PhoneStep> {
    assert.equal(pending, "after-code");
    assert.equal(phone, "+447700900123");
    if (code !== "12345") throw new PhoneRefused("That code is not right.");
    return { step: "password", pending: "after-password", hint: "pet" };
  }
  async enterPassword(_client: PhoneClient, pending: string, password: string): Promise<PhoneStep> {
    assert.equal(pending, "after-password");
    if (password !== "hunter2") throw new PhoneRefused("That password is not right.");
    const session = `session-${++this.next}`;
    this.sessions.add(session);
    return { step: "done", session, account: "@Ada" };
  }
  async open(client: PhoneClient, session: string) {
    this.clients.push(client);
    if (!this.sessions.has(session)) throw Object.assign(new Error("AUTH_KEY_UNREGISTERED"), { ended: true });
    const fake = this;
    const api = {
      async getMe() {
        return { id: 7, username: "Ada", firstName: "Ada", lastName: null, phone: "447700900123" };
      },
      async getInputEntity(key: unknown) {
        return key;
      },
      async sendMessage(chat: unknown, options: { message: string }) {
        if (fake.fail === "dropped") throw new Error("connection closed");
        fake.sent.push({ chat, message: options.message });
        return { id: 99, date: 1_700_000_000 };
      },
    };
    let now = session;
    return {
      api: new Proxy(api, {
        get: (target, name) => {
          if (fake.fail === "ended") throw Object.assign(new Error("SESSION_REVOKED"), { ended: true });
          if (fake.fail === "dropped" && name === "getMe") throw new Error("connection closed");
          if (fake.move) {
            fake.move = false;
            fake.sessions.delete(now);
            now = `${now}-moved`;
            fake.sessions.add(now);
          }
          return target[name as keyof typeof target];
        },
      }),
      close: async () => now,
    };
  }
  async logOut(_client: PhoneClient, session: string) {
    this.loggedOut.push(session);
    this.sessions.delete(session);
  }
  failure(error: unknown) {
    if ((error as { ended?: boolean }).ended) return { kind: "ended" as const };
    return { kind: "unknown" as const };
  }
}

function fixture() {
  const telegram = new FakeTelegram();
  const sql = sqlStorage();
  const background: Promise<unknown>[] = [];
  const apps = new BuiltinApps({
    sql, secret: "test-secret-of-at-least-thirty-two-bytes", accountId: crypto.randomUUID(),
    fetcher: (async () => { throw new Error("a phone app makes no HTTP calls"); }) as typeof fetch,
    waitUntil: (p) => void background.push(p),
    phone: { telegram },
  });
  return { telegram, sql, apps, settled: () => Promise.all(background) };
}

async function signedIn() {
  const f = fixture();
  await f.apps.setClient("telegram", "1234567", HASH);
  const code = await f.apps.phoneSignIn("telegram", { step: "start", phone: "+44 7700 900123" });
  assert.equal(code.state, "code");
  const password = await f.apps.phoneSignIn("telegram", { step: "code", flow: (code as { flow: string }).flow, code: "12345" });
  const done = await f.apps.phoneSignIn("telegram", { step: "password", flow: (password as { flow: string }).flow, password: "hunter2" });
  assert.deepEqual(done, { state: "done", account: "@ada" });
  return f;
}

async function refused(promise: Promise<unknown>): Promise<Error> {
  try {
    await promise;
  } catch (error) {
    return error as Error;
  }
  assert.fail("expected a refusal");
}

test("Telegram is listed with a phone sign-in that asks for the person's API client first, and has no tools until it is set up", async () => {
  const { apps } = fixture();
  const listed = apps.list().find((c) => c.name === "apps.telegram")!;
  assert.ok(accountAppSchema.safeParse(listed).success);
  assert.deepEqual(listed.kind === "app" && listed.signIn, { kind: "phone", consoleUrl: "https://my.telegram.org/apps", clientHelp: "Create an app at my.telegram.org.", clientReady: false });
  assert.equal(apps.tools().filter((t) => t.service === "apps.telegram").length, 0);
  assert.match((await refused(apps.setClient("telegram", "abc", HASH))).message, /api_id is a number/);
  assert.match((await refused(apps.setClient("telegram", "1234567", "short"))).message, /api_hash is 32/);
  assert.deepEqual(await apps.phoneSignIn("telegram", { step: "start", phone: "+447700900123" }).catch((e: Error) => e.message), "Set up Telegram's API ID and hash first");
  await apps.setClient("telegram", " 1234567 ", HASH.toUpperCase());
  const ready = apps.list().find((c) => c.name === "apps.telegram")!;
  assert.equal(ready.kind === "app" && ready.signIn.kind === "phone" && ready.signIn.clientReady, true);
  assert.deepEqual(apps.tools().filter((t) => t.service === "apps.telegram").map((t) => t.name), ["get_me", "list_chats", "read_messages", "search", "send_message", "mark_read"]);
});

test("signing in goes number, code, password; a wrong code or password may be tried again, and the session is kept sealed", async () => {
  const { apps, telegram, sql } = fixture();
  await apps.setClient("telegram", "1234567", HASH);
  assert.deepEqual(await apps.phoneSignIn("telegram", { step: "start", phone: "+1 555 0100" }), { state: "failed", error: "Telegram does not know that number." });
  const code = await apps.phoneSignIn("telegram", { step: "start", phone: "+44 (7700) 900-123" });
  assert.equal(code.state === "code" && code.via, "app");
  const flow = (code as { flow: string }).flow;
  assert.deepEqual(await apps.phoneSignIn("telegram", { step: "code", flow, code: "11111" }), { state: "code", flow, via: "app", error: "That code is not right." });
  assert.deepEqual(await apps.phoneSignIn("telegram", { step: "password", flow, password: "x" }), { state: "failed", error: "This sign-in has ended. Start again." }, "a step out of order");
  assert.deepEqual(await apps.phoneSignIn("telegram", { step: "code", flow, code: "12345" }), { state: "password", flow, hint: "pet" });
  assert.deepEqual(await apps.phoneSignIn("telegram", { step: "password", flow, password: "nope" }), { state: "password", flow, hint: "pet", error: "That password is not right." });
  assert.deepEqual(await apps.phoneSignIn("telegram", { step: "password", flow, password: "hunter2" }), { state: "done", account: "@ada" });
  assert.deepEqual(await apps.phoneSignIn("telegram", { step: "password", flow, password: "hunter2" }), { state: "failed", error: "This sign-in has ended. Start again." }, "a flow is spent");
  assert.deepEqual(telegram.clients[0], { apiId: 1234567, apiHash: HASH });
  assert.deepEqual(apps.accounts("telegram"), [{ account: "@ada", state: "ready", lastError: null }]);
  const stored = JSON.stringify(sql.exec("SELECT * FROM app_accounts").toArray()) + JSON.stringify(sql.exec("SELECT * FROM app_clients").toArray());
  assert.ok(!stored.includes("session-1") && !stored.includes(HASH), "the session and the hash are sealed");
});

test("a sign-in gives up after five wrong codes", async () => {
  const { apps } = fixture();
  await apps.setClient("telegram", "1234567", HASH);
  const { flow } = (await apps.phoneSignIn("telegram", { step: "start", phone: "+447700900123" })) as { flow: string };
  for (let i = 0; i < 4; i++) assert.equal((await apps.phoneSignIn("telegram", { step: "code", flow, code: "11111" })).state, "code");
  assert.deepEqual(await apps.phoneSignIn("telegram", { step: "code", flow, code: "11111" }), { state: "failed", error: "That code is not right. That was the last try. Start again." });
  assert.equal((await apps.phoneSignIn("telegram", { step: "code", flow, code: "12345" })).state, "failed");
});

test("a call opens the account's session, runs the tool, and keeps the session Telegram moved it to", async () => {
  const { apps, telegram } = await signedIn();
  assert.deepEqual(await apps.call("telegram", "get_me", { account: "@ada" }), { id: "7", username: "Ada", firstName: "Ada", lastName: null, phone: "447700900123" });
  telegram.move = true;
  assert.deepEqual(await apps.call("telegram", "send_message", { account: "@Ada", chat: "@grace", text: "hello" }), { id: 99, date: "2023-11-14T22:13:20.000Z" });
  assert.deepEqual(telegram.sent, [{ chat: "@grace", message: "hello" }]);
  assert.deepEqual([...telegram.sessions], ["session-1-moved"]);
  assert.equal((await apps.call("telegram", "get_me", { account: "@ada" }) as { id: string }).id, "7", "the moved session is the one opened next");
  assert.match((await refused(apps.call("telegram", "get_me", { account: "@grace" }))).message, /no Telegram account @grace; signed in: @ada/);
});

test("a dropped connection fails a read, and leaves a send may-have-run", async () => {
  const { apps, telegram } = await signedIn();
  telegram.fail = "dropped";
  assert.match((await refused(apps.call("telegram", "get_me", { account: "@ada" }))).message, /Telegram did not answer$/);
  const send = await refused(apps.call("telegram", "send_message", { account: "@ada", chat: "me", text: "hi" }));
  assert.ok(send instanceof ProviderOutcomeUnknown, send.message);
});

test("a session Telegram ended is dropped and asks for sign-in again", async () => {
  const { apps, telegram } = await signedIn();
  telegram.fail = "ended";
  assert.match((await refused(apps.call("telegram", "get_me", { account: "@ada" }))).message, /Telegram ended this session; sign in again at https:\/\/axo\.leostera\.dev\/app\/settings\/apps\/telegram/);
  assert.deepEqual(apps.accounts("telegram"), [{ account: "@ada", state: "needsSignIn", lastError: "Telegram ended this session" }]);
});

test("removing an account, or signing it in again, logs the old session out at Telegram", async () => {
  const { apps, telegram, settled } = await signedIn();
  const { flow } = (await apps.phoneSignIn("telegram", { step: "start", phone: "+447700900123" })) as { flow: string };
  await apps.phoneSignIn("telegram", { step: "code", flow, code: "12345" });
  assert.deepEqual(await apps.phoneSignIn("telegram", { step: "password", flow, password: "hunter2" }), { state: "done", account: "@ada" });
  await settled();
  assert.deepEqual(telegram.loggedOut, ["session-1"]);
  assert.equal(await apps.disconnect("telegram", "@ADA"), true);
  await settled();
  assert.deepEqual(telegram.loggedOut, ["session-1", "session-2"]);
  assert.deepEqual(apps.accounts("telegram"), []);
});

test("Telegram bot accounts from before Telegram was the person's own are removed, once", async () => {
  const sql = sqlStorage();
  sql.exec("CREATE TABLE app_accounts (app TEXT NOT NULL, account TEXT NOT NULL, grant_sealed TEXT, grant_generation INTEGER NOT NULL DEFAULT 1, last_error TEXT, created_at REAL NOT NULL, PRIMARY KEY (app, account))");
  sql.exec("INSERT INTO app_accounts VALUES ('telegram', '@adabot', 'sealed-bot-token', 1, NULL, 0), ('hetzner', 'main', 'sealed', 1, NULL, 0)");
  const deps = { sql, secret: "test-secret-of-at-least-thirty-two-bytes", accountId: crypto.randomUUID(), fetcher: fetch, waitUntil: () => undefined };
  new BuiltinApps(deps);
  assert.deepEqual(sql.exec<{ app: string; account: string }>("SELECT app, account FROM app_accounts").toArray().map((r) => `${r.app}/${r.account}`), ["hetzner/main"]);
  sql.exec("INSERT INTO app_accounts VALUES ('telegram', '@ada', 'sealed-session', 1, NULL, 0)");
  new BuiltinApps(deps);
  assert.equal(sql.exec("SELECT 1 FROM app_accounts WHERE app = 'telegram'").toArray().length, 1, "a later account stays");
});
