import {
  CLIENT_METHODS,
  ELICITATION_ERRORS,
  ELICITATION_METHODS,
  FRAGMENT_METHOD,
  DISCARD_METHOD,
  MemoryPartialStore,
  SYNC,
  callSchema,
  clientAckParamsSchema,
  clientCloseParamsSchema,
  clientCommandParamsSchema,
  clientElicitationResolveParamsSchema,
  clientHostHelloParamsSchema,
  clientIdSchema,
  clientOlderParamsSchema,
  clientOpenParamsSchema,
  decode,
  discardParamsSchema,
  failure,
  receiveFragment,
  splitMessage,
  success,
  uuid,
  type Call,
  type ClientHostHello,
  type ClientOpenResult,
  type ClientPresence,
  type ClientRecord,
  type ClientSession,
  type Elicitation,
  type Reply,
} from "@axo/protocol";
import { z } from "zod";
import type { HostCommandOutcome, HostNotice } from "./host-do";
import type { ReadRequest, ReadResult } from "./session-store";
import { recordApiEvent } from "./observability";

/**
 * Protocol 3 (RFD0032): the client sockets a HostDO serves itself. A client opens one on each
 * Mac's HostDO and gets that Mac's index, records, progress and resets on it, and sends it
 * commands. No ClientDO sits between them, so a record costs the one SessionDO append: the HostDO
 * sends what it committed from the append in hand, and reads the SessionDO only for records it
 * no longer holds.
 *
 * What each socket has of each Session it opened is a `client_opens` row, so it outlives a
 * hibernation. Recent records, read ids and partial messages are in memory, and only save reads.
 */

/** The `X-Axo-Role` of a protocol 3 client socket, as the Worker forwards it. */
export const DIRECT_CLIENT_ROLE = "direct-client";

/** Frames a client may send per second on a host socket; acknowledgements count. */
const FRAMES_PER_SECOND = 60;
/** The largest message a client may send, reassembled: a prompt with its attachments. */
const CLIENT_MESSAGE_BYTES = 1_048_576;
/** How many reads one pump makes before it gives up until the next event: each one learned something. */
const PUMP_READS = 4;

const attachmentSchema = z.object({
  kind: z.literal(DIRECT_CLIENT_ROLE),
  accountId: uuid,
  clientId: clientIdSchema,
  socketId: uuid,
  /** The client's connection number, from its hello; -1 until then. */
  connection: z.number().int().min(-1),
  /**
   * A signed-in person's client, not a Mac following its peers (RFD0022). Only people see and
   * answer what a Mac asks (RFD0029). Sockets accepted before this field existed were people's.
   */
  person: z.boolean().default(true),
  expiresAt: z.number().finite(),
  window: z.number(),
  calls: z.number().int().nonnegative(),
}).strict();
type Attachment = z.infer<typeof attachmentSchema>;

/** Whether a socket's attachment is a protocol 3 client's. */
export function isDirectClient(attachment: unknown): boolean {
  return attachmentSchema.safeParse(attachment).success;
}

/**
 * A Session a socket has open. `acked` is the last cursor the client acknowledged, `sent` the last
 * one sent: a batch is outstanding while they differ. `epoch` is null until the Session has records.
 */
type OpenRow = { socket_id: string; session_id: string; epoch: number | null; sent: number; acked: number; sent_at: number };

/** A call's id, as its reply names it. */
type Id = NonNullable<Call["id"]> | null;

/** A call's reply, and what follows it on the socket once it is sent. */
type Answer = { reply: Reply | null; after?: () => Promise<void> | void };

/** How far a pump may go: a moved epoch makes it read where the Session was cut (learnTheCut). */
type PumpOptions = { epochMoved?: boolean; reads?: number };

/** What `HostClients` needs from its HostDO. */
export interface HostClientsHost {
  hostId(): string | undefined;
  presence(): ClientPresence;
  sessions(): ClientSession[];
  /** The index's head for a Session, or undefined if it isn't listed. */
  head(sessionId: string): { epoch: number | null; head: number } | undefined;
  read(sessionId: string, request: ReadRequest): Promise<ReadResult>;
  progress(sessionId: string): Array<{ slot: string; snapshot: unknown }>;
  elicitations(): Elicitation[];
  command(method: string, params: unknown): Promise<HostCommandOutcome>;
  resolveElicitation(params: unknown): Promise<HostCommandOutcome>;
}

/**
 * The records each Session committed lately, contiguous and in one epoch, while the object is in
 * memory (RFD0032, pushFromAppend). A client acknowledging a batch gets the next one from here
 * when it can. Lost on hibernation, which costs a read.
 */
export class RecentRecords {
  private readonly sessions = new Map<string, { epoch: number; records: ClientRecord[]; bytes: number }>();

  constructor(private readonly limits = { records: SYNC.clientRecords * 2, bytes: SYNC.clientBytes * 2, sessions: 64 }) {}

  add(sessionId: string, epoch: number, records: ClientRecord[]): void {
    if (records.length === 0) return;
    let held = this.sessions.get(sessionId);
    if (!held || held.epoch !== epoch || held.records.at(-1)!.cursor + 1 !== records[0]!.cursor) held = { epoch, records: [], bytes: 0 };
    this.sessions.delete(sessionId);
    for (const record of records) {
      held.records.push(record);
      held.bytes += record.line.length;
    }
    while (held.records.length > 1 && (held.records.length > this.limits.records || held.bytes > this.limits.bytes))
      held.bytes -= held.records.shift()!.line.length;
    this.sessions.set(sessionId, held);
    while (this.sessions.size > this.limits.sessions) this.sessions.delete(this.sessions.keys().next().value!);
  }

  /**
   * The records after `cursor` in `epoch`, at most a batch; null when they aren't all held from
   * `cursor + 1`, so the caller reads instead.
   */
  after(sessionId: string, epoch: number, cursor: number): ClientRecord[] | null {
    const held = this.sessions.get(sessionId);
    if (!held || held.epoch !== epoch || held.records[0]!.cursor > cursor + 1) return null;
    const batch: ClientRecord[] = [];
    let bytes = 0;
    for (const record of held.records) {
      if (record.cursor <= cursor) continue;
      if (batch.length > 0 && (batch.length >= SYNC.clientRecords || bytes + record.line.length > SYNC.clientBytes)) break;
      batch.push(record);
      bytes += record.line.length;
    }
    return batch;
  }

  /** The Session moved to a new epoch: what is held may be past the cut. */
  drop(sessionId: string): void {
    this.sessions.delete(sessionId);
  }
}

export class HostClients {
  private readonly partials = new Map<string, MemoryPartialStore>();
  /** The latest read per open Session and socket: a reply to an older one is ignored. */
  private readonly reads = new Map<string, number>();
  readonly recent = new RecentRecords();

  constructor(
    private readonly ctx: DurableObjectState,
    private readonly host: HostClientsHost,
  ) {}

  // ─── Sockets ───────────────────────────────────────────────────────────────

  /** Accepts a client socket the Worker forwarded, signed in to the account that owns this host. */
  accept(request: Request): Response {
    const attachment = attachmentSchema.safeParse({
      kind: DIRECT_CLIENT_ROLE,
      accountId: request.headers.get("X-Axo-Account"),
      clientId: request.headers.get("X-Axo-Client"),
      socketId: crypto.randomUUID(),
      connection: -1,
      person: request.headers.get("X-Axo-Person") !== "0",
      expiresAt: Number(request.headers.get("X-Axo-Expiry")),
      window: Date.now(),
      calls: 0,
    });
    if (!attachment.success || attachment.data.expiresAt <= Date.now()) return new Response("Invalid internal identity", { status: 403 });
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server!);
    server!.serializeAttachment(attachment.data);
    return new Response(null, { status: 101, webSocket: client });
  }

  serves(socket: WebSocket): boolean {
    return isDirectClient(socket.deserializeAttachment());
  }

  async receive(socket: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    const peer = this.attachment(socket);
    if (!peer || !this.admit(socket, peer, raw)) return;
    const call = this.callIn(socket, peer, raw as string);
    if (!call) return;
    const answer = await this.answer(socket, peer, call);
    if (answer.reply && call.id !== undefined) this.send(socket, answer.reply);
    await answer.after?.();
  }

  /** Whether a frame may be read: signed in, text, and within the rate limit. Closes it if not. */
  private admit(socket: WebSocket, peer: Attachment, raw: string | ArrayBuffer): raw is string {
    if (peer.expiresAt <= Date.now()) return this.close(socket, 4001, "Sign-in expired"), false;
    if (typeof raw !== "string") return this.close(socket, 1003, "Text required"), false;
    if (Date.now() - peer.window >= 1000) Object.assign(peer, { window: Date.now(), calls: 0 });
    peer.calls += 1;
    socket.serializeAttachment(peer);
    if (peer.calls > FRAMES_PER_SECOND) return this.close(socket, 1008, "Rate limit"), false;
    return true;
  }

  /**
   * The call a frame carries, once whole: a fragment is kept until its message completes, and a
   * frame that isn't one call is answered with its error. Null when there is nothing to answer.
   */
  private callIn(socket: WebSocket, peer: Attachment, raw: string): Call | null {
    let decoded = decode(raw);
    if ("error" in decoded) return this.send(socket, decoded.error), null;
    const frame = decoded.batch ? undefined : callSchema.safeParse(decoded.entries[0]);
    if (frame?.success && frame.data.method === DISCARD_METHOD) {
      const notice = discardParamsSchema.safeParse(frame.data.params);
      if (notice.success) this.partialsOf(peer.socketId).discard(notice.data.messageId);
      return null;
    }
    if (frame?.success && frame.data.method === FRAGMENT_METHOD) {
      const outcome = receiveFragment(this.partialsOf(peer.socketId), frame.data.params);
      if (outcome.status === "invalid") return this.close(socket, 1008, `Invalid fragment: ${outcome.reason}`), null;
      if (outcome.status !== "complete") return null;
      decoded = decode(outcome.raw, CLIENT_MESSAGE_BYTES);
      if ("error" in decoded) return this.send(socket, decoded.error), null;
    }
    if (decoded.batch) return this.send(socket, failure(null, -32600, "Batches are not supported")), null;
    const call = callSchema.safeParse(decoded.entries[0]);
    if (!call.success) return this.send(socket, failure(null, -32600, "Invalid Request")), null;
    return call.data;
  }

  /** A socket closed: what it had open goes with it. */
  closed(socket: WebSocket): void {
    const peer = this.attachment(socket);
    if (!peer) return;
    this.forgetSocket(peer.socketId);
  }

  // ─── From the HostDO ───────────────────────────────────────────────────────

  /**
   * Records a Session just committed: held for the clients that will want them, and sent at once
   * to each socket waiting on the record before them. The HostDO has refreshed the index first.
   */
  async committed(sessionId: string, epoch: number, records: ClientRecord[]): Promise<void> {
    this.recent.add(sessionId, epoch, records);
    await Promise.all(this.rowsOf(sessionId).map((row) => this.pump(row.socket_id, sessionId)));
  }

  /** A Session moved to a new epoch (it was cut back): what is held may be past the cut. */
  epochMoved(sessionId: string): void {
    this.recent.drop(sessionId);
  }

  /**
   * This HostDO cut a Session back to `keep` records, starting `epoch`: each socket in the epoch
   * before is told so, with no read. One further behind learns where with a read (learnTheCut).
   */
  cut(sessionId: string, epoch: number, keep: number): void {
    this.recent.drop(sessionId);
    for (const row of this.rowsOf(sessionId)) {
      const socket = this.socket(row.socket_id);
      if (socket && row.epoch === epoch - 1) this.reset(socket, row, { kind: "reset", epoch, keep });
    }
  }

  /** The HostDO's notices, as frames on each socket that said hello. */
  async deliver(notices: HostNotice[]): Promise<void> {
    const hostId = this.host.hostId();
    if (!hostId) return;
    await Promise.all(this.sockets().map((socket) => {
      const peer = this.attachment(socket)!;
      return peer.connection < 0 ? undefined : this.deliverTo(socket, peer, hostId, notices);
    }));
  }

  /**
   * One socket's share of the notices: every listing change, and progress and moves of what it
   * has open. An open Session that changed or moved is pumped. Only people see what a Mac asks: a
   * Mac following its peers does not (RFD0029).
   */
  private async deliverTo(socket: WebSocket, peer: Attachment, hostId: string, notices: HostNotice[]): Promise<void> {
    const open = new Set(this.rowsOfSocket(peer.socketId).map((row) => row.session_id));
    const sessions: ClientSession[] = [];
    /** Each open Session to pump, and whether its epoch moved. */
    const touched = new Map<string, boolean>();
    for (const notice of notices) {
      switch (notice.kind) {
        case "session":
          sessions.push(notice.session);
          if (open.has(notice.session.sessionId)) touched.set(notice.session.sessionId, touched.get(notice.session.sessionId) ?? false);
          break;
        case "progress":
          if (open.has(notice.sessionId))
            this.send(socket, { jsonrpc: "2.0", method: CLIENT_METHODS.progress, params: { sessionId: notice.sessionId, slot: notice.slot, snapshot: notice.snapshot } });
          break;
        case "epoch":
          // A row already in that epoch (`cut` told it) has nothing to learn.
          if (open.has(notice.sessionId)) touched.set(notice.sessionId, this.row(peer.socketId, notice.sessionId)?.epoch !== notice.epoch);
          break;
        case "presence":
          this.send(socket, { jsonrpc: "2.0", method: CLIENT_METHODS.presence, params: { online: notice.online, hostGeneration: notice.hostGeneration } });
          break;
        case "label":
          this.send(socket, { jsonrpc: "2.0", method: CLIENT_METHODS.label, params: { label: notice.label } });
          break;
        case "elicitationRequested":
          if (peer.person) this.send(socket, this.requested(notice.elicitation));
          break;
        case "elicitationResolved":
          if (peer.person) this.send(socket, { jsonrpc: "2.0", method: ELICITATION_METHODS.resolved, params: { hostId, ...notice.resolved } });
          break;
      }
    }
    if (sessions.length) this.send(socket, { jsonrpc: "2.0", method: CLIENT_METHODS.sessions, params: { hostId, sessions } });
    for (const [sessionId, epochMoved] of touched) await this.pump(peer.socketId, sessionId, { epochMoved });
  }

  // ─── Client requests ───────────────────────────────────────────────────────

  private async answer(socket: WebSocket, peer: Attachment, call: Call): Promise<Answer> {
    const id = call.id ?? null;
    const hostId = this.host.hostId();
    if (call.method === CLIENT_METHODS.hello) return this.hello(socket, peer, call);
    if (peer.connection < 0 || !hostId) return { reply: failure(id, -32600, "Say hello first") };
    try {
      switch (call.method) {
        case CLIENT_METHODS.open: {
          const params = clientOpenParamsSchema.safeParse(call.params);
          if (!params.success || params.data.hostId !== hostId) return { reply: failure(id, -32602, "Invalid params") };
          const opened = await this.open(peer.socketId, params.data);
          // What the open did not return follows it, in batches.
          return { reply: success(id, opened), after: () => this.pump(peer.socketId, params.data.sessionId) };
        }
        case CLIENT_METHODS.ack: {
          const params = clientAckParamsSchema.safeParse(call.params);
          if (params.success) await this.ack(peer.socketId, params.data.sessionId, params.data.cursor);
          return { reply: null };
        }
        case CLIENT_METHODS.older:
          return { reply: await this.older(socket, peer, id, call.params) };
        case CLIENT_METHODS.close: {
          const params = clientCloseParamsSchema.safeParse(call.params);
          if (params.success) this.forgetOpen(peer.socketId, params.data.sessionId);
          return { reply: null };
        }
        case CLIENT_METHODS.command:
          return { reply: await this.command(hostId, id, call.params) };
        case ELICITATION_METHODS.resolve:
          return { reply: await this.resolve(peer, hostId, id, call.params) };
        default:
          return { reply: failure(id, -32601, "Method not found") };
      }
    } catch {
      return { reply: failure(id, -32603, "Unavailable; try again") };
    }
  }

  /** Records just before `before` of a Session the socket has open. */
  private async older(socket: WebSocket, peer: Attachment, id: Id, raw: unknown): Promise<Reply> {
    const params = clientOlderParamsSchema.safeParse(raw);
    const open = params.success ? this.row(peer.socketId, params.data.sessionId) : undefined;
    if (!params.success || !open) return failure(id, -32602, "Invalid params");
    const read = await this.read(open.session_id, { epoch: open.epoch, before: params.data.before, limit: params.data.limit });
    if (read.kind === "reset") {
      this.reset(socket, open, read);
      return success(id, { epoch: read.epoch, records: [], older: null });
    }
    return success(id, { epoch: read.epoch, records: read.records, older: read.older });
  }

  /** Runs a command on the Mac. A call that throws may have reached it: its outcome is unknown (RFD0024). */
  private async command(hostId: string, id: Id, raw: unknown): Promise<Reply> {
    const params = clientCommandParamsSchema.safeParse(raw);
    if (!params.success || params.data.hostId !== hostId) return failure(id, -32602, "Invalid params");
    const outcome = await this.host.command(params.data.method, params.data.params)
      .catch((): HostCommandOutcome => ({ error: { code: -32004, message: "Outcome unknown; reconcile commandId" } }));
    return "error" in outcome ? failure(id, outcome.error.code, outcome.error.message) : success(id, outcome.result);
  }

  /** A person's answer to what the Mac asks. A Mac's own credential cannot answer, for any Mac (RFD0029). */
  private async resolve(peer: Attachment, hostId: string, id: Id, raw: unknown): Promise<Reply> {
    if (!peer.person) return failure(id, ELICITATION_ERRORS.notAPerson, "Only a person answers");
    const params = clientElicitationResolveParamsSchema.safeParse(raw);
    const presence = this.host.presence();
    if (!params.success || params.data.hostId !== hostId) return failure(id, -32602, "Invalid params");
    if (presence.hostGeneration === null) return failure(id, -32005, "Host offline; nothing sent");
    const { elicitationId, action, sealed, device } = params.data;
    const outcome = await this.host
      .resolveElicitation({ target: { hostId, hostGeneration: presence.hostGeneration }, elicitationId, action, ...(sealed ? { sealed } : {}), ...(device ? { device } : {}) })
      .catch((): HostCommandOutcome => ({ error: { code: -32004, message: "Outcome unknown" } }));
    return "error" in outcome ? failure(id, outcome.error.code, outcome.error.message) : success(id, outcome.result);
  }

  /**
   * The index, once per socket. A client's newest connection wins: an older socket of the same
   * client is closed, and a hello older than a socket already serving it is refused. Rows whose
   * socket is gone (a reset closed it) are swept.
   */
  private hello(socket: WebSocket, peer: Attachment, call: Call): Answer {
    const id = call.id ?? null;
    const params = clientHostHelloParamsSchema.safeParse(call.params);
    if (!params.success) return { reply: failure(id, -32602, "Invalid params") };
    if (params.data.clientId !== peer.clientId) return { reply: failure(id, -32602, "clientId does not match the socket") };
    if (peer.connection >= 0) return { reply: failure(id, -32600, "Already said hello") };
    if (!this.host.hostId()) return { reply: failure(id, -32005, "Host not connected yet") };
    for (const other of this.sockets()) {
      const them = this.attachment(other)!;
      if (other === socket || them.clientId !== peer.clientId || them.connection < 0) continue;
      if (them.connection > params.data.connection) {
        recordApiEvent({ event: "host_client_replaced", outcome: "refused" });
        this.close(socket, 4000, "Replaced");
        return { reply: null };
      }
      recordApiEvent({ event: "host_client_replaced", outcome: "replaced" });
      this.close(other, 4000, "Replaced");
    }
    peer.connection = params.data.connection;
    socket.serializeAttachment(peer);
    this.sweep();
    recordApiEvent({ event: "host_client_hello" });
    const result: ClientHostHello = { ...this.host.presence(), sessions: this.host.sessions() };
    // What the Mac asks follows the index, to people only (RFD0029).
    const after = peer.person ? () => { for (const elicitation of this.host.elicitations()) this.send(socket, this.requested(elicitation)); } : undefined;
    return { reply: success(id, result), after };
  }

  /**
   * Opens a Session for a socket: nothing to read when the client holds the index's head
   * (openAtHead); otherwise the records after `have`, or the last `window`. The open counts as
   * acknowledged, and anything past it follows in batches.
   */
  private async open(socketId: string, params: z.infer<typeof clientOpenParamsSchema>): Promise<ClientOpenResult> {
    const sql = this.ctx.storage.sql;
    const { sessionId } = params;
    const readId = this.nextRead(socketId, sessionId);
    sql.exec(`INSERT INTO client_opens (socket_id, session_id, epoch, sent, acked, sent_at) VALUES (?, ?, NULL, 0, 0, 0)
      ON CONFLICT(socket_id, session_id) DO NOTHING`, socketId, sessionId);
    const progress = this.host.progress(sessionId);
    const head = this.host.head(sessionId);
    if (params.have && head && head.epoch === params.have.epoch && head.head === params.have.cursor) {
      this.update(socketId, sessionId, { epoch: head.epoch, sent: head.head, acked: head.head });
      recordApiEvent({ event: "client_open", records: 0, read: false });
      return { epoch: head.epoch, records: [], cursor: head.head, older: null, progress };
    }
    const open = this.row(socketId, sessionId)!;
    let read = params.have
      ? await this.read(sessionId, { epoch: params.have.epoch, after: params.have.cursor, limit: SYNC.clientRecords })
      : await this.read(sessionId, { epoch: null, last: params.window?.last ?? SYNC.defaultWindow, limit: SYNC.clientRecords });
    if (read.kind === "reset") {
      // The client's copy is from an older epoch: it drops past the cut, then reads on from there.
      const socket = this.socket(socketId);
      if (socket) this.send(socket, { jsonrpc: "2.0", method: CLIENT_METHODS.reset, params: { sessionId, epoch: read.epoch, keep: read.keep } });
      read = await this.read(sessionId, { epoch: read.epoch, after: Math.min(params.have!.cursor, read.keep), limit: SYNC.clientRecords });
    }
    if (read.kind === "reset" || this.reads.get(this.key(socketId, sessionId)) !== readId || !this.row(socketId, sessionId)) throw new Error("superseded");
    const cursor = read.records.at(-1)?.cursor ?? (params.have ? Math.min(params.have.cursor, read.count) : read.count);
    this.update(open.socket_id, sessionId, { epoch: read.epoch, sent: cursor, acked: cursor });
    recordApiEvent({ event: "client_open", records: read.records.length, read: true });
    return {
      epoch: read.epoch,
      records: read.records,
      cursor,
      older: params.have ? null : read.older,
      progress,
      // A copy that starts from nothing needs Pi's header line too (RFD0022).
      ...(params.have?.cursor === 0 && read.header !== null ? { header: read.header } : {}),
    };
  }

  private async ack(socketId: string, sessionId: string, cursor: number): Promise<void> {
    const open = this.row(socketId, sessionId);
    if (!open || cursor < open.acked || cursor > open.sent) return;
    this.update(socketId, sessionId, { acked: cursor });
    if (cursor === open.sent) await this.pump(socketId, sessionId);
  }

  /**
   * Sends a socket the next batch of an open Session, once the last is acknowledged and the index's
   * head is past it: from the records held when it can (pushFromAppend), otherwise read from the
   * SessionDO. With `epochMoved`, or when the row's epoch isn't the index's, it reads in the row's
   * epoch to learn where the Session was cut (learnTheCut). A read answered in an older epoch than
   * the index's now is made again (staleReadsAreRedone). A batch outstanding for `SYNC.stallMs`
   * is sent again.
   */
  private async pump(socketId: string, sessionId: string, { epochMoved = false, reads = 0 }: PumpOptions = {}): Promise<void> {
    const socket = this.socket(socketId);
    let open = this.row(socketId, sessionId);
    if (!socket || !open) return;
    if (!epochMoved && open.sent !== open.acked) {
      if (Date.now() - open.sent_at < SYNC.stallMs) return;
      // The client never acknowledged it; it ignores records it already holds.
      this.update(socketId, sessionId, { sent: open.acked });
      recordApiEvent({ event: "client_stalled" });
      open = { ...open, sent: open.acked };
    }
    const head = this.host.head(sessionId);
    const sameEpoch = head !== undefined && head.epoch === open.epoch;
    if (!epochMoved && sameEpoch && head.head <= open.acked) return;
    if (!epochMoved && sameEpoch && open.epoch !== null) {
      const held = this.recent.after(sessionId, open.epoch, open.acked);
      if (held && held.length > 0) return this.sendBatch(socket, open, open.epoch, held);
    }
    if (reads >= PUMP_READS) return;
    const readId = this.nextRead(socketId, sessionId);
    const request: ReadRequest = { epoch: open.epoch, after: open.acked, limit: SYNC.clientRecords };
    // A read that throws is made again at once, while the object is awake (retryAtOnce).
    const read = await this.read(sessionId, request).catch(() => this.read(sessionId, request)).catch(() => null);
    const current = this.row(socketId, sessionId);
    if (!read || !current || this.reads.get(this.key(socketId, sessionId)) !== readId) return;
    if (read.kind === "reset") {
      this.reset(socket, current, read);
      return this.pump(socketId, sessionId, { reads: reads + 1 });
    }
    const now = this.host.head(sessionId);
    if (now?.epoch != null && read.epoch !== null && read.epoch < now.epoch) return this.pump(socketId, sessionId, { epochMoved: true, reads: reads + 1 });
    if (read.epoch !== null) this.recent.add(sessionId, read.epoch, read.records);
    if (current.sent !== current.acked || read.records.length === 0) {
      if (current.epoch === null && read.epoch !== null) this.update(socketId, sessionId, { epoch: read.epoch });
      return;
    }
    this.sendBatch(socket, current, read.epoch!, read.records);
  }

  private sendBatch(socket: WebSocket, open: OpenRow, epoch: number, records: ClientRecord[]): void {
    const cursor = records.at(-1)!.cursor;
    this.update(open.socket_id, open.session_id, { epoch, sent: cursor, sent_at: Date.now() });
    this.send(socket, { jsonrpc: "2.0", method: CLIENT_METHODS.records, params: { sessionId: open.session_id, epoch, records, cursor } });
  }

  /** Tells the client its copy was cut back, and continues in the new epoch from the cut. */
  private reset(socket: WebSocket, open: OpenRow, read: Extract<ReadResult, { kind: "reset" }>): void {
    const keep = Math.min(open.acked, read.keep);
    this.update(open.socket_id, open.session_id, { epoch: read.epoch, sent: keep, acked: keep });
    this.send(socket, { jsonrpc: "2.0", method: CLIENT_METHODS.reset, params: { sessionId: open.session_id, epoch: read.epoch, keep: read.keep } });
  }

  private read(sessionId: string, request: ReadRequest): Promise<ReadResult> {
    return this.host.read(sessionId, request);
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  private requested(elicitation: Elicitation) {
    return { jsonrpc: "2.0", method: ELICITATION_METHODS.requested, params: { hostId: this.host.hostId(), elicitation } };
  }

  private sockets(): WebSocket[] {
    return this.ctx.getWebSockets().filter((socket) => socket.readyState === WebSocket.OPEN && this.attachment(socket) !== null);
  }

  private socket(socketId: string): WebSocket | undefined {
    return this.sockets().find((socket) => this.attachment(socket)!.socketId === socketId);
  }

  private attachment(socket: WebSocket): Attachment | null {
    const parsed = attachmentSchema.safeParse(socket.deserializeAttachment());
    return parsed.success ? parsed.data : null;
  }

  private close(socket: WebSocket, code: number, reason: string): void {
    const peer = this.attachment(socket);
    if (peer) this.forgetSocket(peer.socketId);
    try {
      socket.close(code, reason);
    } catch {
      // Already closing.
    }
  }

  /** Deletes the rows of sockets that no longer exist (sweepStaleRows). */
  private sweep(): void {
    const live = new Set(this.sockets().map((socket) => this.attachment(socket)!.socketId));
    for (const row of this.ctx.storage.sql.exec<{ socket_id: string }>("SELECT DISTINCT socket_id FROM client_opens").toArray())
      if (!live.has(row.socket_id)) this.forgetSocket(row.socket_id);
  }

  private forgetSocket(socketId: string): void {
    this.ctx.storage.sql.exec("DELETE FROM client_opens WHERE socket_id = ?", socketId);
    this.partials.get(socketId)?.clear();
    this.partials.delete(socketId);
    for (const key of this.reads.keys()) if (key.startsWith(`${socketId}:`)) this.reads.delete(key);
  }

  private forgetOpen(socketId: string, sessionId: string): void {
    this.ctx.storage.sql.exec("DELETE FROM client_opens WHERE socket_id = ? AND session_id = ?", socketId, sessionId);
    this.reads.delete(this.key(socketId, sessionId));
  }

  private partialsOf(socketId: string): MemoryPartialStore {
    let store = this.partials.get(socketId);
    if (!store) this.partials.set(socketId, (store = new MemoryPartialStore()));
    return store;
  }

  private row(socketId: string, sessionId: string): OpenRow | undefined {
    return this.ctx.storage.sql.exec<OpenRow>("SELECT * FROM client_opens WHERE socket_id = ? AND session_id = ?", socketId, sessionId).toArray()[0];
  }

  private rowsOf(sessionId: string): OpenRow[] {
    return this.ctx.storage.sql.exec<OpenRow>("SELECT * FROM client_opens WHERE session_id = ?", sessionId).toArray();
  }

  private rowsOfSocket(socketId: string): OpenRow[] {
    return this.ctx.storage.sql.exec<OpenRow>("SELECT * FROM client_opens WHERE socket_id = ?", socketId).toArray();
  }

  private update(socketId: string, sessionId: string, changes: Partial<Pick<OpenRow, "epoch" | "sent" | "acked" | "sent_at">>): void {
    const entries = Object.entries(changes);
    if (entries.length === 0) return;
    this.ctx.storage.sql.exec(
      `UPDATE client_opens SET ${entries.map(([column]) => `${column} = ?`).join(", ")} WHERE socket_id = ? AND session_id = ?`,
      ...entries.map(([, value]) => value), socketId, sessionId);
  }

  private key(socketId: string, sessionId: string): string {
    return `${socketId}:${sessionId}`;
  }

  private nextRead(socketId: string, sessionId: string): number {
    const key = this.key(socketId, sessionId);
    const id = (this.reads.get(key) ?? 0) + 1;
    this.reads.set(key, id);
    return id;
  }

  private send(socket: WebSocket, value: unknown): boolean {
    const frames = splitMessage(JSON.stringify(value), crypto.randomUUID().replaceAll("-", ""));
    if (!frames) {
      recordApiEvent({ event: "relay_send_failed", reason: "too_large" });
      return false;
    }
    try {
      for (const frame of frames) socket.send(frame);
      return true;
    } catch {
      return false;
    }
  }
}
