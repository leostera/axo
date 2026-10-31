import type { z } from "zod";
import type { AppName } from "@axo/protocol";

/**
 * An app: a service Axo provides itself (RFD0016, Apps), reached as `codemode.apps.<app>.<tool>()`.
 * Its tools run in the account's Durable Object and call the provider's API with the account's
 * grant, which never leaves it.
 */

export type ProviderRequest = {
  query?: Record<string, string | string[] | undefined>;
  /** Sent as JSON. */
  body?: unknown;
  /** Sent as is, instead of `body`. */
  raw?: { contentType: string; data: string | Uint8Array<ArrayBuffer> };
  accept?: string;
};

type Method = "GET" | "POST" | "PUT" | "PATCH" | "DELETE";

/** Calls the provider's API as the signed-in account. A path may also be an absolute URL on another host of the provider. */
export type ProviderApi = {
  /** The answer as JSON, or null if empty. */
  request(method: Method, path: string, options?: ProviderRequest): Promise<unknown>;
  requestBytes(method: Method, path: string, options?: ProviderRequest): Promise<ArrayBuffer>;
};

export type AppTool<Input = any> = {
  name: string;
  description: string;
  /** The tool's own fields; every app tool also takes the `account` it acts as. */
  input: z.ZodObject;
  /** Whether running it twice is harmless. A call that got no answer is reported as may-have-run only when it is not. */
  idempotent: boolean;
  run(api: ProviderApi, input: Input): Promise<unknown>;
};

export type AppDefinition = {
  name: AppName;
  title: string;
  provider: "google";
  /** Asked for at sign-in. */
  scopes: readonly string[];
  /** Without these the grant is useless, and the sign-in fails instead of landing. */
  requiredScopes: readonly string[];
  apiOrigin: string;
  tools: readonly AppTool[];
};

/** The provider refused the call: it did not run. */
export class ProviderError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

/** The call went out and no answer came back: it may have run. */
export class ProviderOutcomeUnknown extends Error {}
