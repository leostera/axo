import { z } from "zod";
import { tool, type AppDefinition, type AppTool, type Authorized, type OutgoingRequest } from "../app";

/**
 * A Telegram bot as an app: `codemode.apps.telegram.<tool>({ account, ... })`, with the token
 * @BotFather gives, named by the bot's username. Telegram's Bot API takes the token in the path
 * (`/bot<token>/<method>`), so tools call `/<method>` and the token goes in as the call leaves.
 * A bot sees only chats it is in, and messages sent to it.
 */

const chat = z.union([z.number().int(), z.string().regex(/^@\w{4,64}$/)]).describe("A chat's ID, or a public channel's @username.");

type Answer<T> = { ok: boolean; result: T; description?: string };

async function call<T>(api: Parameters<AppTool["run"]>[0], method: string, body: Record<string, unknown> = {}): Promise<T> {
  const answer = (await api.request("POST", `/${method}`, { body })) as Answer<T>;
  return answer.result;
}

const tools: AppTool[] = [
  tool({
    name: "get_me",
    description: "The bot itself: { id, username, first_name, can_join_groups, can_read_all_group_messages }.",
    input: z.object({}).strict(),
    idempotent: true,
    run: (api) => call(api, "getMe"),
  }),
  tool({
    name: "get_updates",
    description:
      "New messages and other updates sent to the bot since `offset`: [{ update_id, message?, channel_post?, callback_query?, ... }]. " +
      "Pass the last update_id + 1 as `offset` to mark the earlier ones read; Telegram keeps unread updates for a day. Fails while the bot has a webhook.",
    input: z.object({
      offset: z.number().int().optional(),
      limit: z.number().int().min(1).max(100).optional(),
      timeoutSeconds: z.number().int().min(0).max(50).optional().describe("Wait this long for an update when there is none; 0 when left out."),
    }).strict(),
    idempotent: true,
    run: (api, input) => api.request("POST", "/getUpdates", { body: { offset: input.offset, limit: input.limit, timeout: input.timeoutSeconds ?? 0 }, timeoutMs: ((input.timeoutSeconds ?? 0) + 15) * 1000 })
      .then((answer) => (answer as Answer<unknown>).result),
  }),
  tool({
    name: "send_message",
    description: "Sends a message from the bot to a chat it is in, or to a person who has started it. Returns the sent message. `parseMode` formats the text.",
    input: z.object({
      chat,
      text: z.string().min(1).max(4096),
      parseMode: z.enum(["MarkdownV2", "HTML"]).optional(),
      replyTo: z.number().int().optional().describe("The message ID to reply to."),
      silent: z.boolean().optional().describe("Send without a notification sound."),
    }).strict(),
    idempotent: false,
    run: (api, input) => call(api, "sendMessage", {
      chat_id: input.chat, text: input.text, parse_mode: input.parseMode, disable_notification: input.silent,
      reply_parameters: input.replyTo === undefined ? undefined : { message_id: input.replyTo },
    }),
  }),
  tool({
    name: "get_chat",
    description: "A chat the bot is in: { id, type, title?, username?, description?, ... }.",
    input: z.object({ chat }).strict(),
    idempotent: true,
    run: (api, input) => call(api, "getChat", { chat_id: input.chat }),
  }),
  tool({
    name: "call",
    description: "Any other Bot API method, such as editMessageText or sendPhoto with a URL, with its parameters as Telegram names them. Returns its `result`. See core.telegram.org/bots/api.",
    input: z.object({ method: z.string().regex(/^[a-zA-Z]{3,64}$/), params: z.record(z.string(), z.unknown()).optional() }).strict(),
    idempotent: false,
    run: (api, input) => call(api, input.method, input.params ?? {}),
  }),
];

/** The token into the path: `/getMe` becomes `/bot<token>/getMe`. */
function inPath(fields: Readonly<Record<string, string>>, request: OutgoingRequest): Authorized {
  const url = new URL(request.url);
  url.pathname = `/bot${fields.token}${url.pathname}`;
  return { headers: {}, url };
}

export const telegram: AppDefinition = {
  name: "telegram",
  title: "Telegram",
  description: "A Telegram bot of yours: read what people send it, and send messages as it.",
  permissions: [
    "Read messages sent to your bot, and in the groups it is in",
    "Send messages as your bot",
    "Anything else Telegram's Bot API lets your bot do",
  ],
  signIn: "token",
  provider: "telegram",
  providerTitle: "Telegram",
  category: "communication",
  apiOrigin: "https://api.telegram.org",
  hosts: ["api.telegram.org"],
  reference: "https://core.telegram.org/bots/api",
  token: {
    helpUrl: "https://t.me/BotFather",
    named: false,
    fields: [{ name: "token", label: "Bot token", help: "Message @BotFather in Telegram, send /newbot (or /token for a bot you have), and paste the token it gives you.", secret: true }],
    authorize: inPath,
    async identify(api) {
      const me = await call<{ username?: string }>(api, "getMe");
      return me.username ? `@${me.username.toLowerCase()}` : null;
    },
  },
  tools,
};
