import { z } from "zod";
import { REST } from "@discordjs/rest";
import {
  Routes,
  type RESTGetAPIChannelMessagesResult,
  type RESTGetAPICurrentUserGuildsResult,
  type RESTGetAPICurrentUserResult,
  type RESTGetAPIGuildChannelsResult,
  type RESTPostAPIChannelMessageJSONBody,
  type RESTPostAPIChannelMessageResult,
} from "discord-api-types/v10";
import { tool, type AppDefinition, type AppTool, type Authorized, type ProviderApi } from "../app";

/**
 * A Discord bot as an app: `codemode.apps.discord.<tool>({ account, ... })`, with the bot token
 * from Discord's developer portal, named by the bot's username. Discord does not let a person's
 * own account be automated, so this is a bot, and it sees the servers it was invited to.
 */

const snowflake = z.string().regex(/^\d{15,22}$/, "a Discord ID, such as 1234567890123456789");

/**
 * discord.js's REST client, sending through the gateway's fetch, which puts the bot token on.
 * It neither retries (a write that got no answer may have run) nor sweeps on timers; it still
 * waits out Discord's rate limits.
 */
const rest = (api: ProviderApi) => new REST({
  version: "10",
  api: "https://discord.com/api",
  makeRequest: api.fetch as never,
  retries: 0,
  timeout: 30_000,
  handlerSweepInterval: 0,
  hashSweepInterval: 0,
  userAgentAppendix: "Axo (https://axo.leostera.dev)",
}).setToken("from-the-gateway");

const tools: AppTool[] = [
  tool({
    name: "list_guilds",
    description: "The servers the bot is in: { guilds: [{ id, name, owner }] }.",
    input: z.object({}).strict(),
    idempotent: true,
    async run(api) {
      const guilds = (await rest(api).get(Routes.userGuilds())) as RESTGetAPICurrentUserGuildsResult;
      return { guilds: guilds.map((g) => ({ id: g.id, name: g.name, owner: g.owner ?? false })) };
    },
  }),
  tool({
    name: "list_channels",
    description: "A server's channels: { channels: [{ id, name, type, parent, topic }] }; `type` 0 is text, 2 voice, 4 a category, 5 announcements, 15 a forum.",
    input: z.object({ guild: snowflake }).strict(),
    idempotent: true,
    async run(api, input) {
      const channels = (await rest(api).get(Routes.guildChannels(input.guild))) as RESTGetAPIGuildChannelsResult;
      return { channels: channels.map((c) => ({ id: c.id, name: c.name, type: c.type, parent: c.parent_id ?? null, topic: "topic" in c ? c.topic ?? null : null })) };
    },
  }),
  tool({
    name: "read_messages",
    description: "A channel's messages, newest first: { messages: [{ id, author, content, timestamp, attachments }] }. `before` pages back. Message text needs the bot's Message Content intent.",
    input: z.object({ channel: snowflake, limit: z.number().int().min(1).max(100).optional(), before: snowflake.optional() }).strict(),
    idempotent: true,
    async run(api, input) {
      const query = new URLSearchParams({ limit: String(input.limit ?? 50), ...(input.before ? { before: input.before } : {}) });
      const messages = (await rest(api).get(Routes.channelMessages(input.channel), { query })) as RESTGetAPIChannelMessagesResult;
      return { messages: messages.map((m) => ({ id: m.id, author: m.author.username, bot: m.author.bot ?? false, content: m.content, timestamp: m.timestamp, attachments: m.attachments.map((a) => ({ name: a.filename, url: a.url })) })) };
    },
  }),
  tool({
    name: "send_message",
    description: "Posts a message as the bot in a channel, or replies to one. Returns { id }.",
    input: z.object({ channel: snowflake, content: z.string().min(1).max(2000), replyTo: snowflake.optional() }).strict(),
    idempotent: false,
    async run(api, input) {
      const body: RESTPostAPIChannelMessageJSONBody = { content: input.content, message_reference: input.replyTo ? { message_id: input.replyTo } : undefined, allowed_mentions: { parse: [] } };
      const sent = (await rest(api).post(Routes.channelMessages(input.channel), { body })) as RESTPostAPIChannelMessageResult;
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
      const me = (await rest(api).get(Routes.user())) as RESTGetAPICurrentUserResult;
      return me.username?.toLowerCase() ?? null;
    },
  },
  tools,
};
