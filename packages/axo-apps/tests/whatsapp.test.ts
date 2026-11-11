import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import { proto, type WAMessage } from "baileys";
import { accountOf, messageChange, textOf } from "../src/apps/whatsapp/messages";
import { WhatsAppStore, type Sql, type SqlValue } from "../src/apps/whatsapp/store";
import { chatJid, whatsapp } from "../src/apps/whatsapp";
import type { WhatsAppDevice } from "../src/apps/whatsapp/device";
import { derivePairingCodeKey } from "../src/apps/whatsapp/workers/pairing-key";
import { withPairingKey } from "../bundling.mjs";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

/** A Durable Object's SqlStorage, over node:sqlite, for the store's own SQL. */
function sqlStorage(): Sql {
  const db = new DatabaseSync(":memory:");
  return {
    exec<T>(query: string, ...bindings: SqlValue[]) {
      const statement = db.prepare(query);
      if (/^\s*(SELECT|WITH)/i.test(query)) {
        const rows = statement.all(...(bindings as never[])) as T[];
        return { toArray: () => rows, rowsWritten: 0 };
      }
      const result = statement.run(...(bindings as never[]));
      return { toArray: () => [] as T[], rowsWritten: Number(result.changes) };
    },
  } as Sql;
}

const ME = "447700900001@s.whatsapp.net";
const ANA = "447700900123@s.whatsapp.net";
const ANA_LID = "123456789012345@lid";

function message(fields: { chat?: string; id: string; text?: string; fromMe?: boolean; at?: number; participant?: string; push?: string; content?: proto.IMessage; alt?: string }): WAMessage {
  return {
    key: { remoteJid: fields.chat ?? ANA, id: fields.id, fromMe: fields.fromMe ?? false, participant: fields.participant, remoteJidAlt: fields.alt },
    message: fields.content ?? { conversation: fields.text ?? "" },
    messageTimestamp: fields.at ?? 1_790_000_000,
    pushName: fields.push,
  } as WAMessage;
}

test("a message is kept as words, with its sender, time and the message it answers", () => {
  const change = messageChange(message({
    chat: "120363000000000000@g.us", id: "A1", participant: ANA, push: "Ana",
    content: { extendedTextMessage: { text: "see you at 8", contextInfo: { stanzaId: "Q0" } } },
  }));
  assert.deepEqual(change, {
    kind: "message",
    row: { chatId: "120363000000000000@g.us", id: "A1", fromMe: false, sender: ANA, pushName: "Ana", at: 1_790_000_000, type: "extendedText", text: "see you at 8", quotedId: "Q0", deleted: false },
  });
});

test("media are named by kind, with their caption; what is not a message is skipped", () => {
  assert.equal(textOf({ imageMessage: { caption: "the view" } }), "[photo] the view");
  assert.equal(textOf({ audioMessage: { ptt: true } }), "[voice message]");
  assert.equal(textOf({ documentMessage: { fileName: "lease.pdf" } }), "[document] lease.pdf");
  assert.equal(textOf({ pollCreationMessage: { name: "Dinner?", options: [{ optionName: "Fri" }, { optionName: "Sat" }] } }), "[poll] Dinner?\n- Fri\n- Sat");
  assert.equal(messageChange(message({ id: "R", content: { reactionMessage: { text: "👍", key: { id: "A1" } } } })), null);
  assert.equal(messageChange(message({ chat: "status@broadcast", id: "S", text: "my status" })), null);
});

test("an edit and a delete for everyone change the message they name", () => {
  const edit = messageChange(message({
    id: "E", content: { protocolMessage: { type: proto.Message.ProtocolMessage.Type.MESSAGE_EDIT, key: { id: "A1" }, editedMessage: { conversation: "see you at 9" } } },
  }));
  assert.deepEqual(edit, { kind: "edit", chatId: ANA, id: "A1", text: "see you at 9" });
  const revoke = messageChange(message({ id: "D", content: { protocolMessage: { type: proto.Message.ProtocolMessage.Type.REVOKE, key: { id: "A1" } } } }));
  assert.deepEqual(revoke, { kind: "delete", chatId: ANA, id: "A1" });
});

test("a person named by their LID lands in the chat of their number", () => {
  const store = new WhatsAppStore(sqlStorage());
  const keep = (m: WAMessage) => {
    const change = messageChange(m, (jid) => store.canonical(jid));
    if (change?.kind === "message") store.upsertMessage(change.row);
  };
  keep(message({ chat: ANA_LID, id: "L1", text: "before the mapping", at: 1 }));
  keep(message({ chat: ANA_LID, id: "L2", text: "with the number beside it", alt: ANA, at: 2 }));
  store.mapLid(ANA_LID, ANA);
  keep(message({ chat: ANA_LID, id: "L3", text: "after the mapping", at: 3 }));
  assert.deepEqual(store.messages(ANA, { limit: 10 }).map((m) => m.id), ["L3", "L2", "L1"]);
  assert.deepEqual(store.chats({ limit: 10 }).map((c) => c.id), [ANA]);
});

test("search matches every word, ignoring accents and case, and a word's start", () => {
  const store = new WhatsAppStore(sqlStorage());
  store.upsertMessage({ chatId: ANA, id: "1", fromMe: false, sender: ANA, pushName: "Ana", at: 10, type: "conversation", text: "Café mañana at the Plaza?", quotedId: null, deleted: false });
  store.upsertMessage({ chatId: ANA, id: "2", fromMe: true, sender: null, pushName: null, at: 20, type: "conversation", text: "plaza works", quotedId: null, deleted: false });
  store.upsertMessage({ chatId: ANA, id: "3", fromMe: false, sender: ANA, pushName: "Ana", at: 30, type: "conversation", text: "unrelated", quotedId: null, deleted: false });
  assert.deepEqual(store.search("cafe MANANA", { limit: 10 }).map((m) => m.id), ["1"]);
  assert.deepEqual(store.search("plaz", { limit: 10 }).map((m) => m.id), ["2", "1"]);
  assert.deepEqual(store.search('"OR" NEAR(', { limit: 10 }), [], "what a person types is never FTS syntax");
  store.editMessage(ANA, "2", { deleted: true });
  assert.deepEqual(store.search("plaza", { limit: 10 }).map((m) => m.id), ["1"], "a message deleted for everyone is not found");
});

test("the tools read the cache: chats by name, a chat's messages oldest first with paging, search across chats", async () => {
  const store = new WhatsAppStore(sqlStorage());
  store.upsertContact({ id: ANA, name: "Ana García" });
  store.upsertChat({ id: ANA, unread: 2 });
  for (let i = 1; i <= 5; i++) {
    store.upsertMessage({ chatId: ANA, id: `m${i}`, fromMe: i % 2 === 0, sender: i % 2 === 0 ? null : ANA, pushName: "Ana", at: 1_790_000_000 + i, type: "conversation", text: `message ${i}`, quotedId: null, deleted: false });
  }
  store.setSetting("account", "+447700900001");
  const device = { store, connected: () => true } as unknown as WhatsAppDevice;
  const run = (name: string, input: Record<string, unknown>) => whatsapp.tools.find((t) => t.name === name)!.run(device, whatsapp.tools.find((t) => t.name === name)!.input.parse(input));

  const chats = await run("list_chats", { query: "garc" }) as Array<{ id: string; name: string; unread: number; last: { from: string; text: string } }>;
  assert.deepEqual(chats.map((c) => [c.id, c.name, c.unread, c.last.text]), [[ANA, "Ana García", 2, "message 5"]]);

  const page = await run("read_messages", { chat_id: "+44 7700 900123", limit: 2 }) as { messages: Array<{ id: string; from: string }>; next_before: string };
  assert.deepEqual(page.messages.map((m) => [m.id, m.from]), [["m4", "me"], ["m5", "Ana García"]]);
  const older = await run("read_messages", { chat_id: ANA, limit: 2, before: page.next_before }) as { messages: Array<{ id: string }> };
  assert.deepEqual(older.messages.map((m) => m.id), ["m2", "m3"]);

  const found = await run("search", { query: "message 3" }) as Array<{ id: string; chat: string }>;
  assert.deepEqual(found.map((m) => [m.id, m.chat]), [["m3", "Ana García"]]);
  await assert.rejects(Promise.resolve().then(() => run("read_messages", { chat_id: "447700900999@s.whatsapp.net" })), /no chat/);
});

test("accounts are named by their number, and chats by an id or a number", () => {
  assert.equal(accountOf("447700900001:12@s.whatsapp.net"), "+447700900001");
  assert.equal(chatJid("+44 7700 900123"), ANA);
  assert.equal(chatJid("120363000000000000@g.us"), "120363000000000000@g.us");
  assert.throws(() => chatJid("ana"), /not a chat id/);
  assert.equal(whatsapp.tools.every((t) => t.idempotent), true, "every tool only reads");
  void ME;
});

test("a pairing code's key is the one Baileys derives, and the bundle derives it without Web Crypto", async () => {
  const salt = new Uint8Array(32).map((_, i) => i * 7);
  const material = await crypto.subtle.importKey("raw", new TextEncoder().encode("3GLLQ66A"), "PBKDF2", false, ["deriveBits"]);
  const expected = Buffer.from(await crypto.subtle.deriveBits({ name: "PBKDF2", salt, iterations: 2 << 16, hash: "SHA-256" }, material, 256));
  assert.deepEqual(await derivePairingCodeKey("3GLLQ66A", salt), expected);

  let directory = dirname(fileURLToPath(import.meta.resolve("baileys")));
  while (!directory.endsWith("/baileys")) directory = dirname(directory);
  const path = join(directory, "lib", "Utils", "crypto.js");
  const swapped = withPairingKey(await readFile(path, "utf8"), path);
  assert.match(swapped, /^export \{ derivePairingCodeKey \} from ".*pairing-key\.ts";/);
  assert.doesNotMatch(swapped, /export async function derivePairingCodeKey/);
});
