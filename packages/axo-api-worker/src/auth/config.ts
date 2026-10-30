import { requireSecret } from "./crypto";

/** The web app's origin: where sign-in returns to, and the only origin a cookie may act from. */
export const APP_ORIGIN = "https://axo.leostera.dev";

/** What the Worker needs to run sign-in. */
export type AuthEnvironment = {
  /** The Cloudflare OAuth client (https://dash.cloudflare.com/profile/api-tokens → OAuth). */
  OAUTH_CLIENT_ID?: string;
  OAUTH_CLIENT_SECRET?: string;
  /** Keys every secret the Worker derives or seals; at least 32 bytes. */
  SESSION_SECRET?: string;
};

export type AuthConfiguration = {
  readonly clientId: string;
  readonly clientSecret: string | null;
  readonly sessionSecret: string;
};

/** The configuration, or null if sign-in is not set up: callers answer 503, never half-work. */
export function parseAuthConfiguration(env: AuthEnvironment): AuthConfiguration | null {
  if (!env.OAUTH_CLIENT_ID || !env.SESSION_SECRET) return null;
  try {
    return {
      clientId: env.OAUTH_CLIENT_ID,
      clientSecret: env.OAUTH_CLIENT_SECRET || null,
      sessionSecret: requireSecret(env.SESSION_SECRET),
    };
  } catch {
    return null;
  }
}
