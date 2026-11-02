import bigInt from "big-integer";
import { Api, TelegramClient } from "telegram";
import { RPCError } from "telegram/errors/index.js";
import { computeCheck } from "telegram/Password.js";
import { StringSession } from "telegram/sessions/index.js";
import { z } from "zod";
import { clientTool, PhoneRefused, ProviderError, type AppDefinition, type AppTool, type PhoneClient, type PhoneFailure, type PhoneSignIn, type PhoneStep } from "../app";

/**
 * The person's own Telegram account as an app: `codemode.apps.telegram.<tool>({ account, ... })`.
 * Telegram's Bot API only acts as a bot, so this speaks MTProto, Telegram's own protocol, with
 * GramJS: it signs in as a new device of the person's (Settings › Devices lists it, and ending it
 * there signs Axo out), with an API ID and hash they registered at my.telegram.org. In a Worker it
 * reaches Telegram over TCP (Workers' `node:net`). Secret chats live only on the person's phones,
 * so no tool sees them. Each call opens the session and closes it, about a second or two.
 */

const DEVICE = { deviceModel: "Axo", systemVersion: "Cloudflare Workers", appVersion: "1.0", langCode: "en", systemLangCode: "en" };

async function connect(client: PhoneClient, session: string): Promise<TelegramClient> {
  const telegram = new TelegramClient(new StringSession(session), client.apiId, client.apiHash, { ...DEVICE, connectionRetries: 1, autoReconnect: false });
  // GramJS logs what it sends; nothing of a session belongs in a Worker's logs.
  telegram.setLogLevel("none" as never);
  await telegram.connect();
  return telegram;
}

async function closed<T>(telegram: TelegramClient, work: () => Promise<T>): Promise<T> {
  try {
    return await work();
  } finally {
    await telegram.destroy().catch(() => undefined);
  }
}

/** Telegram's error codes a person can act on, in plain words; the rest as Telegram names them. */
function signInError(error: unknown): never {
  if (!(error instanceof RPCError)) throw error;
  const code = error.errorMessage;
  const wait = (error as { seconds?: number }).seconds;
  if (code === "PHONE_CODE_INVALID") throw new PhoneRefused("That code is not right. Check it in Telegram and try again.");
  if (code === "PHONE_CODE_EXPIRED") throw new PhoneRefused("That code expired. Start again for a new one.", true);
  if (code === "PHONE_NUMBER_INVALID") throw new PhoneRefused("Telegram does not know that number. Enter it with its country code, such as +44 7700 900123.", true);
  if (code === "PHONE_NUMBER_BANNED") throw new PhoneRefused("Telegram has banned that number.", true);
  if (code === "PASSWORD_HASH_INVALID") throw new PhoneRefused("That password is not right.");
  if (code === "API_ID_INVALID" || code === "API_ID_PUBLISHED_FLOOD") throw new PhoneRefused("Telegram does not take that API ID and hash. Check them at my.telegram.org, then set them up again.", true);
  if (code === "FLOOD_WAIT" || code.startsWith("FLOOD_WAIT")) throw new PhoneRefused(`Telegram asks to wait ${Math.ceil((wait ?? 60) / 60)} minutes before trying again.`, true);
  throw new PhoneRefused(`Telegram refused: ${code}`, true);
}

type Pending = { session: string; hash?: string };
const pendingOf = (text: string): Pending => JSON.parse(text) as Pending;

/** The account's name: its @username, else its phone number, else its ID. */
async function done(telegram: TelegramClient): Promise<PhoneStep> {
  const me = (await telegram.getMe()) as Api.User;
  const account = me.username ? `@${me.username.toLowerCase()}` : me.phone ? `+${me.phone}` : String(me.id);
  return { step: "done", session: telegram.session.save() as unknown as string, account };
}

async function passwordStep(telegram: TelegramClient): Promise<PhoneStep> {
  const password = await telegram.invoke(new Api.account.GetPassword());
  return { step: "password", pending: JSON.stringify({ session: telegram.session.save() }), hint: password.hint ?? null };
}

/** Codes that mean the session is over: ended on another device, or the account is gone. */
const ENDED = new Set(["AUTH_KEY_UNREGISTERED", "AUTH_KEY_INVALID", "SESSION_REVOKED", "SESSION_EXPIRED", "USER_DEACTIVATED", "USER_DEACTIVATED_BAN", "AUTH_KEY_DUPLICATED"]);

export const telegramSignIn: PhoneSignIn<TelegramClient> = {
  consoleUrl: "https://my.telegram.org/apps",
  clientHelp: "Sign in at my.telegram.org with your phone number, open API development tools, and create an app (any name; platform Other). Telegram shows its api_id and api_hash.",
  async sendCode(client, phone) {
    const telegram = await connect(client, "");
    return closed(telegram, async () => {
      try {
        // GramJS follows Telegram to the number's own data centre, and the session moves with it.
        const sent = await telegram.sendCode({ apiId: client.apiId, apiHash: client.apiHash }, phone);
        return { step: "code", pending: JSON.stringify({ session: telegram.session.save(), hash: sent.phoneCodeHash }), via: sent.isCodeViaApp ? "app" : "sms" };
      } catch (error) {
        signInError(error);
      }
    });
  },
  async enterCode(client, pending, phone, code) {
    const state = pendingOf(pending);
    const telegram = await connect(client, state.session);
    return closed(telegram, async () => {
      try {
        const answer = await telegram.invoke(new Api.auth.SignIn({ phoneNumber: phone, phoneCodeHash: state.hash!, phoneCode: code }));
        if (answer instanceof Api.auth.AuthorizationSignUpRequired) throw new PhoneRefused("That number has no Telegram account. Sign up in Telegram first.", true);
        return await done(telegram);
      } catch (error) {
        if (error instanceof RPCError && error.errorMessage === "SESSION_PASSWORD_NEEDED") return passwordStep(telegram);
        if (error instanceof PhoneRefused) throw error;
        signInError(error);
      }
    });
  },
  async enterPassword(client, pending, password) {
    const telegram = await connect(client, pendingOf(pending).session);
    return closed(telegram, async () => {
      try {
        const current = await telegram.invoke(new Api.account.GetPassword());
        await telegram.invoke(new Api.auth.CheckPassword({ password: await computeCheck(current, password) }));
        return await done(telegram);
      } catch (error) {
        signInError(error);
      }
    });
  },
  async open(client, session) {
    const telegram = await connect(client, session);
    return {
      api: telegram,
      async close() {
        const now = telegram.session.save() as unknown as string;
        await telegram.destroy().catch(() => undefined);
        return now;
      },
    };
  },
  async logOut(client, session) {
    const telegram = await connect(client, session);
    await closed(telegram, () => telegram.invoke(new Api.auth.LogOut()));
  },
  failure(error): PhoneFailure {
    if (error instanceof RPCError) {
      if (ENDED.has(error.errorMessage)) return { kind: "ended" };
      return { kind: "refused", message: `Telegram: ${error.errorMessage}` };
    }
    if (error instanceof ProviderError) return { kind: "refused", message: error.message };
    return { kind: "unknown" };
  },
};

const chat = z.union([z.number().int(), z.string().regex(/^(me|@\w{4,64}|\+\d{6,20}|-?\d{1,20})$/)])
  .describe("A chat: its ID from list_chats, a @username, a phone number in your contacts (+44...), or \"me\" for Saved Messages.");

/** A chat as GramJS resolves it; one only known by ID is found among the dialogs, as GramJS caches entities only for this connection. */
async function resolve(telegram: TelegramClient, target: string | number): Promise<Api.TypeInputPeer> {
  const key = typeof target === "number" || /^-?\d+$/.test(target) ? bigInt(String(target)) : target;
  try {
    return await telegram.getInputEntity(key);
  } catch {
    await telegram.getDialogs({ limit: 200 });
    try {
      return await telegram.getInputEntity(key);
    } catch {
      throw new ProviderError(404, `Telegram: no chat ${String(target)}; use an ID from list_chats or a @username`);
    }
  }
}

type Message = Api.Message;
const message = (m: Message) => ({
  id: m.id,
  date: new Date(m.date * 1000).toISOString(),
  chat: m.chatId?.toString() ?? null,
  from: m.senderId?.toString() ?? null,
  out: m.out ?? false,
  text: m.message ?? "",
  replyTo: m.replyTo && "replyToMsgId" in m.replyTo ? m.replyTo.replyToMsgId ?? null : null,
  media: m.media ? m.media.className.replace(/^MessageMedia/, "").toLowerCase() : null,
});

const tool = clientTool<TelegramClient>();

const tools: AppTool<any, TelegramClient>[] = [
  tool({
    name: "get_me",
    description: "Your Telegram account: { id, username, firstName, lastName, phone }.",
    input: z.object({}).strict(),
    idempotent: true,
    async run(telegram) {
      const me = (await telegram.getMe()) as Api.User;
      return { id: me.id.toString(), username: me.username ?? null, firstName: me.firstName ?? null, lastName: me.lastName ?? null, phone: me.phone ?? null };
    },
  }),
  tool({
    name: "list_chats",
    description: "Your chats, most recent first: { chats: [{ id, title, type, username, unread, pinned, last }] }; `type` is user, group or channel, `last` the newest message.",
    input: z.object({ limit: z.number().int().min(1).max(100).optional().describe("Default 30."), archived: z.boolean().optional().describe("The archived chats instead.") }).strict(),
    idempotent: true,
    async run(telegram, input: { limit?: number; archived?: boolean }) {
      const dialogs = await telegram.getDialogs({ limit: input.limit ?? 30, archived: input.archived });
      return {
        chats: dialogs.map((d) => ({
          id: d.id?.toString() ?? null,
          title: d.title ?? d.name ?? "",
          type: d.isUser ? "user" : d.isGroup ? "group" : d.isChannel ? "channel" : "other",
          username: (d.entity as { username?: string } | undefined)?.username ?? null,
          unread: d.unreadCount,
          pinned: d.pinned,
          last: d.message ? message(d.message) : null,
        })),
      };
    },
  }),
  tool({
    name: "read_messages",
    description: "A chat's messages, newest first: { messages: [{ id, date, from, out, text, replyTo, media }] }. `before` pages back from a message ID.",
    input: z.object({ chat, limit: z.number().int().min(1).max(100).optional().describe("Default 30."), before: z.number().int().positive().optional() }).strict(),
    idempotent: true,
    async run(telegram, input: { chat: string | number; limit?: number; before?: number }) {
      const messages = await telegram.getMessages(await resolve(telegram, input.chat), { limit: input.limit ?? 30, offsetId: input.before });
      return { messages: messages.map(message) };
    },
  }),
  tool({
    name: "search",
    description: "Messages matching words, newest first, in one chat or in all of them: { messages: [{ id, date, chat, from, out, text, ... }] }.",
    input: z.object({ query: z.string().min(1).max(256), chat: chat.optional(), limit: z.number().int().min(1).max(100).optional().describe("Default 30.") }).strict(),
    idempotent: true,
    async run(telegram, input: { query: string; chat?: string | number; limit?: number }) {
      const where = input.chat === undefined ? undefined : await resolve(telegram, input.chat);
      const messages = await telegram.getMessages(where, { search: input.query, limit: input.limit ?? 30 });
      return { messages: messages.map(message) };
    },
  }),
  tool({
    name: "send_message",
    description: "Sends a message as you, or a reply to one. Returns { id, date }.",
    input: z.object({ chat, text: z.string().min(1).max(4096), replyTo: z.number().int().positive().optional(), silent: z.boolean().optional().describe("Without a notification sound.") }).strict(),
    idempotent: false,
    async run(telegram, input: { chat: string | number; text: string; replyTo?: number; silent?: boolean }) {
      const sent = await telegram.sendMessage(await resolve(telegram, input.chat), { message: input.text, replyTo: input.replyTo, silent: input.silent });
      return { id: sent.id, date: new Date(sent.date * 1000).toISOString() };
    },
  }),
  tool({
    name: "mark_read",
    description: "Marks a chat's messages read. Returns { ok }.",
    input: z.object({ chat }).strict(),
    idempotent: true,
    async run(telegram, input: { chat: string | number }) {
      return { ok: await telegram.markAsRead(await resolve(telegram, input.chat)) };
    },
  }),
];

export const telegram: AppDefinition = {
  name: "telegram",
  title: "Telegram",
  description: "Your own Telegram account: read and search your chats, and send messages as you.",
  permissions: [
    "See your chats, groups and channels, and read and search their messages (not secret chats)",
    "Send messages as you",
    "Mark chats read",
  ],
  signIn: "phone",
  provider: "telegram",
  providerTitle: "Telegram",
  category: "communication",
  reference: "https://core.telegram.org/methods",
  phone: telegramSignIn,
  tools,
};
