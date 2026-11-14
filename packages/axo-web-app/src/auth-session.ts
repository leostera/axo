/** Parsed `GET /api/auth/me`; cached browser identity never substitutes for this response. */
export interface AuthenticatedSession {
  authenticated: true;
  accountId: string;
  profile: { email: string | null; name: string | null };
  expiresAt: string;
}
function object(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}
export function parseAuthenticatedSession(value: unknown): AuthenticatedSession {
  const session = object(value);
  const profile = object(session?.profile);
  if (!session || session.authenticated !== true || typeof session.accountId !== "string"
    || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(session.accountId)
    || typeof session.expiresAt !== "string" || !Number.isFinite(Date.parse(session.expiresAt)) || !profile
    || !(profile.email === null || typeof profile.email === "string")
    || !(profile.name === null || typeof profile.name === "string")) throw new Error("Invalid Axo sign-in response");
  return { authenticated: true, accountId: session.accountId, expiresAt: session.expiresAt,
    profile: { email: profile.email, name: profile.name } };
}
