import { Keyring } from "./keys";

/** The web app's origin: where sign-in returns to, and the only origin a cookie may act from. */
export const APP_ORIGIN = "https://axo.leostera.dev";

/** What the Worker needs to run sign-in. */
export type AuthEnvironment = {
  /** The Cloudflare OAuth client (https://dash.cloudflare.com/profile/api-tokens → OAuth). */
  OAUTH_CLIENT_ID?: string;
  OAUTH_CLIENT_SECRET?: string;
  /** Key 0 of the Worker's keys (RFD0076); at least 32 bytes. */
  SESSION_SECRET?: string;
  /** The current key, and the previous one while it is rotated out (RFD0076, Keyring.parse). */
  SECRET_KEYS?: string;
};

export type AuthConfiguration = {
  readonly clientId: string;
  readonly clientSecret: string | null;
  /** What every hash and seal the Worker makes is made with. */
  readonly keys: Keyring;
};

/** The configuration, or null if sign-in is not set up: callers answer 503, never half-work. */
export function parseAuthConfiguration(env: AuthEnvironment): AuthConfiguration | null {
  const keys = Keyring.parse(env);
  if (!env.OAUTH_CLIENT_ID || !keys) return null;
  return { clientId: env.OAUTH_CLIENT_ID, clientSecret: env.OAUTH_CLIENT_SECRET || null, keys };
}
