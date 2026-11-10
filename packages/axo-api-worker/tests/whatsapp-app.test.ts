import assert from "node:assert/strict";
import { test } from "node:test";
import { accountAppSchema } from "@axo/protocol";
import type { LinkedDevice, LinkedOutcome, LinkStart, LinkState } from "@axo/apps";
import { BuiltinApps } from "../src/apps/builtin";
import { sqlStorage } from "./sql-storage";

/**
 * RFD0016, linked devices: WhatsApp, which Axo joins as a linked device of the person's account.
 * Each link is a device of its own (in production, a Durable Object); the fakes stand in for them
 * and for WhatsApp, which approves a link once `approve` is called with the phone's number.
 */

class FakeDevice implements LinkedDevice {
  state: LinkState = { state: "failed", error: "never started" };
  started: LinkStart | null = null;
  unlinked = false;
  /** WhatsApp unlinked the device (from the phone). */
  gone = false;
  runs: Array<{ tool: string; input: Record<string, unknown> }> = [];

  async startLink(start: LinkStart): Promise<LinkState> {
    this.started = start;
    this.state = start.method === "qr" ? { state: "qr", qr: "2@qr-ref,keys" } : { state: "code", code: "ABCD-EFGH" };
    return this.state;
  }
  async linkState(): Promise<LinkState> {
    return this.state;
  }
  async unlink(): Promise<void> {
    this.unlinked = true;
  }
  async run(tool: string, input: Record<string, unknown>): Promise<LinkedOutcome> {
    this.runs.push({ tool, input });
    if (this.gone) return { unlinked: true };
    if (tool === "read_messages" && input.chat_id === "nobody") return { error: "no chat nobody in what WhatsApp synced" };
    return { result: { tool, ok: true } };
  }
  approve(number: string): void {
    this.state = { state: "done", account: number };
  }
}

function fixture() {
  const devices = new Map<string, FakeDevice>();
  const background: Promise<unknown>[] = [];
  const apps = new BuiltinApps({
    sql: sqlStorage(), secret: "test-secret-of-at-least-thirty-two-bytes", accountId: crypto.randomUUID(),
    fetcher: (async () => { throw new Error("a linked app makes no HTTP calls"); }) as typeof fetch,
    waitUntil: (p) => void background.push(p),
    linked: (app, device) => {
      assert.equal(app, "whatsapp");
      let fake = devices.get(device);
      if (!fake) devices.set(device, fake = new FakeDevice());
      return fake;
    },
  });
  return { apps, devices, settled: () => Promise.all(background) };
}

async function linked(f: ReturnType<typeof fixture>, number = "+447700900123") {
  const started = await f.apps.link("whatsapp", { step: "qr" });
  assert.equal(started.state, "qr");
  const flow = (started as { flow: string }).flow;
  f.devices.get(flow)!.approve(number);
  assert.deepEqual(await f.apps.link("whatsapp", { step: "poll", flow }), { state: "done", account: number });
  return f.devices.get(flow)!;
}

async function refused(promise: Promise<unknown>): Promise<Error> {
  try {
    await promise;
  } catch (error) {
    return error as Error;
  }
  assert.fail("expected a refusal");
}

test("WhatsApp is listed as a linked device, with read-only tools and no client to set up", () => {
  const { apps } = fixture();
  const listed = apps.list().find((c) => c.name === "apps.whatsapp")!;
  assert.ok(accountAppSchema.safeParse(listed).success);
  assert.deepEqual(listed.kind === "app" && listed.signIn, { kind: "linked", helpUrl: "https://faq.whatsapp.com/378279804439436" });
  assert.deepEqual(apps.tools().filter((t) => t.service === "apps.whatsapp").map((t) => t.name), ["get_me", "list_chats", "read_messages", "search"]);
});

test("linking shows a QR code, or a pairing code for the number, until the phone approves; the account is the number", async () => {
  const f = fixture();
  const code = await f.apps.link("whatsapp", { step: "code", phone: "+44 7700 900123" });
  assert.deepEqual(code, { state: "code", flow: (code as { flow: string }).flow, code: "ABCD-EFGH" });
  assert.deepEqual(f.devices.get((code as { flow: string }).flow)!.started, { method: "code", phone: "+44 7700 900123" });
  const flow = (code as { flow: string }).flow;
  assert.equal((await f.apps.link("whatsapp", { step: "poll", flow })).state, "code", "still waiting for the phone");
  f.devices.get(flow)!.approve("+447700900123");
  assert.deepEqual(await f.apps.link("whatsapp", { step: "poll", flow }), { state: "done", account: "+447700900123" });
  assert.deepEqual(await f.apps.link("whatsapp", { step: "poll", flow }), { state: "failed", error: "This link has ended. Start again." }, "a link lands once");
  assert.deepEqual(f.apps.accounts("whatsapp"), [{ account: "+447700900123", state: "ready", lastError: null }]);
});

test("a link that failed, or was cancelled, adds nothing; a cancelled device forgets its keys", async () => {
  const f = fixture();
  const started = await f.apps.link("whatsapp", { step: "qr" });
  const flow = (started as { flow: string }).flow;
  f.devices.get(flow)!.state = { state: "failed", error: "The code expired. Start again." };
  assert.deepEqual(await f.apps.link("whatsapp", { step: "poll", flow }), { state: "failed", error: "The code expired. Start again." });
  const again = await f.apps.link("whatsapp", { step: "qr" });
  const second = (again as { flow: string }).flow;
  assert.notEqual(second, flow, "each link is a new device");
  await f.apps.link("whatsapp", { step: "cancel", flow: second });
  await f.settled();
  assert.equal(f.devices.get(second)!.unlinked, true);
  assert.deepEqual(f.apps.accounts("whatsapp"), []);
});

test("a call runs on the account's device; an unknown account, or one WhatsApp unlinked, says to link it", async () => {
  const f = fixture();
  assert.match((await refused(f.apps.call("whatsapp", "list_chats", { account: "+447700900123" }))).message, /no WhatsApp account yet; the person adds one at https:\/\/axo\.leostera\.dev\/app\/settings\/apps\/whatsapp/);
  const device = await linked(f);
  assert.deepEqual(await f.apps.call("whatsapp", "search", { account: "+447700900123", query: "dinner" }), { tool: "search", ok: true });
  assert.deepEqual(device.runs, [{ tool: "search", input: { query: "dinner" } }], "the account is the gateway's; the device gets the tool's own input");
  assert.match((await refused(f.apps.call("whatsapp", "read_messages", { account: "+447700900123", chat_id: "nobody" }))).message, /no chat nobody/);
  device.gone = true;
  assert.match((await refused(f.apps.call("whatsapp", "list_chats", { account: "+447700900123" }))).message, /unlinked Axo's device; link it again/);
  assert.deepEqual(f.apps.accounts("whatsapp"), [{ account: "+447700900123", state: "needsSignIn", lastError: "WhatsApp unlinked this device" }]);
});

test("linking a number again replaces its device, and removing the account unlinks it", async () => {
  const f = fixture();
  const first = await linked(f);
  const second = await linked(f);
  await f.settled();
  assert.equal(first.unlinked, true, "the number's old device is unlinked");
  assert.equal(second.unlinked, false);
  assert.deepEqual(f.apps.accounts("whatsapp").map((a) => a.account), ["+447700900123"]);
  assert.equal(await f.apps.disconnect("whatsapp", "+447700900123"), true);
  await f.settled();
  assert.equal(second.unlinked, true);
  assert.deepEqual(f.apps.accounts("whatsapp"), []);
});
