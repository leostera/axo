import {
  hostPairingCreateResultSchema,
  hostPairingRedeemRequestSchema,
  hostPairingRedeemResultSchema,
} from "@axo/protocol/v1";
import { hmac } from "./crypto";
import { attempt, requestSource } from "./rate-limit";
import { requireAccount, type AuthExports } from "./account-access";
import type { AuthEnvironment } from "./config";

const PAIRING_LIFETIME_MS = 10 * 60 * 1000;
/**
 * Redemptions guess at codes, so they are limited per source and in all. A code has 40 bits and
 * lives 10 minutes: at the global limit, all the guesses of its lifetime have a chance under 1 in
 * 10^7 of finding it. The global limit is high so that it takes many sources to reach it, and
 * only a well-formed redemption, which its source's limit allowed, counts against it.
 * Issuance is the account's (AxoAccountManager.createPairing): 3 pending, 5 an hour.
 */
const MAX_REDEMPTIONS_PER_MINUTE = 6_000;
const MAX_REDEMPTIONS_PER_SOURCE_PER_MINUTE = 8;
const MAX_REDEMPTION_BODY_BYTES = 4_096;
const CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const PAIRING_CHARSET_SIZE = 32;

type PairingEnvironment = AuthEnvironment;

export async function createHostPairing(
  request: Request,
  env: PairingEnvironment,
  exports: AuthExports,
): Promise<Response> {
  if (request.method !== "POST") return methodNotAllowed("POST");
  const caller = await requireAccount(request, env, exports, "change");
  if (caller instanceof Response) return caller;
  const accountId = caller.accountId;
  if (!env.SESSION_SECRET || !exports.AxoAccountManager ||
      !exports.AxoPairingIndex || !exports.AxoPairingRateLimit) return unavailable();

  const account = exports.AxoAccountManager.getByName(accountId);
  if (!account.createPairing || !account.cancelPairing) return unavailable();
  const now = Date.now();
  const expiresAt = now + PAIRING_LIFETIME_MS;
  const routeIndexExpiresAt = expiresAt + 24 * 60 * 60 * 1000;

  for (let attempt = 0; attempt < 8; attempt++) {
    const code = generatePairingCode();
    const verifier = await hmac(env.SESSION_SECRET, `pairing-code\0${code}`);
    const pairingId = crypto.randomUUID();

    let status: "created" | "collision" | "limited";
    try {
      status = await account.createPairing(verifier, pairingId, now, expiresAt);
    } catch {
      return unavailable();
    }
    if (status === "limited") return rateLimited();
    if (status === "collision") continue;

    const index = exports.AxoPairingIndex.getByName(pairingShard(verifier));
    try {
      const reserved = await index.reserve(verifier, accountId, pairingId, routeIndexExpiresAt, now);
      if (!reserved) {
        await account.cancelPairing(verifier, pairingId);
        continue;
      }
    } catch {
      await cancelQuietly(account, verifier, pairingId);
      return unavailable();
    }

    return json(hostPairingCreateResultSchema.parse({
      code,
      expiresAt: new Date(expiresAt).toISOString(),
    }));
  }

  return unavailable();
}

export async function redeemHostPairing(
  request: Request,
  env: PairingEnvironment,
  exports: AuthExports,
): Promise<Response> {
  if (request.method !== "POST") return methodNotAllowed("POST");
  if (!env.SESSION_SECRET || !exports.AxoAccountManager ||
      !exports.AxoPairingIndex || !exports.AxoPairingRateLimit) return unavailable();

  const rawBody = await boundedRequestBody(request);
  if (rawBody === null) return badRequest();
  let value: unknown;
  try {
    value = JSON.parse(rawBody) as unknown;
  } catch {
    return badRequest();
  }
  const parsed = hostPairingRedeemRequestSchema.safeParse(value);
  if (!parsed.success) return badRequest();

  const now = Date.now();
  const sourceKey = await hmac(env.SESSION_SECRET, `pairing-source\0${requestSource(request)}`);
  for (const [name, maximum] of [[`source-${sourceKey}`, MAX_REDEMPTIONS_PER_SOURCE_PER_MINUTE], ["redemption-global", MAX_REDEMPTIONS_PER_MINUTE]] as const) {
    const allowed = await consumeLimit(exports, name, now, maximum);
    if (allowed === "unavailable") return unavailable();
    if (!allowed) return rateLimited();
  }

  const input = parsed.data;
  const codeVerifier = await hmac(env.SESSION_SECRET, `pairing-code\0${input.code}`);
  const index = exports.AxoPairingIndex.getByName(pairingShard(codeVerifier));
  let entry: Awaited<ReturnType<typeof index.lookup>>;
  try {
    entry = await index.lookup(codeVerifier, now);
  } catch {
    return unavailable();
  }
  if (!entry) return invalidPairing();

  const account = exports.AxoAccountManager.getByName(entry.accountId);
  if (!account.redeemPairing) return unavailable();
  const credentialVerifier = await hmac(env.SESSION_SECRET, `host-credential\0${input.credential}`);
  try {
    const redemption = await account.redeemPairing({
      codeVerifier,
      pairingId: entry.pairingId,
      hostId: input.hostId,
      hostGeneration: input.hostGeneration,
      credentialId: input.credentialId,
      credentialVerifier,
      label: input.label,
      hostKind: input.hostKind,
      now,
    });
    if (redemption.status !== "linked") return invalidPairing();
    return json(hostPairingRedeemResultSchema.parse({
      linked: true,
      accountId: entry.accountId,
      hostId: redemption.hostId,
      hostGeneration: redemption.hostGeneration,
      credentialId: redemption.credentialId,
      linkedAt: new Date(redemption.linkedAt).toISOString(),
    }));
  } catch {
    return unavailable();
  }
}

function pairingShard(verifier: string): string {
  const firstCharacter = verifier[0];
  if (!firstCharacter) throw new Error("Pairing verifier is empty");
  return `pairing-${firstCharacter}`;
}

function generatePairingCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(5));
  const characters = Array.from({ length: 8 }, (_, index) => {
    const bitOffset = index * 5;
    const byteOffset = Math.floor(bitOffset / 8);
    const bitWithinByte = bitOffset % 8;
    const pair = (bytes[byteOffset] << 8) | (bytes[byteOffset + 1] ?? 0);
    const codeIndex = (pair >> (11 - bitWithinByte)) & (PAIRING_CHARSET_SIZE - 1);
    return CODE_ALPHABET[codeIndex]!;
  }).join("");
  return `${characters.slice(0, 4)}-${characters.slice(4)}`;
}

async function consumeLimit(
  exports: AuthExports,
  name: string,
  now: number,
  maximum: number,
): Promise<boolean | "unavailable"> {
  const result = await attempt(exports, name, now, maximum);
  return result === "unavailable" ? result : result === "allowed";
}

async function boundedRequestBody(request: Request): Promise<string | null> {
  const contentLength = Number(request.headers.get("Content-Length") ?? "0");
  if (Number.isFinite(contentLength) && contentLength > MAX_REDEMPTION_BODY_BYTES) return null;
  try {
    const body = await request.text();
    return new TextEncoder().encode(body).byteLength <= MAX_REDEMPTION_BODY_BYTES ? body : null;
  } catch {
    return null;
  }
}

async function cancelQuietly(
  account: { cancelPairing?: (verifier: string, pairingId: string) => Promise<void> },
  verifier: string,
  pairingId: string,
): Promise<void> {
  if (!account.cancelPairing) return;
  try {
    await account.cancelPairing(verifier, pairingId);
  } catch {
    // The unreturned code cannot be redeemed without a matching index entry.
  }
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: { "Cache-Control": "private, no-store", "Pragma": "no-cache" },
  });
}

function badRequest(): Response {
  return json({ error: "Invalid pairing request" }, 400);
}

function invalidPairing(): Response {
  return json({ error: "Pairing code is invalid or expired" }, 400);
}

function rateLimited(): Response {
  return json({ error: "Pairing rate limit exceeded" }, 429);
}

function unavailable(): Response {
  return json({ error: "Pairing is temporarily unavailable" }, 503);
}

function methodNotAllowed(allow: string): Response {
  const response = json({ error: "Method not allowed" }, 405);
  response.headers.set("Allow", allow);
  return response;
}
