import { uuid } from "@axo/protocol";
import { z } from "zod";

/**
 * What an open socket is signed in with, and how long it may go before the account confirms it
 * again (RFD0071). A socket outlives its upgrade by days; without this, signing out or revoking a
 * Mac would end neither its sockets nor what they can do.
 *
 * Every client socket holds a lease until `leaseUntil`. Past it, before the object that holds the
 * socket reads a frame from it or writes one to it, it asks the account whether the sign-in still
 * stands. If it does the lease is renewed; if not, or if the account cannot be asked, the socket
 * closes. So nothing goes in or out of a socket SIGN_IN_LEASE_MS after its sign-in ended. No alarm
 * is set for a lease (RFD0031): a socket nothing reaches leaks nothing.
 */
export const SIGN_IN_LEASE_MS = 5 * 60 * 1000;

export const signInSchema = z.discriminatedUnion("kind", [
  /** A person's session: the HMAC the account keeps of its token. */
  z.object({ kind: z.literal("session"), digest: z.string().min(1).max(128) }).strict(),
  /** A paired Mac's credential, which stands while the Mac is linked with it. */
  z.object({ kind: z.literal("host"), hostId: uuid, credentialId: uuid }).strict(),
]);
export type SignIn = z.infer<typeof signInSchema>;

/** The header the Worker passes a socket's sign-in in, to the object that will hold the socket. */
export const SIGN_IN_HEADER = "X-Axo-Sign-In";

export function signInHeader(signIn: SignIn): Record<string, string> {
  return { [SIGN_IN_HEADER]: JSON.stringify(signIn) };
}

export function signInOf(request: Request): SignIn | null {
  try {
    const parsed = signInSchema.safeParse(JSON.parse(request.headers.get(SIGN_IN_HEADER) ?? ""));
    return parsed.success ? parsed.data : null;
  } catch {
    return null;
  }
}

/**
 * The lease's length: SIGN_IN_LEASE_MS, or a shorter one the Worker's `SIGN_IN_LEASE_MS` variable
 * sets (tests do, to see a lease end). Nothing can make it longer.
 */
export function signInLeaseMs(env: object): number {
  const configured = Number((env as { SIGN_IN_LEASE_MS?: string }).SIGN_IN_LEASE_MS);
  return Number.isFinite(configured) && configured > 0 ? Math.min(configured, SIGN_IN_LEASE_MS) : SIGN_IN_LEASE_MS;
}

/** A lease from `now`: never past the sign-in's own end. */
export function leaseFrom(now: number, expiresAt: number, leaseMs: number): number {
  return Math.min(expiresAt, now + leaseMs);
}

/**
 * The account's answer for one sign-in: whether it stands, and, for a socket on a host's HostDO,
 * whether that host is still the account's.
 */
export type ConfirmSignIn = (signIn: SignIn, onHost?: string) => Promise<boolean>;
