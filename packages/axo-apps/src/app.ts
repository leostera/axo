import type { z } from "zod";
import type { AppName, AppTokenField, SavedFile } from "@axo/protocol";
import type { OAuthProviderName } from "./oauth/provider";

/**
 * An app: a service Axo provides itself (RFD0016, Apps), reached as `codemode.apps.<app>.<tool>()`.
 * Its tools run in the account's Durable Object and call the provider's API with the account's
 * credential (an OAuth grant, or a token the person pasted), which never leaves it.
 */

export type ProviderRequest = {
  query?: Record<string, string | string[] | undefined>;
  /** Sent as JSON. */
  body?: unknown;
  /** Sent as is, instead of `body`. */
  raw?: { contentType: string; data: string | Uint8Array<ArrayBuffer> };
  accept?: string;
  /** Extra request headers, such as Google Cloud's `x-goog-user-project`. Never `Authorization`. */
  headers?: Record<string, string>;
  /** How long the whole call may take, answer included; 30 seconds when left out. */
  timeoutMs?: number;
};

/** A provider's answer as it came: for the `request` tool, which passes any endpoint's answer back. */
export type ProviderResponse = { status: number; contentType: string; body: ArrayBuffer };

type Method = "GET" | "POST" | "PUT" | "PATCH" | "DELETE";

/** Calls the provider's API as the signed-in account. A path may also be an absolute URL on another host of the provider. */
export type ProviderApi = {
  /** The account the call acts as, as the call named it: an email, or the name a token app's account was given. */
  readonly account: string;
  /** The answer as JSON, or null if empty. */
  request(method: Method, path: string, options?: ProviderRequest): Promise<unknown>;
  requestBytes(method: Method, path: string, options?: ProviderRequest): Promise<ArrayBuffer>;
  requestRaw(method: Method, path: string, options?: ProviderRequest): Promise<ProviderResponse>;
  /**
   * A fetch for an SDK of the provider's (Octokit, grammY): the same credential, hosts, timeout
   * and outcomes as `request`, but any answer but a 401 comes back as a Response, for the SDK to
   * read as it does. The credential replaces any `Authorization` the SDK sets. A request with
   * the SDK's own abort signal ends when it does, within the longest a call may take; one
   * without, within the usual timeout.
   */
  fetch: typeof fetch;
  /**
   * Stores a file the tool fetched in the account's assets (RFD0030), so its bytes never pass
   * through the script: the script gets a file it can return, which the Mac fetches, and a link.
   * At most ASSET_LIMITS.toolSaveBytes; a refusal (quota, too large) throws ProviderError.
   */
  saveFile(file: { name: string; mimeType: string; bytes: Uint8Array<ArrayBuffer> }): Promise<SavedFile>;
};

/** What a Mac app's tool gets instead of an API: commands run on the Mac the call names (its account). */
export type MacShell = {
  /** The Mac's name as a connection, such as "studio". */
  readonly mac: string;
  /**
   * Runs one program with these arguments, each quoted for the shell, with `stdin` fed from a
   * shell builtin, so it never shows in the Mac's process list.
   */
  run(args: readonly string[], options?: { stdin?: string; timeoutMs?: number }): Promise<{ exitCode: number | null; stdout: string; stderr: string; timedOut: boolean }>;
};

export type AppTool<Input = any, Api = ProviderApi> = {
  name: string;
  description: string;
  /** The tool's own fields; every app tool also takes the `account` it acts as. */
  input: z.ZodObject;
  /** Whether running it twice is harmless. A call that got no answer is reported as may-have-run only when it is not. */
  idempotent: boolean;
  run(api: Api, input: Input): Promise<unknown>;
};

/** A tool whose `run` gets its input as its schema parses it. */
export function tool<S extends z.ZodObject>(definition: Omit<AppTool<z.infer<S>>, "input"> & { input: S }): AppTool {
  return definition as AppTool;
}

/** A tool of an app that hands it its own client (a phone app's, signed in), whose `run` gets that and its input as its schema parses it. */
export function clientTool<C>() {
  return <S extends z.ZodObject>(definition: Omit<AppTool<z.infer<S>, C>, "input"> & { input: S }): AppTool<any, C> => definition as AppTool<any, C>;
}

/** A Mac app's tool, whose `run` gets the Mac's shell and its input as its schema parses it. */
export function macTool<S extends z.ZodObject>(definition: Omit<AppTool<z.infer<S>, MacShell>, "input"> & { input: S }): AppTool<any, MacShell> {
  return definition as AppTool<any, MacShell>;
}

type AppBase = {
  name: AppName;
  title: string;
  /** One sentence on what the app is for, shown on its page. */
  description: string;
  /** What a signed-in account lets Axo do, in plain words, shown on its page. */
  permissions: readonly string[];
  /** Who makes the service, as shown: "Google", "Hetzner". */
  providerTitle: string;
  /** What kind of app it is, for filtering. */
  category: "communication" | "productivity" | "files" | "developer" | "finance" | "home" | "media" | "security" | "health";
};

/** An app whose tools call its service's HTTP API with the account's credential. */
export type HttpApp = AppBase & {
  apiOrigin: string;
  /**
   * The hosts a call may reach with the app's credential, `apiOrigin`'s first; `*.googleapis.com`
   * matches any of its subdomains. No call ever sends a credential anywhere else.
   */
  hosts: readonly string[];
  /** The API's reference, named in the `request` tool's description. */
  reference: string;
  /** The app's named tools; every app also has `request`, for any endpoint of its API. */
  tools: readonly AppTool[];
  /**
   * For a service that answers errors with HTTP 200 (Withings' `status`, Slack's `ok: false`):
   * reads a JSON answer and says whether it is one. `unauthorized` is treated as a 401 (the grant
   * is renewed once and the call sent again); `message` fails the call as the service's error.
   * Applies to every call, `request` included.
   */
  answerError?(json: unknown): AnswerError | null;
};

export type AnswerError = { unauthorized: true } | { unauthorized?: false; status: number; message: string };

/** An app the person signs in to with Axo's own OAuth client for its provider. */
export type OAuthApp = HttpApp & {
  signIn: "oauth";
  /** Whose OAuth client it signs in with (oauth-provider.ts); several apps may share one (Google's). */
  provider: OAuthProviderName;
  /** Asked for at sign-in. */
  scopes: readonly string[];
  /** Without these the grant is useless, and the sign-in fails instead of landing. */
  requiredScopes: readonly string[];
};

/** A request as it is about to go out, for a credential to be put on it. */
export type OutgoingRequest = { method: string; url: URL; body: string | Uint8Array<ArrayBuffer> | undefined; contentType: string | null };
/** The credential's part of a request: headers no call may set itself, and a replaced URL or body. */
export type Authorized = { headers: Record<string, string>; url?: URL; body?: string };

/** What the person pastes to add an account to a token app, and how it goes on each request. */
export type TokenSignIn = {
  /** The service's page where the person creates the token. */
  helpUrl: string;
  fields: readonly AppTokenField[];
  /** Whether the person names each account, because the service has no name for it (a Hetzner project token). */
  named: boolean;
  /**
   * Puts the credential on one request: its headers, or for a service that wants it elsewhere
   * (Telegram's in the path) or signs each request (Kraken), a changed URL or body too.
   */
  authorize(credential: Readonly<Record<string, string>>, request: OutgoingRequest): Authorized | Promise<Authorized>;
  /**
   * Checks the credential with one read call before it is stored, and returns the service's
   * name for the account (an email, a login), or null when the person names it. Throws a
   * ProviderError when the service refuses it.
   */
  identify(api: ProviderApi, fields: Readonly<Record<string, string>>): Promise<string | null>;
  /**
   * A sign-in that ends on one of the person's Macs, for a service that sends sign-ins back only
   * to `http://localhost` (Kraken's public client): axod opens the sign-in page and waits on the
   * redirect port, and the Worker, which keeps the PKCE verifier, finishes it and gets the token
   * fields the person would otherwise paste.
   */
  mac?: MacSignIn;
};

/** A token app's sign-in on the person's Mac (TokenSignIn.mac). */
export type MacSignIn = {
  /** The button, such as "Sign in with Kraken". */
  title: string;
  /** What the person chooses the credential may do; the first is the default. */
  presets: ReadonlyArray<{ id: string; label: string; description: string }>;
  /** The redirect ports the service registered, tried in order, and the redirect's path. */
  ports: readonly number[];
  path: string;
  /** The sign-in page, with every parameter but `redirect_uri`, which axod adds. */
  authorizeUrl(preset: string, state: string, challenge: string): string;
  /**
   * Redeems the code and returns the token fields (as TokenSignIn.fields), when they stop
   * working, and what `revoke` needs later, sealed with them.
   */
  complete(input: { code: string; state: string; redirectUri: string; verifier: string; preset: string }, fetcher: typeof fetch, now: number):
    Promise<{ fields: Record<string, string>; expiresAt: number | null; revocation: unknown }>;
  /** Undoes the sign-in at the service when the account is removed; best effort. */
  revoke?(revocation: unknown, fields: Readonly<Record<string, string>>, fetcher: typeof fetch, now: number): Promise<void>;
};

/** An app the person adds an account to by pasting a token the service issued them. */
export type TokenApp = HttpApp & { signIn: "token"; provider: string; token: TokenSignIn };

/**
 * An app the person signs in to with a code they enter at the provider (a device sign-in):
 * ChatGPT, whose client (Codex's) only lets a server sign in that way.
 */
export type DeviceApp = HttpApp & { signIn: "device"; provider: "openai" };

/**
 * An app that runs a program on one of the account's Macs (1Password's `op`), signed in there
 * already. Its accounts are the Macs; nothing is stored in the cloud. Its tools run with the
 * Mac's shell, and it has no `request`: its own catch-all tool runs any of the program's commands.
 */
export type MacApp = AppBase & {
  signIn: "mac";
  provider: string;
  /** What the person sets up on a Mac first, in plain words, shown on the app's page. */
  setup: string;
  /** The program's documentation. */
  reference: string;
  tools: readonly AppTool<any, MacShell>[];
};

/** The API client a phone app signs in with: an ID and hash the person registered with the service (my.telegram.org). */
export type PhoneClient = { apiId: number; apiHash: string };

/**
 * Where a phone sign-in stands: a code was sent (to the person's Telegram app, or by SMS), the
 * account has a password to enter too, or it is done. `pending` is the service's state between
 * steps, which the gateway keeps sealed and hands back.
 */
export type PhoneStep =
  | { step: "code"; pending: string; via: "app" | "sms" }
  | { step: "password"; pending: string; hint: string | null }
  | { step: "done"; session: string; account: string };

/** What went wrong in a phone app's call, as the gateway acts on it. */
export type PhoneFailure =
  /** The session is over (the person ended it on another device): only signing in again helps. */
  | { kind: "ended" }
  /** The service refused the call, which did not run. */
  | { kind: "refused"; message: string }
  /** The call may have reached the service, and no answer came back. */
  | { kind: "unknown" };

/**
 * A phone app's sign-in and sessions, speaking the service's own protocol (Telegram's MTProto,
 * through GramJS). The person's own API client signs in as a new device of theirs; the session
 * it ends with is the account's credential. Each call opens the session and closes it again.
 * A step the person got wrong (a code that is not right, a password) throws PhoneRefused.
 */
export type PhoneSignIn<Api = unknown> = {
  /** Where the person registers the API client. */
  consoleUrl: string;
  /** How to, in plain words, shown with the form. */
  clientHelp: string;
  sendCode(client: PhoneClient, phone: string): Promise<PhoneStep>;
  enterCode(client: PhoneClient, pending: string, phone: string, code: string): Promise<PhoneStep>;
  enterPassword(client: PhoneClient, pending: string, password: string): Promise<PhoneStep>;
  /** Opens the session for one call; `close` gives back the session as it is then (it may have moved). */
  open(client: PhoneClient, session: string): Promise<{ api: Api; close(): Promise<string> }>;
  /** Ends the session at the service, when the account is removed. Best effort. */
  logOut(client: PhoneClient, session: string): Promise<void>;
  /** What a call's error means. */
  failure(error: unknown): PhoneFailure;
};

/** A step of a phone sign-in the person got wrong, said in plain words; the sign-in may go on. */
export class PhoneRefused extends Error {
  /** Whether the sign-in is over and must start again (an expired code). */
  constructor(message: string, readonly over = false) {
    super(message);
  }
}

/**
 * An app the person signs in to with their phone number, as a new device of theirs (Telegram),
 * with an API client of their own. Its tools get the service's client, signed in.
 */
export type PhoneApp = AppBase & {
  signIn: "phone";
  provider: string;
  reference: string;
  phone: PhoneSignIn<any>;
  tools: readonly AppTool<any, any>[];
};

/** How linking starts: a QR code the person scans, or a pairing code for their number that they type into their phone. */
export type LinkStart = { method: "qr" } | { method: "code"; phone: string };

/** Where linking stands, as the device answers it. */
export type LinkState =
  | { state: "connecting" }
  | { state: "qr"; qr: string }
  | { state: "code"; code: string }
  | { state: "done"; account: string }
  | { state: "failed"; error: string };

/** What a linked device answers a tool call with: the result, or that the service unlinked it (only linking again helps). */
export type LinkedOutcome = { result: unknown } | { unlinked: true } | { error: string };

/**
 * One linked device of the person's (WhatsApp's), kept by the gateway in a Durable Object of its
 * own, connected to the service and caching what it is sent. Its tools run there, against that cache.
 */
export type LinkedDevice = {
  startLink(start: LinkStart): Promise<LinkState>;
  linkState(): Promise<LinkState>;
  /** Logs the device out at the service and forgets everything it kept. Best effort. */
  unlink(): Promise<void>;
  run(tool: string, input: Record<string, unknown>): Promise<LinkedOutcome>;
};

/**
 * An app Axo joins as a linked device of the person's account (WhatsApp), the way a desktop app
 * does: the person scans a QR code with their phone, or types a pairing code into it. There is no
 * client to register; the account's name is its phone number.
 */
export type LinkedApp = AppBase & {
  signIn: "linked";
  provider: string;
  reference: string;
  /** Where the service explains linked devices, shown with the linking form. */
  helpUrl: string;
  tools: readonly AppTool<any, any>[];
};

export type AppDefinition = OAuthApp | TokenApp | DeviceApp | MacApp | PhoneApp | LinkedApp;

/** The provider refused the call: it did not run. */
export class ProviderError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

/**
 * The provider said the access token is no good: nothing ran, so the call may be sent again once
 * the grant is renewed. Thrown for a 401, and by an app whose service says so otherwise (Withings
 * answers HTTP 200 with status 401).
 */
export class Unauthorized extends Error {}

/** The call went out and no answer came back: it may have run. */
export class ProviderOutcomeUnknown extends Error {}

/** Whether a grant may be sent to `url`: https, on one of the app's hosts. */
export function allowedUrl(definition: Pick<HttpApp, "hosts">, url: URL): boolean {
  if (url.protocol !== "https:" || url.username || url.password || url.port) return false;
  return definition.hosts.some((host) =>
    host.startsWith("*.") ? url.hostname.endsWith(host.slice(1)) && url.hostname.length > host.length - 1 : url.hostname === host);
}
