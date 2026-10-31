/**
 * Connections and tools (RFD0016; modelled in specs/connections.ts).
 *
 * A Session reaches its account's connections through `axod mcp`: the local axod forwards each
 * `axo.connections.*` request on its relay socket, the host's HostDO hands it to the account's
 * AxoAccountManager by RPC, and the answer comes back the same way. The account sends
 * `axo.connections.bash` the other way, down the target Mac's socket.
 *
 * Every request from a Mac names the Session that asked, so the call log can say who called.
 */
import { z } from "zod";
import { uuid } from "./identity.ts";

export const CONNECTIONS_METHODS = {
  list: "axo.connections.list",
  search: "axo.connections.search",
  execute: "axo.connections.execute",
  add: "axo.connections.add",
  remove: "axo.connections.remove",
  log: "axo.connections.log",
} as const;
export type ConnectionsMethod = (typeof CONNECTIONS_METHODS)[keyof typeof CONNECTIONS_METHODS];

/** Sent by the account to a Mac; never by a Mac. */
export const BASH_METHOD = "axo.connections.bash";

export const CONNECTIONS_LIMITS = {
  scriptWallMs: 5 * 60_000,
  callsPerScript: 100,
  concurrentCallsPerScript: 4,
  scriptBytes: 65_536,
  bashDefaultTimeoutMs: 60_000,
  bashMaxTimeoutMs: 10 * 60_000,
  bashOutputBytes: 1_048_576,
  resultBytes: 1_048_576,
  logDays: 30,
  logPage: 100,
} as const;

/** Errors a connections call may end with, beyond JSON-RPC's own. */
export const CONNECTIONS_ERRORS = {
  /** The call went out and no answer came back: it may have run. */
  outcomeUnknown: -32004,
  /** The target Mac is offline; nothing was sent. */
  hostOffline: -32005,
  /** A limit in RFD0016's table was exceeded; the message names it. */
  limitExceeded: -32020,
  notFound: -32021,
  nameTaken: -32022,
  /** The script threw; the message is its error. */
  scriptFailed: -32023,
  /** This Mac is not paired, or its relay is down. */
  notConnected: -32024,
} as const;

/** A service name: a JavaScript-safe identifier, the `x` in `codemode.x.tool()`. */
export const connectionNameSchema = z.string().regex(/^[A-Za-z_][A-Za-z0-9_]{0,63}$/);

/**
 * Apps are services Axo itself provides, each with its own sign-in and tools, reached as
 * `codemode.apps.<app>.<tool>()`. `apps` is reserved: no connection or Mac takes that name.
 */
export const APPS_NAMESPACE = "apps";
export const APPS = ["gmail", "calendar", "drive", "docs", "sheets", "slides", "contacts", "tasks", "meet", "cloud"] as const;
export type AppName = (typeof APPS)[number];
/** An app's service name, `apps.<app>`. */
export const appServiceSchema = z.string().regex(/^apps\.[a-z][a-z0-9_]{0,31}$/);
/** At most this many provider accounts per app and account. */
export const APP_ACCOUNTS_MAX = 20;
export const appAccountSchema = z.object({
  account: z.string().min(3).max(320),
  /** `needsSignIn`: the grant was refused or expired; sign in to that account again. */
  state: z.enum(["ready", "needsSignIn"]),
  lastError: z.string().max(512).nullable(),
}).strict();
export type AppAccount = z.infer<typeof appAccountSchema>;
/** Any service a tool or call belongs to: a connection, a Mac or an app. */
export const serviceSchema = z.union([connectionNameSchema, appServiceSchema]);

const sessionId = uuid;
const script = z.string().min(1).max(CONNECTIONS_LIMITS.scriptBytes);

export const connectionSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("host"),
    name: connectionNameSchema,
    hostId: uuid,
    state: z.enum(["online", "offline"]),
  }).strict(),
  z.object({
    kind: z.literal("thirdParty"),
    name: connectionNameSchema,
    url: z.url(),
    state: z.enum(["ready", "needsSignIn", "error"]),
    tools: z.number().int().nonnegative(),
    syncedAt: z.iso.datetime().nullable(),
    lastError: z.string().max(512).nullable(),
  }).strict(),
  z.object({
    kind: z.literal("app"),
    name: appServiceSchema,
    title: z.string().max(64),
    /** One sentence on what the app is for. */
    description: z.string().max(512),
    /** What a signed-in account lets Axo do, in plain words, one per line. */
    permissions: z.array(z.string().max(256)).max(32),
    /** Listed only when this Axo deployment has a client for the app's provider. `ready` once any account is. */
    state: z.enum(["ready", "needsSignIn"]),
    /** The provider accounts signed in, each named by its email; every call names one. */
    accounts: z.array(appAccountSchema).max(APP_ACCOUNTS_MAX),
    tools: z.array(connectionNameSchema).max(256),
    lastError: z.string().max(512).nullable(),
  }).strict(),
]);
export type Connection = z.infer<typeof connectionSchema>;

export const toolDefinitionSchema = z.object({
  service: serviceSchema,
  name: connectionNameSchema,
  /** The upstream server's own name for the tool, kept for display. */
  title: z.string().max(256),
  description: z.string().max(16_384),
  inputSchema: z.record(z.string(), z.unknown()),
  /** How a script calls it, such as `codemode.apps.gmail.search_messages`. */
  call: z.string().max(256),
}).strict();
export type ToolDefinition = z.infer<typeof toolDefinitionSchema>;

export const callRecordSchema = z.object({
  callId: z.string().min(1).max(64),
  at: z.iso.datetime(),
  sessionId: sessionId.nullable(),
  hostId: uuid.nullable(),
  service: serviceSchema,
  tool: z.string().min(1).max(128),
  /** The target Mac, for `bash`. */
  targetHostId: uuid.nullable(),
  durationMs: z.number().int().nonnegative(),
  outcome: z.enum(["ok", "error", "unknown"]),
  error: z.string().max(512).nullable(),
  input: z.unknown(),
}).strict();
export type CallRecord = z.infer<typeof callRecordSchema>;

export const connectionsParams = {
  [CONNECTIONS_METHODS.list]: z.object({ sessionId }).strict(),
  [CONNECTIONS_METHODS.search]: z.object({ sessionId, code: script }).strict(),
  [CONNECTIONS_METHODS.execute]: z.object({ sessionId, code: script }).strict(),
  [CONNECTIONS_METHODS.add]: z.object({ sessionId, name: connectionNameSchema, url: z.url({ protocol: /^https$/ }) }).strict(),
  /** Removes a third-party connection, or signs out of an app (`apps.<app>`). */
  [CONNECTIONS_METHODS.remove]: z.object({
    sessionId,
    name: serviceSchema,
    /** For an app: the account to sign out of. */
    account: z.string().min(3).max(320).optional(),
  }).strict(),
  [CONNECTIONS_METHODS.log]: z.object({
    sessionId,
    limit: z.number().int().min(1).max(CONNECTIONS_LIMITS.logPage).optional(),
    before: z.iso.datetime().optional(),
    /** Only calls to this service, such as `apps.gmail` or `linear`. */
    service: serviceSchema.optional(),
  }).strict(),
} as const;

export const connectionsResults = {
  [CONNECTIONS_METHODS.list]: z.object({ connections: z.array(connectionSchema) }).strict(),
  [CONNECTIONS_METHODS.search]: z.object({ result: z.unknown() }).strict(),
  [CONNECTIONS_METHODS.execute]: z.object({ result: z.unknown(), logs: z.array(z.string()) }).strict(),
  [CONNECTIONS_METHODS.add]: z.object({ connection: connectionSchema, signInUrl: z.url().nullable() }).strict(),
  [CONNECTIONS_METHODS.remove]: z.object({ removed: z.literal(true) }).strict(),
  [CONNECTIONS_METHODS.log]: z.object({ records: z.array(callRecordSchema) }).strict(),
} as const;

export type ConnectionsParams<M extends ConnectionsMethod> = z.infer<(typeof connectionsParams)[M]>;
export type ConnectionsResult<M extends ConnectionsMethod> = z.infer<(typeof connectionsResults)[M]>;

export function isConnectionsMethod(method: string): method is ConnectionsMethod {
  return Object.hasOwn(connectionsParams, method);
}

export const bashParamsSchema = z.object({
  accountId: uuid,
  callId: z.string().min(1).max(64),
  command: z.string().min(1).max(CONNECTIONS_LIMITS.scriptBytes),
  cwd: z.string().regex(/^\//).max(4096).optional(),
  timeoutMs: z.number().int().min(1).max(CONNECTIONS_LIMITS.bashMaxTimeoutMs).optional(),
}).strict();
export type BashParams = z.infer<typeof bashParamsSchema>;

export const bashResultSchema = z.object({
  exitCode: z.number().int().nullable(),
  signal: z.number().int().nullable(),
  stdout: z.string(),
  stderr: z.string(),
  stdoutTruncated: z.boolean(),
  stderrTruncated: z.boolean(),
  timedOut: z.boolean(),
  durationMs: z.number().int().nonnegative(),
}).strict();
export type BashResult = z.infer<typeof bashResultSchema>;
