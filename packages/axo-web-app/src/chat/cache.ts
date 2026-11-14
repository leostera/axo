import { clientHelloResultSchema, clientRecordSchema, type ClientHello } from "@axo/protocol";
import type { TranscriptRecord } from "./transcript.ts";

/** Display-only snapshots, never command queues, approvals, credentials or resume cursors. */
export interface CachedChat {
  hostId: string;
  sessionId: string;
  records: TranscriptRecord[];
}
export interface ChatSnapshot {
  listing: ClientHello;
  selected: { hostId: string; sessionId: string | null } | null;
  chats: CachedChat[];
  drafts: [string, string][];
}
type CacheStorage = Pick<Storage, "getItem" | "setItem" | "removeItem">;
const MAX_BYTES = 2 * 1024 * 1024;
const MAX_CHAT_BYTES = 192 * 1024;
const MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;
const recordSchema = clientRecordSchema.omit({ hash: true });
const bytes = (text: string) => new TextEncoder().encode(text).length;
function object(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function draftKeys(listing: ClientHello): Set<string> {
  return new Set([
    ...listing.hosts.map(host => `${host.hostId}/new`),
    ...listing.sessions.map(session => `${session.hostId}/chat/${session.sessionId}`),
  ]);
}

/** Storage is optional: private mode, corrupt data and quota exhaustion never break chats. */
export class ChatCache {
  private readonly key: string;
  private readonly storage: CacheStorage | null;
  constructor(accountId: string, storage?: CacheStorage | null) {
    this.key = `axo.chats.v1.${accountId}`;
    try { this.storage = storage === undefined ? globalThis.localStorage ?? null : storage; }
    catch { this.storage = null; }
  }
  read(): ChatSnapshot | null {
    try {
      const text = this.storage?.getItem(this.key);
      if (!text || bytes(text) > MAX_BYTES) return null;
      const value = object(JSON.parse(text));
      if (!value || value.version !== 1 || typeof value.savedAt !== "number"
        || value.savedAt > Date.now() + 60_000 || Date.now() - value.savedAt > MAX_AGE_MS) return null;
      const rawListing = object(value.listing);
      if (!rawListing || !Array.isArray(rawListing.hosts) || rawListing.hosts.length > 64
        || !Array.isArray(rawListing.sessions) || rawListing.sessions.length > 1000) return null;
      const listing = clientHelloResultSchema.parse(rawListing);
      const hosts = new Set(listing.hosts.map(host => host.hostId));
      if (listing.sessions.some(session => !hosts.has(session.hostId))) return null;
      const sessionOf = (hostId: unknown, sessionId: unknown) => listing.sessions.find(session => session.hostId === hostId && session.sessionId === sessionId);
      if (!Array.isArray(value.chats) || value.chats.length > 10 || !Array.isArray(value.drafts) || value.drafts.length > 32) return null;
      const chats: CachedChat[] = [];
      for (const raw of value.chats) {
        const chat = object(raw);
        if (!chat || !Array.isArray(chat.records) || chat.records.length > 128) return null;
        const session = sessionOf(chat.hostId, chat.sessionId);
        if (!session) return null;
        const records = chat.records.map(record => recordSchema.parse(record));
        if (records.some((record, index) => index > 0 && record.cursor <= records[index - 1]!.cursor)) return null;
        chats.push({ hostId: session.hostId, sessionId: session.sessionId, records });
      }
      let selected: ChatSnapshot["selected"] = null;
      if (value.selected !== null) {
        const selection = object(value.selected);
        if (!selection || typeof selection.hostId !== "string" || !hosts.has(selection.hostId)
          || (selection.sessionId !== null && !sessionOf(selection.hostId, selection.sessionId))) return null;
        const session = sessionOf(selection.hostId, selection.sessionId);
        selected = { hostId: selection.hostId, sessionId: session?.sessionId ?? null };
      }
      const keys = draftKeys(listing);
      const drafts: [string, string][] = [];
      for (const pair of value.drafts) {
        if (!Array.isArray(pair) || pair.length !== 2 || typeof pair[0] !== "string" || !keys.has(pair[0])
          || typeof pair[1] !== "string" || bytes(pair[1]) > 16000) return null;
        drafts.push([pair[0], pair[1]]);
      }
      // Cached presence/status must never imply a live or actionable Mac.
      return { listing: { hosts: listing.hosts.map(host => ({ ...host, online: false })), sessions: listing.sessions.map(session => ({ ...session, status: null })) }, selected, chats, drafts };
    } catch { return null; }
  }
  write(snapshot: ChatSnapshot): void {
    if (!this.storage) return;
    try {
      const selectedId = snapshot.selected?.sessionId;
      const listing = {
        hosts: [...snapshot.listing.hosts].sort((a, b) => Number(b.hostId === snapshot.selected?.hostId) - Number(a.hostId === snapshot.selected?.hostId)).slice(0, 64),
        sessions: [...snapshot.listing.sessions].sort((a, b) => {
          const selected = Number(b.sessionId === selectedId) - Number(a.sessionId === selectedId);
          return selected || (b.metadata.lastMessageAt ?? b.metadata.createdAt ?? 0) - (a.metadata.lastMessageAt ?? a.metadata.createdAt ?? 0);
        }).slice(0, 1000),
      };
      const hosts = new Set(listing.hosts.map(host => host.hostId));
      listing.sessions = listing.sessions.filter(session => hosts.has(session.hostId));
      const owns = (hostId: string, sessionId: string) => listing.sessions.some(session => session.hostId === hostId && session.sessionId === sessionId);
      const chats = snapshot.chats.filter(chat => owns(chat.hostId, chat.sessionId)).slice(-10).map(chat => {
        const records: TranscriptRecord[] = [];
        let size = 0;
        for (const record of chat.records.slice(-128).reverse()) {
          const kept = { cursor: record.cursor, id: record.id, format: record.format, line: record.line };
          const length = bytes(JSON.stringify(kept));
          if (size + length > MAX_CHAT_BYTES) break;
          size += length;
          records.unshift(kept);
        }
        return { hostId: chat.hostId, sessionId: chat.sessionId, records };
      });
      const selected = snapshot.selected && hosts.has(snapshot.selected.hostId)
        && (snapshot.selected.sessionId === null || owns(snapshot.selected.hostId, snapshot.selected.sessionId)) ? snapshot.selected : null;
      const keys = draftKeys(listing);
      const drafts = snapshot.drafts.filter(([key, text]) => keys.has(key) && text.length > 0 && bytes(text) <= 16000).slice(-32);
      while (true) {
        const text = JSON.stringify({ version: 1, savedAt: Date.now(), listing, selected, chats, drafts });
        if (bytes(text) <= MAX_BYTES) {
          try { this.storage.setItem(this.key, text); return; }
          catch { /* Evict older conversations before giving up on limited storage. */ }
        }
        if (!chats.length) return;
        chats.shift();
      }
    } catch { /* A display cache is never required to use the app. */ }
  }
  watchClear(onClear: () => void): () => void {
    if (typeof window === "undefined") return () => {};
    const changed = (event: StorageEvent) => {
      if (event.storageArea === this.storage && (event.key === this.key || event.key === null) && event.newValue === null) onClear();
    };
    window.addEventListener("storage", changed);
    return () => window.removeEventListener("storage", changed);
  }
  clear(): void {
    try { this.storage?.removeItem(this.key); } catch { /* unavailable storage */ }
  }
}
