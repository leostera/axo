import {
  Browsers,
  BufferJSON,
  DisconnectReason,
  initAuthCreds,
  makeCacheableSignalKeyStore,
  makeWASocket,
  proto,
  type AuthenticationCreds,
  type BaileysEventMap,
  type SignalDataSet,
  type SignalDataTypeMap,
  type SignalKeyStore,
  type WASocket,
} from "baileys";
import type { LinkedOutcome, LinkStart, LinkState } from "../../app";
import { accountOf, ignoredChat, messageChange, preferNumber, seconds, type MessageChange } from "./messages";
import { WhatsAppStore, type Sql } from "./store";

/**
 * One linked WhatsApp device, as its Durable Object runs it (RFD0016, Linked devices): Baileys'
 * socket to WhatsApp, speaking the protocol WhatsApp Web does, so no phone or Mac
 * of the person's has to stay on. Linking makes new keys and shows a QR code or a pairing code;
 * once the phone approves, the device stays linked until the person removes it (here, or on
 * their phone), and reconnects whenever its object starts again. Everything WhatsApp sends it
 * (history sync, new messages, edits) goes into its cache, which its tools read.
 */

export type DeviceDeps = {
  sql: Sql;
  /** Seals the device's keys at rest, since they would let anyone read and send as the person. */
  seal(plain: string): Promise<string>;
  unseal(sealed: string): Promise<string | null>;
  /** Runs `work` as one SQLite transaction (a Durable Object's `transactionSync`). */
  transaction(work: () => void): void;
  /** Wakes the object at `at`, to reconnect if its socket went with it. */
  setAlarm(at: number): Promise<void> | void;
  deleteAlarm(): Promise<void> | void;
  now?: () => number;
  /** Stands in for Baileys' socket, in tests. */
  makeSocket?: typeof makeWASocket;
};

/** Linking a new device must finish within this; WhatsApp's QR codes run out in about two minutes anyway. */
export const LINK_LIFETIME_MS = 5 * 60_000;
/** How often a linked device's object wakes to check it is connected. */
export const WATCH_INTERVAL_MS = 60_000;
/** The most a reconnect waits after the connection dropped. */
const MAX_BACKOFF_MS = 30_000;

type Status = "new" | "linking" | "linked" | "unlinked";
type Link = { start: LinkStart; state: LinkState; startedAt: number; codeAsked: boolean };

export class WhatsAppDevice {
  readonly store: WhatsAppStore;
  private socket: WASocket | null = null;
  private open = false;
  private starting: Promise<void> | null = null;
  private link: Link | null = null;
  private creds: AuthenticationCreds | null = null;
  private retries = 0;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  /** Writes of the device's keys, one after another, as Baileys makes them. */
  private writes: Promise<unknown> = Promise.resolve();

  constructor(private readonly deps: DeviceDeps) {
    this.store = new WhatsAppStore(deps.sql);
  }

  private now(): number {
    return this.deps.now?.() ?? Date.now();
  }

  status(): Status {
    return (this.store.setting("status") as Status | null) ?? "new";
  }

  /** Whether the socket is connected and signed in right now. */
  connected(): boolean {
    return this.open;
  }

  // Linking

  /** Starts linking with fresh keys, and answers once there is a code to show (or in ten seconds). */
  async startLink(start: LinkStart): Promise<LinkState> {
    if (this.status() === "linked") return { state: "failed", error: "This device is already linked." };
    this.close();
    this.store.forget();
    this.creds = null;
    this.store.setSetting("status", "linking");
    this.link = { start, state: { state: "connecting" }, startedAt: this.now(), codeAsked: false };
    await this.deps.setAlarm(this.now() + WATCH_INTERVAL_MS);
    await this.connect();
    for (let waited = 0; waited < 10_000 && this.link?.state.state === "connecting"; waited += 250) await sleep(250);
    return this.linkState();
  }

  linkState(): LinkState {
    const status = this.status();
    if (status === "linked") return { state: "done", account: this.store.setting("account")! };
    if (!this.link) return { state: "failed", error: status === "unlinked" ? "WhatsApp unlinked this device." : "This link has ended. Start again." };
    if (this.now() - this.link.startedAt > LINK_LIFETIME_MS) this.failLink("The code expired. Start again.");
    return this.link.state;
  }

  private failLink(error: string): void {
    if (!this.link) return;
    this.link.state = { state: "failed", error };
    this.close();
    this.store.forget();
    // The failure stays to be read; a later start begins again.
    this.store.setSetting("status", "new");
  }

  /** Logs the device out at WhatsApp, so it leaves the phone's Linked devices, and forgets everything. */
  async unlink(): Promise<void> {
    const wasLinked = this.status() === "linked";
    this.link = null;
    try {
      if (wasLinked) {
        await this.connect();
        for (let waited = 0; waited < 10_000 && !this.open; waited += 250) await sleep(250);
        if (this.open) await this.socket?.logout().catch(() => undefined);
      }
    } finally {
      this.close();
      this.store.forget();
      this.store.setSetting("status", "unlinked");
      await this.deps.deleteAlarm();
    }
  }

  // Staying connected

  /** The object woke: a linked device connects again if its socket went; a link that ran out ends. */
  async alarm(): Promise<void> {
    const status = this.status();
    if (status === "linked") {
      await this.deps.setAlarm(this.now() + WATCH_INTERVAL_MS);
      await this.connect();
      return;
    }
    if (status === "linking" && this.link && this.now() - this.link.startedAt <= LINK_LIFETIME_MS) {
      await this.deps.setAlarm(this.now() + WATCH_INTERVAL_MS);
      return;
    }
    // A link the object forgot (it restarted) or that ran out is over.
    if (status === "linking") {
      this.failLink("The code expired. Start again.");
      this.link = null;
    }
  }

  /** Connects, unless already connected or connecting. */
  async connect(): Promise<void> {
    if (this.socket) return;
    if (this.starting) return this.starting;
    this.starting = this.startSocket().finally(() => {
      this.starting = null;
    });
    return this.starting;
  }

  private async startSocket(): Promise<void> {
    const creds = this.creds ??= await this.loadCreds();
    const socket = (this.deps.makeSocket ?? makeWASocket)({
      auth: { creds, keys: makeCacheableSignalKeyStore(this.keyStore(), quiet) },
      logger: quiet,
      // As WhatsApp Web in Chrome. As its desktop app ("Desktop"), WhatsApp drops the connection when it registers.
      browser: Browsers.macOS("Chrome"),
      syncFullHistory: true,
      // Online, the phone would stop showing the person notifications.
      markOnlineOnConnect: false,
      shouldIgnoreJid: (jid) => ignoredChat(jid),
      // The cache keeps words, not WhatsApp's messages, so it cannot resend one a contact failed to decrypt.
      getMessage: async () => undefined,
      generateHighQualityLinkPreview: false,
    });
    this.socket = socket;
    socket.ev.process(async (events) => {
      if (this.socket !== socket) return;
      try {
        if (events["creds.update"]) this.saveCreds();
        if (events["connection.update"]) await this.connectionChanged(socket, events["connection.update"]);
        this.cache(events);
      } catch (error) {
        console.warn("whatsapp: event failed", error instanceof Error ? error.message : String(error));
      }
    });
  }

  private async connectionChanged(socket: WASocket, update: BaileysEventMap["connection.update"]): Promise<void> {
    const link = this.link;
    if (update.qr) {
      if (!link) {
        // A linked device asked to link again: WhatsApp no longer knows its keys.
        this.unlinked();
        return;
      }
      if (link.start.method === "qr") link.state = { state: "qr", qr: update.qr };
      else if (!link.codeAsked) {
        link.codeAsked = true;
        try {
          const code = await socket.requestPairingCode(link.start.phone.replace(/\D/g, ""));
          link.state = { state: "code", code: code.length === 8 ? `${code.slice(0, 4)}-${code.slice(4)}` : code };
        } catch (error) {
          console.warn("whatsapp: no pairing code", error instanceof Error ? error.stack ?? error.message : String(error));
          this.failLink("WhatsApp did not give a pairing code for that number. Check it, or link with the QR code.");
        }
      }
    }
    if (update.connection === "open") {
      this.open = true;
      this.retries = 0;
      const account = accountOf(socket.user!.id);
      this.store.setSetting("account", account);
      if (socket.user?.name) this.store.setSetting("name", socket.user.name);
      if (!this.store.setting("linked_at")) this.store.setSetting("linked_at", new Date(this.now()).toISOString());
      this.store.setSetting("status", "linked");
      this.link = null;
      // Groups are named by their subject, which history sync does not always carry.
      socket.groupFetchAllParticipating().then((groups) => {
        this.deps.transaction(() => {
          for (const group of Object.values(groups)) this.store.upsertChat({ id: group.id, name: group.subject });
        });
      }, () => undefined);
    }
    if (update.connection === "close") {
      this.open = false;
      if (this.socket === socket) this.socket = null;
      const code = (update.lastDisconnect?.error as { output?: { statusCode?: number } } | undefined)?.output?.statusCode;
      if (code === DisconnectReason.restartRequired) {
        // WhatsApp asks for this once the phone approved the link.
        void this.connect();
        return;
      }
      if (code === DisconnectReason.loggedOut) {
        if (this.link) this.failLink("WhatsApp refused the link. Start again.");
        else this.unlinked();
        return;
      }
      if (this.link) {
        this.failLink(code === DisconnectReason.timedOut ? "The code expired. Start again." : "WhatsApp closed the connection. Start again.");
        return;
      }
      if (this.status() === "linked") this.reconnectLater();
    }
  }

  private reconnectLater(): void {
    if (this.retryTimer) return;
    const delay = Math.min(MAX_BACKOFF_MS, 1000 * 2 ** this.retries++);
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      void this.connect();
    }, delay);
  }

  /** WhatsApp logged the device out (from the phone, or after a long time away): only linking again helps. */
  private unlinked(): void {
    this.close();
    this.store.forget();
    this.store.setSetting("status", "unlinked");
  }

  private close(): void {
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.retryTimer = null;
    const socket = this.socket;
    this.socket = null;
    this.open = false;
    if (socket) {
      try {
        socket.end(undefined);
      } catch {
        // Already closed.
      }
    }
  }

  // The cache

  private cache(events: Partial<BaileysEventMap>): void {
    const store = this.store;
    const history = events["messaging-history.set"];
    const upserts = events["messages.upsert"];
    if (!history && !upserts && !events["chats.upsert"] && !events["chats.update"] && !events["chats.delete"] && !events["contacts.upsert"]
      && !events["contacts.update"] && !events["lid-mapping.update"] && !events["groups.update"] && !events["messages.delete"]) return;
    this.deps.transaction(() => {
      for (const mapping of history?.lidPnMappings ?? []) store.mapLid(mapping.lid, mapping.pn);
      const mapping = events["lid-mapping.update"];
      if (mapping) store.mapLid(mapping.lid, mapping.pn);
      for (const contact of [...(history?.contacts ?? []), ...(events["contacts.upsert"] ?? []), ...(events["contacts.update"] ?? [])]) {
        if (!contact.id) continue;
        if (contact.lid && contact.phoneNumber) store.mapLid(contact.lid, contact.phoneNumber);
        const id = store.canonical(preferNumber(contact.id, contact.phoneNumber));
        store.upsertContact({ id, name: contact.name ?? null, notify: contact.notify ?? contact.verifiedName ?? null });
      }
      for (const chat of [...(history?.chats ?? []), ...(events["chats.upsert"] ?? []), ...(events["chats.update"] ?? [])]) {
        if (!chat.id || ignoredChat(chat.id)) continue;
        store.upsertChat({
          id: store.canonical(preferNumber(chat.id, (chat as { pnJid?: string | null }).pnJid)),
          name: chat.name ?? null,
          unread: chat.unreadCount ?? null,
          archived: chat.archived ?? null,
          lastAt: chat.conversationTimestamp ? seconds(chat.conversationTimestamp as number) : null,
        });
      }
      for (const id of events["chats.delete"] ?? []) store.deleteChat(store.canonical(id));
      for (const group of events["groups.update"] ?? []) if (group.id && group.subject) store.upsertChat({ id: group.id, name: group.subject });
      for (const message of [...(history?.messages ?? []), ...(upserts?.messages ?? [])]) {
        const change = messageChange(message, (jid) => store.canonical(jid));
        if (change) this.apply(change);
      }
      const deleted = events["messages.delete"];
      if (deleted && "keys" in deleted) {
        for (const key of deleted.keys) if (key.remoteJid && key.id) store.editMessage(store.canonical(key.remoteJid), key.id, { deleted: true });
      }
    });
  }

  private apply(change: MessageChange): void {
    if (change.kind === "message") this.store.upsertMessage(change.row);
    else if (change.kind === "edit") this.store.editMessage(change.chatId, change.id, { text: change.text });
    else this.store.editMessage(change.chatId, change.id, { deleted: true });
  }

  // The device's keys

  private async loadCreds(): Promise<AuthenticationCreds> {
    const sealed = this.store.readAuth("creds", "");
    const plain = sealed ? await this.deps.unseal(sealed) : null;
    return plain ? (JSON.parse(plain, BufferJSON.reviver) as AuthenticationCreds) : initAuthCreds();
  }

  /** Baileys changes the credentials in place and says so; they are written as they are then. */
  private saveCreds(): void {
    const creds = this.creds;
    if (!creds) return;
    const plain = JSON.stringify(creds, BufferJSON.replacer);
    this.writes = this.writes.then(async () => this.store.writeAuth("creds", "", await this.deps.seal(plain))).catch(() => undefined);
  }

  private keyStore(): SignalKeyStore {
    return {
      get: async <T extends keyof SignalDataTypeMap>(type: T, ids: string[]) => {
        await this.writes;
        const found: { [id: string]: SignalDataTypeMap[T] } = {};
        for (const id of ids) {
          const sealed = this.store.readAuth(type, id);
          const plain = sealed ? await this.deps.unseal(sealed) : null;
          if (!plain) continue;
          let value = JSON.parse(plain, BufferJSON.reviver);
          if (type === "app-state-sync-key") value = proto.Message.AppStateSyncKeyData.fromObject(value);
          found[id] = value;
        }
        return found;
      },
      set: async (data: SignalDataSet) => {
        const sealed: Array<[string, string, string | null]> = [];
        for (const type in data) {
          for (const [id, value] of Object.entries(data[type as keyof SignalDataSet] ?? {})) {
            sealed.push([type, id, value ? await this.deps.seal(JSON.stringify(value, BufferJSON.replacer)) : null]);
          }
        }
        const write = this.writes.then(() => this.deps.transaction(() => {
          for (const [type, id, value] of sealed) this.store.writeAuth(type, id, value);
        }));
        this.writes = write.catch(() => undefined);
        await write;
      },
    };
  }

  /** Runs one of the app's tools against the cache, connecting first if the socket went. */
  async run(tools: ReadonlyArray<{ name: string; run(api: WhatsAppDevice, input: Record<string, unknown>): Promise<unknown> }>, name: string, input: Record<string, unknown>): Promise<LinkedOutcome> {
    const status = this.status();
    if (status === "unlinked") return { unlinked: true };
    if (status !== "linked") return { error: "This WhatsApp device is not linked yet." };
    const tool = tools.find((t) => t.name === name);
    if (!tool) return { error: `WhatsApp has no tool named ${name}` };
    void this.connect().catch(() => undefined);
    return { result: await tool.run(this, input) };
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Baileys' logger, quiet but for errors, which go to the Worker's logs. */
const quiet = {
  level: "error",
  child() {
    return quiet;
  },
  trace() {},
  debug() {},
  info() {},
  warn() {},
  error(object: unknown, message?: string) {
    console.warn("whatsapp:", message ?? "", object instanceof Error ? object.message : "");
  },
};
