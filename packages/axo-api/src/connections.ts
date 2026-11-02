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
/**
 * A loopback sign-in on a Mac (axo-relay's signin.rs): axod opens the sign-in page in the
 * person's browser, waits for the redirect to `http://localhost:<port><path>`, and answers with
 * the code. For services that send sign-ins back only to localhost (Kraken's public client).
 */
export const SIGN_IN_METHOD = "axo.connections.signIn";
/** What the Mac answers a sign-in with: the redirect it used, and the code or the service's error. */
export const signInResultSchema = z.object({
  redirectUri: z.string().regex(/^http:\/\/localhost:\d{4,5}\/[A-Za-z0-9/_.-]*$/),
  code: z.string().min(1).max(4096).optional(),
  error: z.string().max(256).optional(),
  errorDescription: z.string().max(1024).optional(),
}).strict();

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
 * What the person calls a connection they add, as typed: "emdash: leostera.com". Scripts reach it
 * by its slug (connectionSlug), the connection's `name`.
 */
export const connectionTitleSchema = z.string().trim().min(1).max(100);

/**
 * The name a script calls a connection by, made from what the person typed: lowercase letters,
 * digits and underscores, so `codemode.<name>` is plain JavaScript ("emdash: leostera.com" is
 * emdash_leostera_com). Null when nothing in it is a letter or digit.
 */
export function connectionSlug(title: string): string | null {
  const slug = title.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase()
    .replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 64).replace(/_+$/, "");
  if (!slug) return null;
  return /^[0-9]/.test(slug) ? `_${slug}`.slice(0, 64) : slug;
}

/**
 * Apps are services Axo itself provides, each with its own sign-in and tools, reached as
 * `codemode.apps.<app>.<tool>()`. `apps` is reserved: no connection or Mac takes that name.
 */
export const APPS_NAMESPACE = "apps";
export const APPS = ["gmail", "calendar", "drive", "docs", "sheets", "slides", "contacts", "tasks", "meet", "cloud", "hetzner", "chatgpt", "onepassword", "octopus", "wise", "telegram", "kraken", "github", "discord", "unifi", "spotify", "withings"] as const;
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
/** A field a person fills in to add an account to a token app, such as Hetzner's API token. */
export const appTokenFieldSchema = z.object({
  name: connectionNameSchema,
  /** As shown: "API token". */
  label: z.string().max(64),
  /** Where to find it, in plain words. */
  help: z.string().max(256),
  /** A secret is never shown again once added. */
  secret: z.boolean(),
}).strict();
export type AppTokenField = z.infer<typeof appTokenFieldSchema>;
/**
 * The OAuth client an `oauth` app signs in with: one the person registered with the provider
 * (`provider` names it, such as "github"; one client serves every app of a provider), with
 * `redirectUri` as its redirect URI. Its ID and secret are entered on the app's page and kept,
 * sealed, in the account's gateway, where they can be replaced at any time. `ready`: one is set
 * up. `consoleUrl`: the provider's page for registering one.
 */
export const appOAuthClientSchema = z.object({
  provider: z.string().regex(/^[a-z][a-z0-9_]{0,31}$/),
  ready: z.boolean(),
  consoleUrl: z.url({ protocol: /^https$/ }).max(2048),
  redirectUri: z.url({ protocol: /^https$/ }).max(2048),
}).strict();
export type AppOAuthClient = z.infer<typeof appOAuthClientSchema>;
/** What setting up an OAuth app's client sends, once; the secret is never shown again. */
export const appClientRequestSchema = z.object({
  clientId: z.string().min(1).max(512).regex(/^[^\s]+$/, "no spaces or line breaks"),
  clientSecret: z.string().min(1).max(2048).regex(/^[^\s]+$/, "no spaces or line breaks"),
}).strict();
export type AppClientRequest = z.infer<typeof appClientRequestSchema>;
/**
 * How a person adds an account to an app. `oauth`: Add account opens the provider's sign-in,
 * once its client is set up (`client`; left out by Workers from before clients were the person's).
 * `token`: the person pastes what the service issued them (an API token, a key), which Axo seals
 * and never shows again; `named` says the person names the account, since the service does not.
 * `device`: Add account shows a code the person enters at the provider (ChatGPT), while the page
 * asks Axo whether they have. `mac`: the app runs a program on the account's Macs (1Password's
 * CLI), which are its accounts; `setup` says what to set up on a Mac first. `phone`: the person
 * signs in with their phone number and the code the service sends, as a new device of theirs
 * (Telegram), with an API client they register at `consoleUrl` first (`clientReady` once set up).
 */
/** A token app's sign-in on a Mac: the button, and what the person chooses the credential may do. */
export const appMacSignInOfferSchema = z.object({
  title: z.string().min(1).max(64),
  presets: z.array(z.object({ id: connectionNameSchema, label: z.string().min(1).max(64), description: z.string().max(256) }).strict()).min(1).max(8),
}).strict();
export const appSignInSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("oauth"), client: appOAuthClientSchema.optional() }).strict(),
  z.object({ kind: z.literal("device") }).strict(),
  z.object({ kind: z.literal("mac"), setup: z.string().max(1024), helpUrl: z.url({ protocol: /^https$/ }).max(2048) }).strict(),
  z.object({ kind: z.literal("phone"), consoleUrl: z.url({ protocol: /^https$/ }).max(2048), clientHelp: z.string().max(1024), clientReady: z.boolean() }).strict(),
  z.object({
    kind: z.literal("token"),
    /** The service's page where the person creates the token. */
    helpUrl: z.url({ protocol: /^https$/ }).max(2048),
    named: z.boolean(),
    fields: z.array(appTokenFieldSchema).min(1).max(4),
    /** A sign-in that ends on one of the account's Macs, offered beside pasting a token (Kraken's). */
    mac: appMacSignInOfferSchema.optional(),
  }).strict(),
]);
export type AppSignIn = z.infer<typeof appSignInSchema>;
/** What adding a token app account sends: the account's name when the person names it, and the fields. */
export const appTokenRequestSchema = z.object({
  account: z.string().min(3).max(64).regex(/^[a-z0-9][a-z0-9._@-]*$/, "use lowercase letters, digits, dots, dashes and @").optional(),
  fields: z.record(connectionNameSchema, z.string().min(1).max(8192)),
}).strict();
export type AppTokenRequest = z.infer<typeof appTokenRequestSchema>;
/** A device sign-in as the web app polls it: the code to enter and where, until it is done or failed. */
export const appDeviceSignInSchema = z.discriminatedUnion("state", [
  z.object({
    state: z.literal("pending"),
    userCode: z.string().min(1).max(64),
    verificationUrl: z.url({ protocol: /^https$/ }).max(2048),
    intervalSeconds: z.number().int().min(1).max(60),
    expiresAt: z.iso.datetime(),
  }).strict(),
  z.object({ state: z.literal("done"), account: z.string().min(3).max(320) }).strict(),
  z.object({ state: z.literal("failed"), error: z.string().max(512) }).strict(),
]);
export type AppDeviceSignIn = z.infer<typeof appDeviceSignInSchema>;
/** What starting a sign-in on a Mac sends: which Mac, the preset chosen, and the account's name when the person names it. */
export const appMacSignInRequestSchema = z.object({
  mac: connectionNameSchema,
  preset: connectionNameSchema,
  account: z.string().min(3).max(64).regex(/^[a-z0-9][a-z0-9._@-]*$/, "use lowercase letters, digits, dots, dashes and @").optional(),
}).strict();
export type AppMacSignInRequest = z.infer<typeof appMacSignInRequestSchema>;
/** A sign-in on a Mac as the web app polls it: waiting for the person in their browser, done, or failed. */
export const appMacSignInSchema = z.discriminatedUnion("state", [
  z.object({ state: z.literal("pending"), mac: connectionNameSchema, expiresAt: z.iso.datetime() }).strict(),
  z.object({ state: z.literal("done"), account: z.string().min(3).max(320), expiresAt: z.iso.datetime().nullable() }).strict(),
  z.object({ state: z.literal("failed"), error: z.string().max(512) }).strict(),
]);
export type AppMacSignIn = z.infer<typeof appMacSignInSchema>;
/** A step of a phone sign-in: the number, then the code the service sent, then a password if the account has one. */
export const appPhoneSignInRequestSchema = z.discriminatedUnion("step", [
  z.object({ step: z.literal("start"), phone: z.string().trim().regex(/^\+?[\d ()-]{6,24}$/, "enter the number with its country code") }).strict(),
  z.object({ step: z.literal("code"), flow: z.string().min(16).max(64), code: z.string().trim().regex(/^\d{4,8}$/, "the code is digits") }).strict(),
  z.object({ step: z.literal("password"), flow: z.string().min(16).max(64), password: z.string().min(1).max(256) }).strict(),
]);
export type AppPhoneSignInRequest = z.infer<typeof appPhoneSignInRequestSchema>;
/**
 * Where a phone sign-in stands after a step: the code to enter (`via` the service's own app or
 * SMS), the account's password, done, or failed and over. `error` on a step that goes on says what
 * the person got wrong in the last one (a code that is not right).
 */
export const appPhoneSignInSchema = z.discriminatedUnion("state", [
  z.object({ state: z.literal("code"), flow: z.string().min(16).max(64), via: z.enum(["app", "sms"]), error: z.string().max(512).optional() }).strict(),
  z.object({ state: z.literal("password"), flow: z.string().min(16).max(64), hint: z.string().max(256).nullable(), error: z.string().max(512).optional() }).strict(),
  z.object({ state: z.literal("done"), account: z.string().min(3).max(320) }).strict(),
  z.object({ state: z.literal("failed"), error: z.string().max(512) }).strict(),
]);
export type AppPhoneSignIn = z.infer<typeof appPhoneSignInSchema>;
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
    /** What the person called it; null when that is its name (and from a Worker one release older). */
    title: connectionTitleSchema.nullable().default(null),
    url: z.url(),
    state: z.enum(["ready", "needsSignIn", "error"]),
    tools: z.number().int().nonnegative(),
    /** The server's icon, an https URL the browser loads for its tile; null until found, or when it has none. */
    icon: z.url({ protocol: /^https$/ }).max(2048).nullable().default(null),
    syncedAt: z.iso.datetime().nullable(),
    lastError: z.string().max(512).nullable(),
  }).strict(),
  z.object({
    kind: z.literal("app"),
    name: appServiceSchema,
    title: z.string().max(64),
    // What an app's page shows. A reader takes a listing without them, from a Worker one release
    // older than it (as while a deploy reaches the account's Durable Object), as empty.
    /** One sentence on what the app is for. */
    description: z.string().max(512).default(""),
    /** Who makes the service, as shown: "Google". */
    provider: z.string().max(64).default(""),
    /** What kind of app it is, for filtering: "communication", "productivity", "files", "developer", ... */
    category: z.string().regex(/^[a-z][a-z-]{0,31}$/).or(z.literal("")).default(""),
    /** What a signed-in account lets Axo do, in plain words, one per line. */
    permissions: z.array(z.string().max(256)).max(32).default([]),
    /** How Add account works. A listing from an older Worker has only OAuth apps. */
    signIn: appSignInSchema.default({ kind: "oauth" }),
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
  /** `name` is what to call it, any text; the connection's name is its slug (connectionSlug). */
  [CONNECTIONS_METHODS.add]: z.object({ sessionId, name: connectionTitleSchema, url: z.url({ protocol: /^https$/ }) }).strict(),
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
