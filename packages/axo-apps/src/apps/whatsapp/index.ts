import { z } from "zod";
import { clientTool, ProviderError, type LinkedApp } from "../../app";
import type { WhatsAppDevice } from "./device";
import type { ShownMessage } from "./store";

/**
 * WhatsApp as an app: `codemode.apps.whatsapp.<tool>({ account, ... })`, where the account is the
 * person's number, such as "+447700900123". Axo is a linked device of theirs, as WhatsApp's
 * Web is, through Baileys (RFD0016, Linked devices). Its tools read what that device was
 * sent: the history WhatsApp synced when it was linked, and every message since. They only read;
 * nothing is sent, and nothing is marked as read.
 *
 * Baileys is not WhatsApp's: WhatsApp may restrict an account it sees using it, and a change to
 * WhatsApp's protocol can break it until Baileys catches up. The page says so before linking.
 */

const tool = clientTool<WhatsAppDevice>();

const chatId = z.string().min(3).max(128)
  .describe("The chat: its id from list_chats (such as 447700900123@s.whatsapp.net, or …@g.us for a group), or a phone number with its country code.");

/** A chat as `list_chats` gives it: an ID, a phone number or a group's, from what the person typed. */
export function chatJid(value: string): string {
  const trimmed = value.trim();
  if (trimmed.includes("@")) return trimmed;
  const digits = trimmed.replace(/[^\d]/g, "");
  if (digits.length < 6) throw new ProviderError(400, `${value.slice(0, 64)} is not a chat id or a phone number`);
  return `${digits}@s.whatsapp.net`;
}

const iso = (at: number | null) => (at ? new Date(at * 1000).toISOString() : null);

function shown(message: ShownMessage, options: { chat?: boolean } = {}) {
  return {
    id: message.id,
    ...(options.chat ? { chat_id: message.chatId, chat: message.chatName } : {}),
    at: iso(message.at),
    from: message.fromMe ? "me" : message.senderName ?? message.sender,
    from_id: message.fromMe ? null : message.sender,
    type: message.type,
    text: message.deleted ? "[deleted]" : message.text,
    reply_to: message.quotedId,
  };
}

export const whatsapp: LinkedApp = {
  name: "whatsapp",
  title: "WhatsApp",
  description: "Read and search your WhatsApp chats, as a linked device of your account.",
  permissions: [
    "Read your chats and the messages WhatsApp gives a linked device",
    "Search them",
    "Never sends messages or marks them as read",
  ],
  providerTitle: "WhatsApp",
  category: "communication",
  signIn: "linked",
  provider: "whatsapp",
  reference: "https://baileys.wiki/docs/intro",
  helpUrl: "https://faq.whatsapp.com/378279804439436",
  tools: [
    tool({
      name: "get_me",
      description: "The linked account: its number and name, whether Axo is connected to WhatsApp now, when it was linked, and how much history Axo holds (chats, messages, the oldest message's date).",
      input: z.object({}).strict(),
      idempotent: true,
      run: async (device) => {
        const counts = device.store.counts();
        return {
          account: device.store.setting("account"),
          name: device.store.setting("name"),
          connected: device.connected(),
          linked_at: device.store.setting("linked_at"),
          chats: counts.chats,
          messages: counts.messages,
          oldest_message_at: iso(counts.oldest),
        };
      },
    }),
    tool({
      name: "list_chats",
      description: "Chats, the most recent first, with each one's name, unread count and last message. Only what WhatsApp synced to Axo's device: older chats may be missing.",
      input: z.object({
        query: z.string().min(1).max(128).optional().describe("Only chats whose name or number contains this."),
        unread_only: z.boolean().optional().describe("Only chats with unread messages."),
        archived: z.boolean().optional().describe("true for archived chats only; false, the default, for the rest."),
        limit: z.number().int().min(1).max(100).optional().describe("At most this many; 30 when left out."),
      }).strict(),
      idempotent: true,
      run: async (device, input) => {
        const chats = device.store.chats({ limit: input.limit ?? 30, unreadOnly: input.unread_only, archived: input.archived ?? false, query: input.query });
        return chats.map((chat) => ({
          id: chat.id,
          name: chat.name ?? (chat.isGroup ? "Unnamed group" : `+${chat.id.split("@")[0]}`),
          group: chat.isGroup,
          unread: chat.unread,
          archived: chat.archived,
          last_at: iso(chat.lastAt),
          last: chat.last ? { from: chat.last.fromMe ? "me" : chat.last.senderName ?? chat.last.sender, text: chat.last.deleted ? "[deleted]" : chat.last.text.slice(0, 200) } : null,
        }));
      },
    }),
    tool({
      name: "read_messages",
      description: "A chat's messages, oldest first, ending with the latest (or just before `before`). Media come as [photo], [voice message] and so on, with any caption. Page back with `before` set to `next_before`.",
      input: z.object({
        chat_id: chatId,
        limit: z.number().int().min(1).max(200).optional().describe("At most this many; 50 when left out."),
        before: z.iso.datetime({ offset: true }).optional().describe("Only messages sent before this time (ISO 8601)."),
      }).strict(),
      idempotent: true,
      run: async (device, input) => {
        const id = chatJid(input.chat_id);
        const chat = device.store.chat(id);
        const before = input.before ? Math.floor(Date.parse(input.before) / 1000) : undefined;
        const limit = input.limit ?? 50;
        const messages = device.store.messages(id, { limit, before });
        if (!chat && !messages.length) throw new ProviderError(404, `no chat ${input.chat_id.slice(0, 64)} in what WhatsApp synced; list_chats shows the ones there are`);
        const oldest = messages.at(-1);
        return {
          chat: { id: chat?.id ?? id, name: chat?.name ?? null, group: chat?.isGroup ?? id.endsWith("@g.us") },
          messages: messages.reverse().map((message) => shown(message)),
          next_before: messages.length === limit && oldest ? iso(oldest.at) : null,
        };
      },
    }),
    tool({
      name: "search",
      description: "Messages containing every word of the query (accents and case ignored; a word also matches longer words it starts), the newest first, across chats or in one.",
      input: z.object({
        query: z.string().min(1).max(256),
        chat_id: chatId.optional(),
        limit: z.number().int().min(1).max(100).optional().describe("At most this many; 30 when left out."),
      }).strict(),
      idempotent: true,
      run: async (device, input) => {
        const found = device.store.search(input.query, { limit: input.limit ?? 30, chatId: input.chat_id ? chatJid(input.chat_id) : undefined });
        return found.map((message) => shown(message, { chat: true }));
      },
    }),
  ],
};

export { WhatsAppDevice, LINK_LIFETIME_MS, WATCH_INTERVAL_MS, type DeviceDeps } from "./device";
