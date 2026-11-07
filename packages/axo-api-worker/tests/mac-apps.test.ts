import assert from "node:assert/strict";
import { test } from "node:test";
import { connectionSchema } from "@axo/protocol";
import { BuiltinApps, macCommand } from "../src/apps/builtin";
import { ProviderOutcomeUnknown } from "@axo/apps";
import { sqlStorage } from "./sql-storage";

/**
 * RFD0016, Mac apps: 1Password runs its CLI on the Mac a call names (its account), signed in
 * through the 1Password app there. Arguments are quoted for the shell; values a command takes on
 * standard input never appear on its command line.
 */

/** What `op` on a Mac would do, from the command Axo sends: its arguments, and its input. */
function parse(command: string): { args: string[]; stdin: string | null } {
  let stdin: string | null = null;
  const piped = /^printf '%s' '([A-Za-z0-9+/=]*)' \| base64 -d \| (.*)$/s.exec(command);
  if (piped) {
    stdin = Buffer.from(piped[1]!, "base64").toString("utf8");
    command = piped[2]!;
  }
  const args: string[] = [];
  const re = /'((?:[^']|'\\'')*)'(?: |$)/gy;
  for (let m; (m = re.exec(command));) args.push(m[1]!.replace(/'\\''/g, "'"));
  assert.equal(args.map((a) => `'${a.replace(/'/g, "'\\''")}'`).join(" "), command, "every argument is quoted");
  return { args, stdin };
}

type Ran = { mac: string; args: string[]; stdin: string | null };

function fixture(macs = ["studio", "leo_s_laptop"]) {
  const ran: Ran[] = [];
  let next: ((r: Ran) => { exitCode: number | null; stdout: string; stderr: string; timedOut?: boolean }) | null = null;
  let offline = false;
  let lost = false;
  const items: Record<string, unknown> = {
    GitHub: { id: "abc", title: "GitHub", category: "LOGIN", vault: { id: "v1", name: "Private" }, urls: [{ href: "https://github.com", primary: true }], tags: [],
      fields: [{ id: "username", label: "username", type: "STRING", purpose: "USERNAME", value: "leostera", reference: "op://Private/GitHub/username" },
        { id: "password", label: "password", type: "CONCEALED", purpose: "PASSWORD", value: "hunter2", reference: "op://Private/GitHub/password" }] },
  };
  const apps = new BuiltinApps({
    sql: sqlStorage(), secret: "test-secret-of-at-least-thirty-two-bytes", accountId: crypto.randomUUID(),
    fetcher: (async () => { throw new Error("no network"); }) as typeof fetch, waitUntil: () => undefined,
    macs: () => macs,
    runOnMac: async (mac, command) => {
      if (offline) throw new (await import("@axo/apps")).ProviderError(0, `${mac}: host offline; nothing sent`);
      if (lost) throw new ProviderOutcomeUnknown(`${mac} did not answer; the command may have run`);
      const r = { mac, ...parse(command) };
      ran.push(r);
      if (next) return { timedOut: false, ...next(r) };
      const [, noun, verb, name] = r.args;
      if (noun === "item" && verb === "get") {
        const found = items[name!] as { fields: Array<{ type: string; value?: string }> } | undefined;
        if (!found) return { exitCode: 1, stdout: "", stderr: `[ERROR] 2026/10/31 12:00:00 "${name}" isn't an item.`, timedOut: false };
        const reveal = r.args.includes("--reveal");
        const shown = { ...found, fields: found.fields.map((f) => (f.type === "CONCEALED" && !reveal ? { ...f, value: undefined } : f)) };
        return { exitCode: 0, stdout: JSON.stringify(shown), stderr: "", timedOut: false };
      }
      if (noun === "item" && verb === "create") {
        const template = JSON.parse(r.stdin!) as { title: string };
        return { exitCode: 0, stdout: JSON.stringify({ id: "new", title: template.title, category: "LOGIN", vault: { name: "Private" }, fields: [] }), stderr: "", timedOut: false };
      }
      if (noun === "read") return { exitCode: 0, stdout: "hunter2", stderr: "", timedOut: false };
      return { exitCode: 0, stdout: "[]", stderr: "", timedOut: false };
    },
  });
  return { apps, ran, setNext: (f: typeof next) => { next = f; }, setOffline: (v: boolean) => { offline = v; }, setLost: (v: boolean) => { lost = v; } };
}

async function refused(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (error) {
    return (error as Error).message;
  }
  assert.fail("expected a refusal");
}

test("a command's arguments are each quoted, and its input is piped from a builtin, never an argument", () => {
  assert.equal(macCommand(["op", "item", "get", "it's; rm -rf ~"]), `'op' 'item' 'get' 'it'\\''s; rm -rf ~'`);
  const piped = macCommand(["op", "item", "create", "--template=/dev/stdin"], JSON.stringify({ password: "hunter2" }));
  assert.ok(!piped.includes("hunter2"));
  assert.deepEqual(parse(piped), { args: ["op", "item", "create", "--template=/dev/stdin"], stdin: JSON.stringify({ password: "hunter2" }) });
});

test("1Password's accounts are the account's Macs; it is listed only where Macs can be reached", () => {
  const { apps } = fixture();
  const listed = connectionSchema.parse(apps.list().find((c) => c.name === "apps.onepassword"));
  assert.ok(listed.kind === "app");
  assert.deepEqual(listed.accounts.map((a) => a.account), ["studio", "leo_s_laptop"]);
  assert.equal(listed.signIn.kind, "mac");
  assert.ok(!listed.tools.includes("request"), "a Mac app has no HTTP API");
  assert.ok(listed.tools.includes("op"));
  const bare = new BuiltinApps({ sql: sqlStorage(), secret: "test-secret-of-at-least-thirty-two-bytes", accountId: crypto.randomUUID(), fetcher: fetch, waitUntil: () => undefined });
  assert.equal(bare.list().some((c) => c.name === "apps.onepassword"), false);
});

test("each call runs op on the Mac it names; secrets stay hidden unless asked for, and values go in on standard input", async () => {
  const { apps, ran } = fixture();
  const item = (await apps.call("onepassword", "get_item", { account: "studio", item: "GitHub", vault: "Private" })) as { fields: Array<{ label: string; value: string | null }> };
  assert.deepEqual(item.fields.map((f) => [f.label, f.value]), [["username", "leostera"], ["password", null]]);
  assert.deepEqual(ran.at(-1), { mac: "studio", args: ["op", "item", "get", "GitHub", "--vault", "Private", "--format", "json"], stdin: null });
  const revealed = (await apps.call("onepassword", "get_item", { account: "leo_s_laptop", item: "GitHub", reveal: true, opAccount: "my.1password.com" })) as { fields: Array<{ value: string | null }> };
  assert.equal(revealed.fields[1]!.value, "hunter2");
  assert.deepEqual(ran.at(-1)!.args, ["op", "item", "get", "GitHub", "--reveal", "--account", "my.1password.com", "--format", "json"]);
  assert.equal(ran.at(-1)!.mac, "leo_s_laptop");

  assert.deepEqual(await apps.call("onepassword", "read", { account: "studio", reference: "op://Private/GitHub/password" }), { value: "hunter2" });
  assert.match(await refused(apps.call("onepassword", "read", { account: "studio", reference: "Private/GitHub" })), /op:\/\//);

  const created = (await apps.call("onepassword", "create_item", {
    account: "studio", vault: "Private", category: "API Credential", title: "Hetzner", fields: [{ label: "credential", value: "s3cret", type: "concealed" }],
  })) as { title: string };
  assert.equal(created.title, "Hetzner");
  const sent = ran.at(-1)!;
  assert.deepEqual(sent.args, ["op", "item", "create", "--vault", "Private", "--template=/dev/stdin", "--format", "json"]);
  assert.deepEqual(JSON.parse(sent.stdin!).fields, [{ label: "credential", value: "s3cret", type: "CONCEALED" }]);
  assert.equal(JSON.parse(sent.stdin!).category, "API_CREDENTIAL");

  assert.match(await refused(apps.call("onepassword", "list_vaults", { account: "eve" })), /no Mac named eve; the account's Macs: studio, leo_s_laptop/);
  assert.match(await refused(apps.call("onepassword", "op", { account: "studio", args: ["signout"] })), /for the person/);
});

test("op's failures say what to do on the Mac; a lost answer to a write may have run, to a read is only a failure", async () => {
  const { apps, setNext, setOffline, setLost } = fixture();
  setNext(() => ({ exitCode: 1, stdout: "", stderr: "[ERROR] 2026/10/31 12:00:00 no account found for filter" }));
  assert.match(await refused(apps.call("onepassword", "list_vaults", { account: "studio" })), /not signed in: in the 1Password app, turn on Settings, Developer, Integrate with 1Password CLI/);
  setNext(() => ({ exitCode: 127, stdout: "", stderr: "zsh: command not found: op" }));
  assert.match(await refused(apps.call("onepassword", "list_vaults", { account: "studio" })), /not installed on studio/);
  setNext(() => ({ exitCode: null, stdout: "", stderr: "", timedOut: true }));
  assert.match(await refused(apps.call("onepassword", "list_vaults", { account: "studio" })), /approve the Touch ID prompt/);
  setNext(null);
  setOffline(true);
  assert.match(await refused(apps.call("onepassword", "list_vaults", { account: "studio" })), /host offline; nothing sent/);
  setOffline(false);
  setLost(true);
  await assert.rejects(apps.call("onepassword", "create_item", { account: "studio", vault: "Private", category: "Login", title: "x" }), ProviderOutcomeUnknown);
  const read = await refused(apps.call("onepassword", "list_vaults", { account: "studio" }));
  assert.match(read, /may have run/);
  await assert.rejects(apps.call("onepassword", "list_vaults", { account: "studio" }), (e) => !(e instanceof ProviderOutcomeUnknown));
});
