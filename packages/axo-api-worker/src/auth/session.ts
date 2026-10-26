import { z } from "zod";
import { fromBase64Url, hmac, randomToken } from "./crypto";

/**
 * A session token is `axo1.<account id>.<secret>`: the account says which Durable Object to ask,
 * the 256-bit secret proves possession. The Worker keeps only a keyed hash of the secret, so a
 * copy of the database is not a set of sign-ins, and revoking is deleting the hash.
 */
export type SessionToken = {
  readonly accountId: string;
  readonly secret: string;
};

const SECRET_BYTES = 32;

export function newSessionToken(accountId: string): SessionToken {
  return { accountId, secret: randomToken(SECRET_BYTES) };
}

export function formatSessionToken(token: SessionToken): string {
  return `axo1.${token.accountId}.${token.secret}`;
}

export function parseSessionToken(text: string): SessionToken | null {
  const parts = text.split(".");
  if (parts.length !== 3 || parts[0] !== "axo1") return null;
  const [, accountId, secret] = parts;
  if (!z.uuid().safeParse(accountId).success) return null;
  try {
    if (fromBase64Url(secret!).byteLength !== SECRET_BYTES) return null;
  } catch {
    return null;
  }
  return { accountId: accountId!, secret: secret! };
}

export function sessionDigest(sessionSecret: string, token: SessionToken): Promise<string> {
  return hmac(sessionSecret, `session\0${token.accountId}\0${token.secret}`);
}

/** How long each kind of client stays signed in. */
export const SESSION_LIFETIME_MS = { web: 30 * 24 * 3600_000, native: 90 * 24 * 3600_000 } as const;
export type SessionKind = keyof typeof SESSION_LIFETIME_MS;

export const SESSION_COOKIE = "__Host-axo_session";

/** The value of cookie `name`, or null. */
export function cookieValue(header: string | null, name: string): string | null {
  if (!header) return null;
  for (const part of header.split(";")) {
    const separator = part.indexOf("=");
    if (separator >= 0 && part.slice(0, separator).trim() === name) return part.slice(separator + 1).trim() || null;
  }
  return null;
}

export function setCookie(name: string, value: string, maxAgeSeconds: number): string {
  return `${name}=${value}; Path=/; Max-Age=${maxAgeSeconds}; Secure; HttpOnly; SameSite=Lax`;
}

export function clearCookie(name: string): string {
  return setCookie(name, "", 0);
}
