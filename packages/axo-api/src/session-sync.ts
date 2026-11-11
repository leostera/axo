/**
 * Session sync and client delivery (RFD0018; modelled in specs/sessions/session-sync.ts and
 * specs/sessions/client-delivery.ts).
 *
 * Upload: Axod → HostDO → SessionDO. On every connect Axod sends `axo.host.sync`, a manifest of
 * every Session it has, and the cloud answers with what it holds; Axod then appends the lines it
 * is missing until each is acknowledged as committed.
 *
 * Delivery: SessionDO → ClientDO → client. A client holds one socket, opens the Sessions it shows
 * by window, and acknowledges each batch of records before it gets the next.
 */
import { z } from "zod";
import { uuid } from "./identity.ts";
import { PI3_FORMAT } from "./pi3.ts";
import { piRuntimeSchema } from "./pi.ts";
import { hostModelSchema } from "./v1.ts";

export const SYNC = {
  /** Records and bytes of lines in one append batch. */
  appendRecords: 64,
  appendBytes: 1_048_576,
  /** Append batches Axod keeps waiting for acknowledgement, per Session and in total. */
  inflightPerSession: 4,
  inflightTotal: 16,
  /** Every request Axod or a client sends has this long to be answered. */
  requestTimeoutMs: 10_000,
  /**
   * A records batch a client has not acknowledged for this long is sent again, the next time
   * anything wakes its ClientDO for that Session (RFD0031: nothing wakes it on a timer).
   */
  stallMs: 30_000,
  /** How stale a host's last-seen time on the account may get while it is online (RFD0031). */
  lastSeenMs: 600_000,
  /** How long a HostDO gathers notices before it sends them. */
  noticeMs: 75,
  /** Records and bytes in one batch to a client; a single larger record goes alone. */
  clientRecords: 64,
  clientBytes: 524_288,
  /** Records an `open` without `have` or `window` returns. */
  defaultWindow: 20,
  /** Sessions one manifest may list. */
  manifestSessions: 4096,
  /** Positions one `chainAt` may ask for. */
  chainAtPositions: 32,
} as const;

export const hashSchema = z.string().regex(/^sha256:[0-9a-f]{64}$/);
const count = z.number().int().min(0).max(Number.MAX_SAFE_INTEGER);
const position = z.number().int().min(1).max(Number.MAX_SAFE_INTEGER);
const epoch = z.number().int().min(1).max(Number.MAX_SAFE_INTEGER);
const round = z.number().int().min(1).max(Number.MAX_SAFE_INTEGER);
const unixSeconds = z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER);
const emoji = z.string().min(1).max(16).refine((value) => value.trim() === value && !/[\p{Cc}\p{White_Space}]/u.test(value));
const piId = z.string().min(1).max(128);
const line = z.string().min(2);

export const sessionStatusSchema = z.enum(["starting", "ready", "working", "needsAttention", "unavailable"]);
export type SessionStatus = z.infer<typeof sessionStatusSchema>;

const gitHash = z.string().regex(/^[0-9a-f]{7,64}$/);
const pathText = z.string().max(1024);

/**
 * A Session's folder and its repository as git saw it when the agent last settled, so another Mac
 * can tell what it would need to continue the Session (RFD0022). Outside a repository only `path`.
 */
export const workspaceStateSchema = z.object({
  path: pathText,
  repoRoot: pathText.nullable(),
  /** The upstream remote's URL, with any credentials removed. */
  remote: z.string().min(1).max(1024).nullable(),
  /** Null when HEAD is detached. */
  branch: z.string().min(1).max(255).nullable(),
  head: gitHash.nullable(),
  /** Where the branch's upstream was, as last fetched on that Mac. */
  upstreamHead: gitHash.nullable(),
  /** Paths `git status` lists, at most 50; `dirtyMore` counts the rest. */
  dirty: z.array(pathText).max(50),
  dirtyMore: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER),
  /** Unix seconds. */
  at: unixSeconds,
}).strict();
export type WorkspaceState = z.infer<typeof workspaceStateSchema>;

/** What a client lists a Session by. The host owns it and raises its version on every change. */
export const sessionMetadataSchema = z.object({
  name: z.string().min(1).max(80).nullable(),
  emoji: emoji.nullable(),
  /** The last component of the Session's folder (RFD0038). */
  folderName: z.string().min(1).max(255).nullable(),
  hasAgent: z.boolean(),
  /** Unix seconds. */
  createdAt: unixSeconds.nullable(),
  /** Unix seconds of the latest completed user or assistant message. */
  lastMessageAt: unixSeconds.nullable(),
  /** Archived on the Mac, deleted there, or missing from its manifest: the cloud never deletes. */
  archived: z.boolean(),
  /** Absent until the Mac has read it; older Macs never send it. */
  workspaceState: workspaceStateSchema.optional(),
  /** What the Session's Pi runs, as it last said (RFD0033); absent until it has. */
  pi: piRuntimeSchema.optional(),
}).strict();
export type SessionMetadata = z.infer<typeof sessionMetadataSchema>;

export const uploadStateSchema = z.object({ count, chain: hashSchema, heads: z.array(hashSchema).max(1024) }).strict();
export type UploadState = z.infer<typeof uploadStateSchema>;

// ─── Axod → HostDO ──────────────────────────────────────────────────────────

export const HOST_SYNC_METHODS = {
  sync: "axo.host.sync",
  append: "axo.host.session.append",
  chainAt: "axo.host.session.chainAt",
  truncate: "axo.host.session.truncate",
  meta: "axo.host.session.meta",
  progress: "axo.host.session.progress",
  status: "axo.host.session.status",
} as const;

export const manifestRowSchema = z.object({
  sessionId: uuid,
  metadataVersion: position,
  metadata: sessionMetadataSchema,
  format: z.literal(PI3_FORMAT),
  /** Null while the Session has no transcript yet. */
  upload: uploadStateSchema.nullable(),
}).strict();
export type ManifestRow = z.infer<typeof manifestRowSchema>;

export const hostSyncParamsSchema = z.object({
  hostId: uuid,
  hostGeneration: uuid,
  round,
  sessions: z.array(manifestRowSchema).max(SYNC.manifestSessions),
}).strict();
export type HostSyncParams = z.infer<typeof hostSyncParamsSchema>;

export const cloudSessionStateSchema = z.discriminatedUnion("state", [
  z.object({ sessionId: uuid, state: z.literal("unknown") }).strict(),
  z.object({ sessionId: uuid, state: z.literal("known"), epoch, count, chain: hashSchema, heads: z.array(hashSchema).max(1024) }).strict(),
]);
export type CloudSessionState = z.infer<typeof cloudSessionStateSchema>;

export const hostSyncResultSchema = z.object({
  round,
  /** False when the manifest was from an older round than the last applied; Axod syncs again. */
  applied: z.boolean(),
  sessions: z.array(cloudSessionStateSchema).max(SYNC.manifestSessions),
  serverOnly: z.array(uuid).max(SYNC.manifestSessions),
}).strict();
export type HostSyncResult = z.infer<typeof hostSyncResultSchema>;

export const appendRecordSchema = z.object({ id: piId.nullable(), line, hash: hashSchema }).strict();
export type AppendRecord = z.infer<typeof appendRecordSchema>;

export const appendParamsSchema = z.object({
  sessionId: uuid,
  epoch,
  /** The position of the first record. */
  from: position,
  /** The raw header line; required while the cloud does not know the Session. */
  header: line.optional(),
  records: z.array(appendRecordSchema).min(1).max(SYNC.appendRecords),
}).strict();
export type AppendParams = z.infer<typeof appendParamsSchema>;

/** `gap`, `conflict` and `epoch` all mean: run the handshake again for this Session. */
export const appendResultSchema = z.discriminatedUnion("outcome", [
  z.object({ outcome: z.literal("committed"), epoch, count, chain: hashSchema }).strict(),
  z.object({ outcome: z.enum(["gap", "conflict", "epoch", "invalid"]), epoch: epoch.nullable(), count, chain: hashSchema.nullable() }).strict(),
]);
export type AppendResult = z.infer<typeof appendResultSchema>;

export const chainAtParamsSchema = z.object({
  sessionId: uuid,
  round,
  positions: z.array(count).min(1).max(SYNC.chainAtPositions),
}).strict();
export const chainAtResultSchema = z.object({
  round,
  epoch: epoch.nullable(),
  /** The cloud's chain after each position, or null past its count. */
  chains: z.array(hashSchema.nullable()),
}).strict();

export const truncateParamsSchema = z.object({ sessionId: uuid, round, keep: count, expectedChain: hashSchema }).strict();
export const truncateResultSchema = z.discriminatedUnion("outcome", [
  z.object({ round, outcome: z.literal("truncated"), epoch, count, chain: hashSchema }).strict(),
  z.object({ round, outcome: z.literal("mismatch") }).strict(),
]);

export const metaParamsSchema = z.object({ sessionId: uuid, metadataVersion: position, metadata: sessionMetadataSchema }).strict();
export const metaResultSchema = z.object({ applied: z.boolean() }).strict();

/** A progress slot: `"message"` for the reply being written, or a tool call's id. */
export const progressSlotSchema = z.string().min(1).max(128);
export const progressParamsSchema = z.object({
  sessionId: uuid,
  slot: progressSlotSchema,
  /** The newest snapshot, or null to clear the slot. */
  snapshot: z.unknown(),
  at: unixSeconds,
}).strict();
export const statusParamsSchema = z.object({ sessionId: uuid, status: sessionStatusSchema, at: unixSeconds }).strict();

// ─── Client ↔ ClientDO ──────────────────────────────────────────────────────

export const CLIENT_METHODS = {
  hello: "axo.client.hello",
  /** Lists the account's hosts again now, as hello does: for a host paired a moment ago. */
  refresh: "axo.client.refresh",
  hosts: "axo.client.hosts",
  sessions: "axo.client.sessions",
  open: "axo.client.session.open",
  records: "axo.client.session.records",
  ack: "axo.client.session.ack",
  older: "axo.client.session.older",
  progress: "axo.client.session.progress",
  reset: "axo.client.session.reset",
  close: "axo.client.session.close",
  command: "axo.client.command",
  /** Names a Mac of the account (RFD0022). */
  renameHost: "axo.client.host.rename",
  /** Protocol 3, on a host socket: the Mac came online or went offline (RFD0032). */
  presence: "axo.client.host.presence",
  /** Protocol 3, on a host socket: the Mac was named (RFD0032). */
  label: "axo.client.host.label",
} as const;

/**
 * Protocol 3 (RFD0032): the account socket lists the hosts, and a socket on each host's HostDO
 * carries its index, records, progress and commands. Protocol 2 has the account socket carry it all.
 */
export const CLIENT_PROTOCOL = { relayed: 2, direct: 3 } as const;

export const clientIdSchema = z.string().regex(/^[A-Za-z0-9_-]{8,64}$/);

/** What a person calls a Mac; empty goes back to the name the Mac reports. */
export const hostNameSchema = z.string().trim().max(64).refine((value) => !/\p{Cc}/u.test(value), "No control characters");
export const clientHostRenameParamsSchema = z.object({ hostId: uuid, name: hostNameSchema }).strict();
export const clientHostRenameResultSchema = z.object({ label: z.string().min(1).max(128) }).strict();

/** A durable record as clients see it. Only the format adapter on the client knows Pi. */
export const clientRecordSchema = z.object({
  /** The record's place in the cloud copy: the client's resume point within one epoch. */
  cursor: position,
  id: piId.nullable(),
  format: z.literal(PI3_FORMAT),
  line,
  hash: hashSchema,
}).strict();
export type ClientRecord = z.infer<typeof clientRecordSchema>;

export const clientHostSchema = z.object({
  hostId: uuid,
  hostGeneration: uuid,
  label: z.string().min(1).max(128),
  hostKind: z.string().regex(/^[a-z][a-z0-9-]{0,63}$/),
  model: hostModelSchema.optional(),
  online: z.boolean(),
  lastSeenAt: z.string().datetime({ offset: true }),
}).strict();
export type ClientHost = z.infer<typeof clientHostSchema>;

export const clientSessionSchema = z.object({
  hostId: uuid,
  sessionId: uuid,
  metadata: sessionMetadataSchema,
  /** Null until the first record lands. */
  epoch: epoch.nullable(),
  head: count,
  status: sessionStatusSchema.nullable(),
}).strict();
export type ClientSession = z.infer<typeof clientSessionSchema>;

export const progressSnapshotSchema = z.object({ slot: progressSlotSchema, snapshot: z.unknown() }).strict();
export type ProgressSnapshot = z.infer<typeof progressSnapshotSchema>;

/** On the account socket. In protocol 3 it answers with the hosts and no Sessions. */
export const clientHelloParamsSchema = z.object({ protocolVersion: z.union([z.literal(2), z.literal(3)]), clientId: clientIdSchema }).strict();
export const clientHelloResultSchema = z.object({
  hosts: z.array(clientHostSchema),
  sessions: z.array(clientSessionSchema),
}).strict();
export type ClientHello = z.infer<typeof clientHelloResultSchema>;

export const clientHostsParamsSchema = z.object({ hosts: z.array(clientHostSchema) }).strict();

/**
 * On a host socket (protocol 3). `connection` grows with each connection the client makes: the
 * HostDO keeps a client's newest socket, and refuses an older one whose hello comes late.
 */
export const clientHostHelloParamsSchema = z.object({
  protocolVersion: z.literal(3),
  clientId: clientIdSchema,
  connection: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER),
}).strict();
export const clientPresenceParamsSchema = z.object({ online: z.boolean(), hostGeneration: uuid.nullable() }).strict();
export type ClientPresence = z.infer<typeof clientPresenceParamsSchema>;
/** The host's index, and whether it is online. What it is asking follows as notifications. */
export const clientHostHelloResultSchema = clientPresenceParamsSchema.extend({ sessions: z.array(clientSessionSchema) }).strict();
export type ClientHostHello = z.infer<typeof clientHostHelloResultSchema>;
export const clientLabelParamsSchema = z.object({ label: z.string().min(1).max(128) }).strict();
export const clientSessionsParamsSchema = z.object({ hostId: uuid, sessions: z.array(clientSessionSchema) }).strict();

export const clientOpenParamsSchema = z.object({
  hostId: uuid,
  sessionId: uuid,
  have: z.object({ epoch, cursor: count }).strict().optional(),
  window: z.object({ last: z.number().int().min(1).max(SYNC.clientRecords) }).strict().optional(),
}).strict();
export const clientOpenResultSchema = z.object({
  /** Null while the cloud holds no records for the Session. */
  epoch: epoch.nullable(),
  records: z.array(clientRecordSchema),
  /** The last cursor the client holds after applying `records`. */
  cursor: count,
  /** Records below this cursor exist; null when the client holds the start. */
  older: count.nullable(),
  progress: z.array(progressSnapshotSchema),
  /** Pi's header line, for a client that opened from `have.cursor` 0 to keep a whole copy (RFD0022). */
  header: line.optional(),
}).strict();
export type ClientOpenResult = z.infer<typeof clientOpenResultSchema>;

export const clientRecordsParamsSchema = z.object({ sessionId: uuid, epoch, records: z.array(clientRecordSchema).min(1), cursor: position }).strict();
export const clientAckParamsSchema = z.object({ sessionId: uuid, cursor: count }).strict();
export const clientOlderParamsSchema = z.object({ sessionId: uuid, before: position, limit: z.number().int().min(1).max(SYNC.clientRecords) }).strict();
/** Records just below `before`, oldest first, and the next `before` to page with. */
export const clientOlderResultSchema = z.object({ epoch: epoch.nullable(), records: z.array(clientRecordSchema), older: count.nullable() }).strict();
export const clientProgressParamsSchema = z.object({ sessionId: uuid, slot: progressSlotSchema, snapshot: z.unknown() }).strict();
export const clientResetParamsSchema = z.object({ sessionId: uuid, epoch, keep: count }).strict();
export const clientCloseParamsSchema = z.object({ sessionId: uuid }).strict();
export const clientCommandParamsSchema = z.object({
  hostId: uuid,
  method: z.string().regex(/^axo\.remote\.[a-z.]+$/).max(128),
  params: z.record(z.string(), z.unknown()),
}).strict();
