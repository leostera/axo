import { z } from "zod";
import { tool, type AppDefinition, type AppTool, type ProviderApi } from "../app";
import type { Authorized } from "../app";

/**
 * A Discord bot as an app: `codemode.apps.discord.<tool>({ account, ... })`, with the bot token
 * from Discord's developer portal, named by the bot's username. Discord does not let a person's
 * own account be automated, so this is a bot, and it sees the servers it was invited to.
 */

const snowflake = z.string().regex(/^\d{15,22}$/, "a Discord ID, such as 1234567890123456789");
const get = (api: ProviderApi, path: string, query: Record<string, string | undefined> = {}) => api.request("GET", `/api/v10${path}`, { query });

const tools: AppTool[] = [
  tool({
    name: "list_guilds",
    description: "The servers the bot is in: { guilds: [{ id, name, owner }] }.",
    input: z.object({}).strict(),
    idempotent: true,
    async run(api) {
      const guilds = (await get(api, "/users/@me/guilds")) as Array<{ id: string; name: string; owner?: boolean }>;
      return { guilds: guilds.map((g) => ({ id: g.id, name: g.name, owner: g.owner ?? false })) };
    },
  }),
  tool({
    name: "list_channels",
    description: "A server's channels: { channels: [{ id, name, type, parent, topic }] }; `type` 0 is text, 2 voice, 4 a category, 5 announcements, 15 a forum.",
    input: z.object({ guild: snowflake }).strict(),
    idempotent: true,
    async run(api, input) {
      const channels = (await get(api, `/guilds/${input.guild}/channels`)) as Array<{ id: string; name: string; type: number; parent_id?: string | null; topic?: string | null }>;
      return { channels: channels.map((c) => ({ id: c.id, name: c.name, type: c.type, parent: c.parent_id ?? null, topic: c.topic ?? null })) };
    },
  }),
  tool({
    name: "read_messages",
    description: "A channel's messages, newest first: { messages: [{ id, author, content, timestamp, attachments }] }. `before` pages back. Message text needs the bot's Message Content intent.",
    input: z.object({ channel: snowflake, limit: z.number().int().min(1).max(100).optional(), before: snowflake.optional() }).strict(),
    idempotent: true,
    async run(api, input) {
      const messages = (await get(api, `/channels/${input.channel}/messages`, { limit: String(input.limit ?? 50), before: input.before })) as Array<{ id: string; author: { username: string; bot?: boolean }; content: string; timestamp: string; attachments?: Array<{ filename: string; url: string }> }>;
      return { messages: messages.map((m) => ({ id: m.id, author: m.author.username, bot: m.author.bot ?? false, content: m.content, timestamp: m.timestamp, attachments: (m.attachments ?? []).map((a) => ({ name: a.filename, url: a.url })) })) };
    },
  }),
  tool({
    name: "send_message",
    description: "Posts a message as the bot in a channel, or replies to one. Returns { id }.",
    input: z.object({ channel: snowflake, content: z.string().min(1).max(2000), replyTo: snowflake.optional() }).strict(),
    idempotent: false,
    async run(api, input) {
      const sent = (await api.request("POST", `/api/v10/channels/${input.channel}/messages`, {
        body: { content: input.content, message_reference: input.replyTo ? { message_id: input.replyTo } : undefined, allowed_mentions: { parse: [] } },
      })) as { id: string };
      return { id: sent.id };
    },
  }),
];

export const discord: AppDefinition = {
  name: "discord",
  title: "Discord",
  description: "A Discord bot of yours: read the channels of the servers it is in, and post as it.",
  permissions: [
    "See the servers and channels your bot is in",
    "Read messages in those channels",
    "Post messages as your bot",
  ],
  signIn: "token",
  provider: "discord",
  providerTitle: "Discord",
  category: "communication",
  apiOrigin: "https://discord.com",
  hosts: ["discord.com"],
  reference: "https://discord.com/developers/docs/reference",
  token: {
    helpUrl: "https://discord.com/developers/applications",
    named: false,
    fields: [{ name: "token", label: "Bot token", help: "In Discord's developer portal, open your application, then Bot, and reset the token to copy it. Invite the bot to your servers from OAuth2.", secret: true }],
    authorize: (fields): Authorized => ({ headers: { Authorization: `Bot ${fields.token}`, "User-Agent": "DiscordBot (https://axo.leostera.dev, 1)" } }),
    async identify(api) {
      const me = (await get(api, "/users/@me")) as { username?: string };
      return me.username?.toLowerCase() ?? null;
    },
  },
  tools,
};
