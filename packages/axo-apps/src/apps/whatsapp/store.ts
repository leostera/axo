/**
 * What a linked WhatsApp device keeps, in its Durable Object's SQLite: its keys (sealed by the
 * caller), a few settings, and the chats, contacts and messages WhatsApp sent it, with a full-text
 * index for search. It is a cache of what this device saw, not a backup: WhatsApp's history sync
 * gives a linked device only part of an account's history.
 */

/** The part of a Durable Object's `SqlStorage` the store uses. */
export type Sql = {
  exec<T extends Record<string, SqlValue> = Record<string, SqlValue>>(query: string, ...bindings: SqlValue[]): { toArray(): T[]; readonly rowsWritten: number };
};
export type SqlValue = string | number | null | ArrayBuffer;

export type ChatRow = { id: string; name: string | null; isGroup: boolean; unread: number; archived: boolean; lastAt: number | null };
export type MessageRow = {
  chatId: string;
  id: string;
  fromMe: boolean;
  /** Who sent it: a phone number's JID, or a LID's when WhatsApp gave no number. Null for one of the person's own. */
  sender: string | null;
  /** The name the sender set on WhatsApp, as this message carried it. */
  pushName: string | null;
  /** Seconds since the epoch, as WhatsApp stamps messages. */
  at: number;
  type: string;
  text: string;
  quotedId: string | null;
  deleted: boolean;
};
/** A message, with its sender's and chat's names as the person would see them. */
export type ShownMessage = MessageRow & { senderName: string | null; chatName: string | null };

const SCHEMA = [
  "CREATE TABLE IF NOT EXISTS wa_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
  "CREATE TABLE IF NOT EXISTS wa_auth (kind TEXT NOT NULL, id TEXT NOT NULL, sealed TEXT NOT NULL, PRIMARY KEY (kind, id))",
  `CREATE TABLE IF NOT EXISTS wa_chats (id TEXT PRIMARY KEY, name TEXT, is_group INTEGER NOT NULL DEFAULT 0,
    unread INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0, last_at INTEGER)`,
  "CREATE TABLE IF NOT EXISTS wa_contacts (id TEXT PRIMARY KEY, name TEXT, notify TEXT)",
  // A LID (WhatsApp's number-hiding ID) and the phone number JID it stands for, as WhatsApp said.
  "CREATE TABLE IF NOT EXISTS wa_lids (lid TEXT PRIMARY KEY, pn TEXT NOT NULL)",
  `CREATE TABLE IF NOT EXISTS wa_messages (chat_id TEXT NOT NULL, id TEXT NOT NULL, from_me INTEGER NOT NULL, sender TEXT,
    push_name TEXT, at INTEGER NOT NULL, type TEXT NOT NULL, text TEXT NOT NULL, quoted_id TEXT, deleted INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (chat_id, id))`,
  "CREATE INDEX IF NOT EXISTS wa_messages_by_time ON wa_messages (chat_id, at DESC)",
  `CREATE VIRTUAL TABLE IF NOT EXISTS wa_messages_fts USING fts5(text, content='wa_messages', content_rowid='rowid',
    tokenize='unicode61 remove_diacritics 2')`,
  `CREATE TRIGGER IF NOT EXISTS wa_messages_ai AFTER INSERT ON wa_messages BEGIN
    INSERT INTO wa_messages_fts (rowid, text) VALUES (new.rowid, new.text); END`,
  `CREATE TRIGGER IF NOT EXISTS wa_messages_ad AFTER DELETE ON wa_messages BEGIN
    INSERT INTO wa_messages_fts (wa_messages_fts, rowid, text) VALUES ('delete', old.rowid, old.text); END`,
  `CREATE TRIGGER IF NOT EXISTS wa_messages_au AFTER UPDATE OF text ON wa_messages BEGIN
    INSERT INTO wa_messages_fts (wa_messages_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
    INSERT INTO wa_messages_fts (rowid, text) VALUES (new.rowid, new.text); END`,
];

export class WhatsAppStore {
  constructor(private readonly sql: Sql) {
    for (const statement of SCHEMA) sql.exec(statement);
  }

  // Settings

  setting(key: string): string | null {
    return this.sql.exec<{ value: string }>("SELECT value FROM wa_settings WHERE key = ?", key).toArray()[0]?.value ?? null;
  }

  setSetting(key: string, value: string | null): void {
    if (value === null) this.sql.exec("DELETE FROM wa_settings WHERE key = ?", key);
    else this.sql.exec("INSERT INTO wa_settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", key, value);
  }

  // The device's keys, sealed by the caller

  readAuth(kind: string, id: string): string | null {
    return this.sql.exec<{ sealed: string }>("SELECT sealed FROM wa_auth WHERE kind = ? AND id = ?", kind, id).toArray()[0]?.sealed ?? null;
  }

  writeAuth(kind: string, id: string, sealed: string | null): void {
    if (sealed === null) this.sql.exec("DELETE FROM wa_auth WHERE kind = ? AND id = ?", kind, id);
    else this.sql.exec("INSERT INTO wa_auth (kind, id, sealed) VALUES (?, ?, ?) ON CONFLICT (kind, id) DO UPDATE SET sealed = excluded.sealed", kind, id, sealed);
  }

  /** Forgets the device: its keys, settings and everything it cached. */
  forget(): void {
    for (const table of ["wa_auth", "wa_settings", "wa_messages", "wa_chats", "wa_contacts", "wa_lids"]) this.sql.exec(`DELETE FROM ${table}`);
  }

  // Who is who

  /** A LID's phone number JID, when WhatsApp said; otherwise the JID itself. */
  canonical(jid: string): string {
    if (!jid.endsWith("@lid")) return jid;
    return this.sql.exec<{ pn: string }>("SELECT pn FROM wa_lids WHERE lid = ?", jid).toArray()[0]?.pn ?? jid;
  }

  mapLid(lid: string, pn: string): void {
    if (!lid.endsWith("@lid") || !pn.endsWith("@s.whatsapp.net")) return;
    this.sql.exec("INSERT INTO wa_lids (lid, pn) VALUES (?, ?) ON CONFLICT (lid) DO UPDATE SET pn = excluded.pn", lid, pn);
    // What was kept under the LID moves to the number, so one person is one chat.
    this.sql.exec("UPDATE OR IGNORE wa_messages SET chat_id = ? WHERE chat_id = ?", pn, lid);
    this.sql.exec("UPDATE wa_messages SET sender = ? WHERE sender = ?", pn, lid);
    const chat = this.sql.exec<RawChat>("SELECT * FROM wa_chats WHERE id = ?", lid).toArray()[0];
    if (chat) {
      this.upsertChat({ id: pn, name: chat.name, unread: chat.unread, archived: chat.archived === 1, lastAt: chat.last_at });
      this.sql.exec("DELETE FROM wa_chats WHERE id = ?", lid);
    }
  }

  /** Merges what WhatsApp said about a chat; what it left out keeps its value. */
  upsertChat(chat: { id: string; name?: string | null; unread?: number | null; archived?: boolean | null; lastAt?: number | null }): void {
    const archived = chat.archived === undefined || chat.archived === null ? null : chat.archived ? 1 : 0;
    this.sql.exec(`INSERT INTO wa_chats (id, name, is_group, unread, archived, last_at) VALUES (?, ?, ?, coalesce(?, 0), coalesce(?, 0), ?)
      ON CONFLICT (id) DO UPDATE SET name = coalesce(excluded.name, wa_chats.name), unread = coalesce(?, wa_chats.unread),
        archived = coalesce(?, wa_chats.archived), last_at = max(coalesce(excluded.last_at, 0), coalesce(wa_chats.last_at, 0))`,
    chat.id, chat.name ?? null, chat.id.endsWith("@g.us") ? 1 : 0, chat.unread ?? null, archived, chat.lastAt ?? null, chat.unread ?? null, archived);
  }

  deleteChat(id: string): void {
    this.sql.exec("DELETE FROM wa_messages WHERE chat_id = ?", id);
    this.sql.exec("DELETE FROM wa_chats WHERE id = ?", id);
  }

  upsertContact(contact: { id: string; name?: string | null; notify?: string | null }): void {
    if (!contact.name && !contact.notify) return;
    this.sql.exec(`INSERT INTO wa_contacts (id, name, notify) VALUES (?, ?, ?)
      ON CONFLICT (id) DO UPDATE SET name = coalesce(excluded.name, wa_contacts.name), notify = coalesce(excluded.notify, wa_contacts.notify)`,
    contact.id, contact.name ?? null, contact.notify ?? null);
  }

  /** Keeps a message, or updates the one with its ID; its chat moves up. */
  upsertMessage(message: MessageRow): void {
    this.sql.exec(`INSERT INTO wa_messages (chat_id, id, from_me, sender, push_name, at, type, text, quoted_id, deleted) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (chat_id, id) DO UPDATE SET text = excluded.text, type = excluded.type, deleted = excluded.deleted,
        push_name = coalesce(excluded.push_name, wa_messages.push_name)`,
    message.chatId, message.id, message.fromMe ? 1 : 0, message.sender, message.pushName, message.at, message.type, message.text,
    message.quotedId, message.deleted ? 1 : 0);
    this.upsertChat({ id: message.chatId, lastAt: message.at });
    if (message.pushName && message.sender && !message.fromMe) this.upsertContact({ id: message.sender, notify: message.pushName });
  }

  /** A message edited, or deleted for everyone: only its text changes. */
  editMessage(chatId: string, id: string, change: { text: string } | { deleted: true }): void {
    if ("deleted" in change) this.sql.exec("UPDATE wa_messages SET deleted = 1, text = '' WHERE chat_id = ? AND id = ?", chatId, id);
    else this.sql.exec("UPDATE wa_messages SET text = ? WHERE chat_id = ? AND id = ?", change.text, chatId, id);
  }

  // Reading

  /** Chats, the most recent first, named by the group's subject or the contact's name; `query` matches names. */
  chats(options: { limit: number; unreadOnly?: boolean; archived?: boolean; query?: string }): Array<ChatRow & { last: ShownMessage | null }> {
    const like = options.query ? `%${options.query.replace(/[\\%_]/g, (c) => `\\${c}`)}%` : null;
    const rows = this.sql.exec<RawChat & { shown: string | null }>(`SELECT c.*, coalesce(c.name, k.name, k.notify) AS shown
      FROM wa_chats c LEFT JOIN wa_contacts k ON k.id = c.id
      WHERE (? = 0 OR c.unread > 0) AND (? IS NULL OR c.archived = ?)
        AND (? IS NULL OR coalesce(c.name, k.name, k.notify, '') LIKE ? ESCAPE '\\' OR c.id LIKE ? ESCAPE '\\')
      ORDER BY coalesce(c.last_at, 0) DESC LIMIT ?`,
    options.unreadOnly ? 1 : 0, options.archived === undefined ? null : 1, options.archived ? 1 : 0, like, like, like, options.limit).toArray();
    return rows.map((row) => {
      const last = this.sql.exec<RawMessage>("SELECT * FROM wa_messages WHERE chat_id = ? ORDER BY at DESC LIMIT 1", row.id).toArray()[0];
      return { ...chatOf(row), name: row.shown, last: last ? this.shown(last) : null };
    });
  }

  chat(id: string): ChatRow | null {
    const row = this.sql.exec<RawChat & { shown: string | null }>(`SELECT c.*, coalesce(c.name, k.name, k.notify) AS shown
      FROM wa_chats c LEFT JOIN wa_contacts k ON k.id = c.id WHERE c.id = ?`, this.canonical(id)).toArray()[0];
    return row ? { ...chatOf(row), name: row.shown } : null;
  }

  /** A chat's messages, the newest first; `before` pages back from a time, in seconds. */
  messages(chatId: string, options: { limit: number; before?: number }): ShownMessage[] {
    return this.sql.exec<RawMessage>("SELECT * FROM wa_messages WHERE chat_id = ? AND at < ? ORDER BY at DESC, rowid DESC LIMIT ?",
      this.canonical(chatId), options.before ?? Number.MAX_SAFE_INTEGER, options.limit).toArray().map((row) => this.shown(row));
  }

  /** Messages matching every word of `query` (each also as a prefix), accents ignored, the newest first. */
  search(query: string, options: { limit: number; chatId?: string }): ShownMessage[] {
    const match = ftsQuery(query);
    if (!match) return [];
    const chat = options.chatId ? this.canonical(options.chatId) : null;
    return this.sql.exec<RawMessage>(`SELECT m.* FROM wa_messages_fts f JOIN wa_messages m ON m.rowid = f.rowid
      WHERE wa_messages_fts MATCH ? AND (? IS NULL OR m.chat_id = ?) AND m.deleted = 0 ORDER BY m.at DESC LIMIT ?`,
    match, chat, chat, options.limit).toArray().map((row) => this.shown(row));
  }

  counts(): { chats: number; messages: number; oldest: number | null } {
    const chats = this.sql.exec<{ n: number }>("SELECT count(*) AS n FROM wa_chats").toArray()[0]!.n;
    const messages = this.sql.exec<{ n: number; oldest: number | null }>("SELECT count(*) AS n, min(at) AS oldest FROM wa_messages").toArray()[0]!;
    return { chats, messages: messages.n, oldest: messages.oldest };
  }

  private shown(row: RawMessage): ShownMessage {
    const names = this.sql.exec<{ sender: string | null; chat: string | null }>(`SELECT
        (SELECT coalesce(name, notify) FROM wa_contacts WHERE id = ?) AS sender,
        (SELECT coalesce(c.name, k.name, k.notify) FROM wa_chats c LEFT JOIN wa_contacts k ON k.id = c.id WHERE c.id = ?) AS chat`,
    row.sender, row.chat_id).toArray()[0];
    return { ...messageOf(row), senderName: row.from_me ? null : names?.sender ?? row.push_name, chatName: names?.chat ?? null };
  }
}

/** Each word as a quoted FTS5 prefix term, so what a person typed never reads as FTS syntax. */
export function ftsQuery(query: string): string {
  return query.split(/\s+/).map((word) => word.replace(/"/g, "")).filter(Boolean).map((word) => `"${word}"*`).join(" ");
}

type RawChat = { id: string; name: string | null; is_group: number; unread: number; archived: number; last_at: number | null };
type RawMessage = {
  chat_id: string; id: string; from_me: number; sender: string | null; push_name: string | null; at: number; type: string; text: string;
  quoted_id: string | null; deleted: number;
};

function chatOf(row: RawChat): ChatRow {
  return { id: row.id, name: row.name, isGroup: row.is_group === 1, unread: row.unread, archived: row.archived === 1, lastAt: row.last_at };
}

function messageOf(row: RawMessage): MessageRow {
  return {
    chatId: row.chat_id, id: row.id, fromMe: row.from_me === 1, sender: row.sender, pushName: row.push_name, at: row.at,
    type: row.type, text: row.text, quotedId: row.quoted_id, deleted: row.deleted === 1,
  };
}
