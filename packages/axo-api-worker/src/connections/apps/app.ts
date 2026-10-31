import type { z } from "zod";
import type { AppName, AppTokenField } from "@axo/protocol";

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
  category: "communication" | "productivity" | "files" | "developer" | "finance" | "home" | "media" | "security";
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
};

/** An app the person signs in to with Axo's own OAuth client for its provider. */
export type OAuthApp = HttpApp & {
  signIn: "oauth";
  provider: "google";
  /** Asked for at sign-in. */
  scopes: readonly string[];
  /** Without these the grant is useless, and the sign-in fails instead of landing. */
  requiredScopes: readonly string[];
};

/** What the person pastes to add an account to a token app, and how it goes on each request. */
export type TokenSignIn = {
  /** The service's page where the person creates the token. */
  helpUrl: string;
  fields: readonly AppTokenField[];
  /** Whether the person names each account, because the service has no name for it (a Hetzner project token). */
  named: boolean;
  /** The headers that carry the credential on one request. */
  authorize(credential: Readonly<Record<string, string>>): Record<string, string>;
  /**
   * Checks the credential with one read call before it is stored, and returns the service's
   * name for the account (an email, a login), or null when the person names it. Throws a
   * ProviderError when the service refuses it.
   */
  identify(api: ProviderApi, fields: Readonly<Record<string, string>>): Promise<string | null>;
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

export type AppDefinition = OAuthApp | TokenApp | DeviceApp | MacApp;

/** The provider refused the call: it did not run. */
export class ProviderError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

/** The call went out and no answer came back: it may have run. */
export class ProviderOutcomeUnknown extends Error {}

/** Whether a grant may be sent to `url`: https, on one of the app's hosts. */
export function allowedUrl(definition: Pick<HttpApp, "hosts">, url: URL): boolean {
  if (url.protocol !== "https:" || url.username || url.password || url.port) return false;
  return definition.hosts.some((host) =>
    host.startsWith("*.") ? url.hostname.endsWith(host.slice(1)) && url.hostname.length > host.length - 1 : url.hostname === host);
}
