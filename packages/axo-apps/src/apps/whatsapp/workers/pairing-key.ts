import { pbkdf2Async } from "@noble/hashes/pbkdf2.js";
import { sha256 } from "@noble/hashes/sha2.js";

/**
 * Baileys' `derivePairingCodeKey`, which bundling.mjs puts in its place: the key a pairing code
 * and WhatsApp's salt make, by PBKDF2-SHA256 at 131,072 (2 << 16) iterations. Baileys asks Web
 * Crypto for it, which on Workers refuses more than 100,000 iterations, so every pairing code
 * failed there; this computes the same key in JavaScript.
 */
export async function derivePairingCodeKey(pairingCode: string, salt: Uint8Array): Promise<Buffer> {
  return Buffer.from(await pbkdf2Async(sha256, new TextEncoder().encode(pairingCode), new Uint8Array(salt), { c: 2 << 16, dkLen: 32 }));
}
