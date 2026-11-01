import { z } from "zod";
import { macTool, ProviderError, type AppDefinition, type AppTool, type MacShell } from "../app";

/**
 * 1Password as an app: `codemode.apps.onepassword.<tool>({ account, ... })`, where the account is
 * the Mac to ask, such as "studio". It runs the 1Password CLI (`op`) there, signed in through the
 * 1Password app on that Mac, so it reaches every vault the person can, Private included.
 *
 * Why a Mac and not the cloud: 1Password has no OAuth, and its service accounts (the only way in
 * without a person) can never open a Private or Personal vault. Its CLI, integrated with the
 * desktop app, can: the first command of a session asks for Touch ID, and the session then stays
 * unlocked for ten minutes of quiet, at most twelve hours. No secret is stored in the cloud; what
 * a tool returns (a revealed password) passes through the calling script, as any Mac command's
 * output does (RFD0016, Drawbacks).
 */

const vault = z.string().min(1).max(256).optional().describe("A vault's name or ID; every vault when left out.");
const item = z.string().min(1).max(512).describe("An item's name, ID or share link.");
const opAccount = z.string().min(1).max(256).optional()
  .describe("Which 1Password account on the Mac, by its sign-in address, email or ID, when it has more than one (see list_accounts).");
const fieldType = z.enum(["text", "concealed", "email", "url", "phone", "date", "monthYear", "otp"]);

/** Turns `op`'s answer into JSON, or an error a person can act on. */
async function op(shell: MacShell, args: string[], options: { account?: string; stdin?: string; json?: boolean } = {}): Promise<unknown> {
  const full = ["op", ...args, ...(options.account ? ["--account", options.account] : []), ...(options.json === false ? [] : ["--format", "json"])];
  const result = await shell.run(full, { stdin: options.stdin, timeoutMs: 90_000 });
  if (result.timedOut) throw new ProviderError(0, `1Password on ${shell.mac} did not answer in time; approve the Touch ID prompt on the Mac, then try again`);
  if (result.exitCode === 127) throw new ProviderError(0, `the 1Password CLI is not installed on ${shell.mac} (brew install 1password-cli)`);
  if (result.exitCode !== 0) {
    const message = result.stderr.replace(/^\[ERROR\] \S+ \S+ /gm, "").trim().split("\n")[0] ?? "";
    if (/no account found|not currently signed in|sign in/i.test(message))
      throw new ProviderError(0, `1Password on ${shell.mac} is not signed in: in the 1Password app, turn on Settings, Developer, Integrate with 1Password CLI`);
    if (/authorization (was )?(denied|dismissed|timeout)/i.test(message)) throw new ProviderError(0, `1Password on ${shell.mac}: the Touch ID prompt was declined`);
    throw new ProviderError(0, `1Password: ${message.slice(0, 300) || `op exited with ${result.exitCode}`}`);
  }
  if (options.json === false) return result.stdout;
  const text = result.stdout.trim();
  return text ? (JSON.parse(text) as unknown) : null;
}

type Field = { id?: string; label?: string; type?: string; purpose?: string; value?: string; reference?: string; section?: { label?: string } };
type Item = { id: string; title: string; category: string; vault?: { id?: string; name?: string }; urls?: Array<{ href?: string; primary?: boolean }>; tags?: string[]; fields?: Field[]; updated_at?: string };

/** An item as a tool returns it: its fields by label, with `op://` references to read them later. */
function shown(i: Item) {
  return {
    id: i.id,
    title: i.title,
    category: i.category,
    vault: i.vault?.name ?? null,
    urls: (i.urls ?? []).map((u) => u.href).filter(Boolean),
    tags: i.tags ?? [],
    updated: i.updated_at ?? null,
    fields: (i.fields ?? []).filter((f) => f.label || f.id).map((f) => ({
      label: f.label ?? f.id ?? "",
      section: f.section?.label ?? null,
      type: f.type ?? null,
      value: f.value ?? null,
      reference: f.reference ?? null,
    })),
  };
}

const tools: AppTool<any, MacShell>[] = [
  macTool({
    name: "list_accounts",
    description: "Lists the 1Password accounts signed in on the Mac: [{ url, email, user_uuid, account_uuid }].",
    input: z.object({}).strict(),
    idempotent: true,
    async run(shell) {
      return op(shell, ["account", "list"]);
    },
  }),
  macTool({
    name: "list_vaults",
    description: "Lists the vaults the person can open: [{ id, name, content_version }].",
    input: z.object({ opAccount }).strict(),
    idempotent: true,
    async run(shell, input) {
      return op(shell, ["vault", "list"], { account: input.opAccount });
    },
  }),
  macTool({
    name: "list_items",
    description: "Lists items, without their secrets: [{ id, title, category, vault, urls, tags, updated_at }]. Filter by vault, categories (\"Login\", \"Password\", \"API Credential\", ...) and tags.",
    input: z.object({
      opAccount,
      vault,
      categories: z.array(z.string().min(1).max(64)).max(20).optional(),
      tags: z.array(z.string().min(1).max(128)).max(20).optional(),
    }).strict(),
    idempotent: true,
    async run(shell, input) {
      const args = ["item", "list", ...(input.vault ? ["--vault", input.vault] : []), ...(input.categories ? ["--categories", input.categories.join(",")] : []), ...(input.tags ? ["--tags", input.tags.join(",")] : [])];
      return op(shell, args, { account: input.opAccount });
    },
  }),
  macTool({
    name: "get_item",
    description:
      "Gets one item with its fields: { id, title, category, vault, urls, tags, fields: [{ label, section, type, value, reference }] }. " +
      "Secret fields (passwords, keys) are hidden unless `reveal` is true; a field's `reference` (op://vault/item/field) reads it later with `read`.",
    input: z.object({ opAccount, item, vault, reveal: z.boolean().optional() }).strict(),
    idempotent: true,
    async run(shell, input) {
      const found = (await op(shell, ["item", "get", input.item, ...(input.vault ? ["--vault", input.vault] : []), ...(input.reveal ? ["--reveal"] : [])], { account: input.opAccount })) as Item;
      return shown(found);
    },
  }),
  macTool({
    name: "read",
    description: "Reads one field by its secret reference, such as \"op://Private/GitHub/password\" or \"op://Private/GitHub/one-time password?attribute=otp\": { value }.",
    input: z.object({ opAccount, reference: z.string().regex(/^op:\/\/[^\r\n]{3,1024}$/, "a reference starts with op://") }).strict(),
    idempotent: true,
    async run(shell, input) {
      const value = (await op(shell, ["read", "--no-newline", input.reference], { account: input.opAccount, json: false })) as string;
      return { value };
    },
  }),
  macTool({
    name: "get_otp",
    description: "The current one-time password (TOTP) of an item that has one: { otp }.",
    input: z.object({ opAccount, item, vault }).strict(),
    idempotent: true,
    async run(shell, input) {
      const otp = (await op(shell, ["item", "get", input.item, "--otp", ...(input.vault ? ["--vault", input.vault] : [])], { account: input.opAccount, json: false })) as string;
      return { otp: otp.trim() };
    },
  }),
  macTool({
    name: "create_item",
    description:
      "Creates an item: a Login, Password, API Credential, Secure Note, ... with a title, fields and URLs. `generatePassword` makes a random password for a Login or Password. " +
      "Values go to 1Password through standard input, never on the command line. Returns the item, secrets hidden.",
    input: z.object({
      opAccount,
      vault: z.string().min(1).max(256).describe("The vault to create it in."),
      category: z.string().min(1).max(64).describe("\"Login\", \"Password\", \"API Credential\", \"Secure Note\", ..."),
      title: z.string().min(1).max(512),
      urls: z.array(z.url()).max(20).optional(),
      tags: z.array(z.string().min(1).max(128)).max(20).optional(),
      fields: z.array(z.object({
        label: z.string().min(1).max(256),
        value: z.string().max(65_536),
        type: fieldType.optional().describe("\"concealed\" for a secret; \"text\" when left out."),
        purpose: z.enum(["USERNAME", "PASSWORD", "NOTES"]).optional().describe("Marks the item's built-in username, password or notes field."),
      }).strict()).max(100).optional(),
      generatePassword: z.object({ length: z.number().int().min(1).max(64).optional(), symbols: z.boolean().optional() }).strict().optional(),
    }).strict(),
    idempotent: false,
    async run(shell, input) {
      const template = {
        title: input.title,
        category: input.category.toUpperCase().replace(/\s+/g, "_"),
        tags: input.tags,
        urls: input.urls?.map((href, i) => ({ href, primary: i === 0 })),
        fields: input.fields?.map((f) => ({ label: f.label, value: f.value, type: (f.type ?? (f.purpose === "PASSWORD" ? "concealed" : "text")).toUpperCase(), ...(f.purpose ? { purpose: f.purpose } : {}) })),
      };
      const recipe = input.generatePassword ? [`--generate-password=letters,digits${input.generatePassword.symbols === false ? "" : ",symbols"},${input.generatePassword.length ?? 32}`] : [];
      const created = (await op(shell, ["item", "create", "--vault", input.vault, "--template=/dev/stdin", ...recipe], { account: input.opAccount, stdin: JSON.stringify(template) })) as Item;
      return shown(created);
    },
  }),
  macTool({
    name: "update_item",
    description:
      "Changes an item: its title, URLs, tags, and the values of fields by label (adding a field that is not there). " +
      "Values go to 1Password through standard input. Returns the item, secrets hidden.",
    input: z.object({
      opAccount,
      item,
      vault,
      title: z.string().min(1).max(512).optional(),
      urls: z.array(z.url()).max(20).optional(),
      tags: z.array(z.string().min(1).max(128)).max(20).optional(),
      fields: z.array(z.object({ label: z.string().min(1).max(256), value: z.string().max(65_536), type: fieldType.optional() }).strict()).max(100).optional(),
    }).strict(),
    idempotent: true,
    async run(shell, input) {
      const where = input.vault ? ["--vault", input.vault] : [];
      const current = (await op(shell, ["item", "get", input.item, ...where, "--reveal"], { account: input.opAccount })) as Item & Record<string, unknown>;
      const fields = [...(current.fields ?? [])];
      for (const change of input.fields ?? []) {
        const existing = fields.find((f) => f.label === change.label);
        if (existing) {
          existing.value = change.value;
          if (change.type) existing.type = change.type.toUpperCase();
        } else fields.push({ label: change.label, value: change.value, type: (change.type ?? "text").toUpperCase() });
      }
      const next = {
        ...current,
        ...(input.title ? { title: input.title } : {}),
        ...(input.tags ? { tags: input.tags } : {}),
        ...(input.urls ? { urls: input.urls.map((href, i) => ({ href, primary: i === 0 })) } : {}),
        fields,
      };
      const updated = (await op(shell, ["item", "edit", current.id, ...where, "--template=/dev/stdin"], { account: input.opAccount, stdin: JSON.stringify(next) })) as Item;
      return shown({ ...updated, fields: (updated.fields ?? []).map((f) => (f.type === "CONCEALED" ? { ...f, value: undefined } : f)) });
    },
  }),
  macTool({
    name: "delete_item",
    description: "Moves an item to the archive, where it can be restored; `permanently` deletes it for good instead. Prefer the archive unless asked. Returns { deleted: true }.",
    input: z.object({ opAccount, item, vault, permanently: z.boolean().optional() }).strict(),
    idempotent: true,
    async run(shell, input) {
      await op(shell, ["item", "delete", input.item, ...(input.vault ? ["--vault", input.vault] : []), ...(input.permanently ? [] : ["--archive"])], { account: input.opAccount, json: false });
      return { deleted: true };
    },
  }),
  macTool({
    name: "op",
    description:
      "Runs any other 1Password CLI command, as arguments after `op`, such as [\"document\", \"get\", \"Passport\"] or [\"item\", \"share\", \"GitHub\"]: " +
      "{ exitCode, stdout, stderr }. See https://developer.1password.com/docs/cli/reference. `signin`, `signout` and `account forget` are refused.",
    input: z.object({
      opAccount,
      args: z.array(z.string().max(4096)).min(1).max(64),
      stdin: z.string().max(1_000_000).optional().describe("Fed to the command's standard input, such as an item template."),
    }).strict(),
    idempotent: false,
    async run(shell, input) {
      const [command, sub] = input.args;
      if (command === "signin" || command === "signout" || (command === "account" && (sub === "forget" || sub === "add")))
        throw new ProviderError(0, "signing 1Password in or out is for the person, on the Mac");
      const result = await shell.run(["op", ...input.args, ...(input.opAccount ? ["--account", input.opAccount] : [])], { stdin: input.stdin, timeoutMs: 90_000 });
      return { exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr };
    },
  }),
];

export const onepassword: AppDefinition = {
  name: "onepassword",
  title: "1Password",
  description: "Your passwords, keys and secure notes, from the 1Password app on your Mac.",
  permissions: [
    "See your vaults and items, and read passwords, keys and one-time codes when a Session asks",
    "Create, change and archive items",
    "Anything else the 1Password command line can do, except signing in or out",
  ],
  signIn: "mac",
  provider: "1password",
  providerTitle: "1Password",
  category: "security",
  setup: "On each Mac, install the 1Password command line (brew install 1password-cli), then in the 1Password app turn on Settings, Developer, Integrate with 1Password CLI. The Mac asks for Touch ID the first time a Session uses it, then stays unlocked for ten minutes.",
  reference: "https://developer.1password.com/docs/cli/reference",
  tools,
};
