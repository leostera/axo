import type { OAuthClient } from "@axo/apps";

/**
 * Google's client from the Worker's environment (`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`), from
 * before OAuth clients were the person's, stored in the account's gateway. Used only while an
 * account has none of its own; it goes once the account manager stops reading it.
 */
export type GoogleClient = OAuthClient;

export function googleClient(env: { GOOGLE_CLIENT_ID?: string; GOOGLE_CLIENT_SECRET?: string }): GoogleClient | null {
  if (!env.GOOGLE_CLIENT_ID || !env.GOOGLE_CLIENT_SECRET) return null;
  return { clientId: env.GOOGLE_CLIENT_ID, clientSecret: env.GOOGLE_CLIENT_SECRET };
}
