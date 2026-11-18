import { z } from "zod";
import { base64Url, constantTimeEqual, fromBase64Url, hmac, requireSecret, seal as sealV1, unseal as unsealV1 } from "./crypto";

/**
 * The Worker's keys (RFD0076): every hash and seal it keeps or hands out is made with one of them,
 * and says which. Each is used per purpose, through a key derived for that purpose alone.
 *
 * Key 0 is `SESSION_SECRET`, used as the Worker always used it: a hash is HMAC(SESSION_SECRET,
 * "<purpose>\0<value>"), bare, and a seal is `v1.<iv>.<ciphertext>`. So everything made before
 * keys had IDs is key 0's, and still verifies. A key n ≥ 1 comes from `SECRET_KEYS`; its hashes are
 * `k<n>.<HMAC(HKDF(key, purpose), value)>` and its seals `v2.<n>.<iv>.<ciphertext>`.
 *
 * New hashes and seals use the current key; the previous one, while configured, still verifies and
 * opens what it made. Rotating is: make the new key current and the old one previous, wait until
 * what only the old one opens has ended or been rewritten, then drop it.
 */
export type KeyId = number;
type Key = { readonly id: KeyId; readonly secret: string };

const keyRefSchema = z.object({ id: z.number().int().min(0).max(1_000_000), secret: z.string().optional() }).strict();
/** `SECRET_KEYS`: `{"current":{"id":1,"secret":"…"},"previous":{"id":0}}`. Key 0 has no secret here: it is SESSION_SECRET. */
const secretKeysSchema = z.object({ current: keyRefSchema, previous: keyRefSchema.nullable().default(null) }).strict();

export type KeyEnvironment = { SESSION_SECRET?: string; SECRET_KEYS?: string };

const encoder = new TextEncoder();
const KEYED_HASH = /^k([0-9]+)\.([A-Za-z0-9_-]{43})$/;

export class Keyring {
  private constructor(readonly current: Key, readonly previous: Key | null) {}

  /** The keys `env` configures, or null if it configures none, or any badly: callers answer 503. */
  static parse(env: KeyEnvironment): Keyring | null {
    try {
      const key = (ref: z.infer<typeof keyRefSchema>): Key => {
        if (ref.id === 0) {
          if (ref.secret !== undefined) throw new Error("Key 0 is SESSION_SECRET");
          return { id: 0, secret: requireSecret(env.SESSION_SECRET ?? "") };
        }
        return { id: ref.id, secret: requireSecret(ref.secret ?? "") };
      };
      if (!env.SECRET_KEYS) return env.SESSION_SECRET ? Keyring.legacy(env.SESSION_SECRET) : null;
      const keys = secretKeysSchema.parse(JSON.parse(env.SECRET_KEYS));
      if (keys.previous && keys.previous.id === keys.current.id) return null;
      return new Keyring(key(keys.current), keys.previous ? key(keys.previous) : null);
    } catch {
      return null;
    }
  }

  /** Only key 0, SESSION_SECRET: the keys before SECRET_KEYS existed. */
  static legacy(sessionSecret: string): Keyring {
    return new Keyring({ id: 0, secret: requireSecret(sessionSecret) }, null);
  }

  // ─── Hashes ────────────────────────────────────────────────────────────────

  /** `value`'s hash for `purpose`, with the current key: what is stored, or handed out, now. */
  hash(purpose: string, value: string): Promise<string> {
    return hashWith(this.current, purpose, value);
  }

  /** `value`'s hash with each key, current first: what to look a stored hash up by. */
  async hashes(purpose: string, value: string): Promise<string[]> {
    return Promise.all(this.keys().map((key) => hashWith(key, purpose, value)));
  }

  /**
   * Whether `stored` is `value`'s hash for `purpose`, with the key it names: "current", "previous"
   * (to be rewritten with the current key), or false.
   */
  async verify(purpose: string, value: string, stored: string): Promise<"current" | "previous" | false> {
    const key = this.key(keyIdOfHash(stored));
    if (!key || !constantTimeEqual(await hashWith(key, purpose, value), stored)) return false;
    return key === this.current ? "current" : "previous";
  }

  // ─── Seals ─────────────────────────────────────────────────────────────────

  /** Encrypts and authenticates `value` for `purpose`, with the current key. */
  seal(purpose: string, value: unknown): Promise<string> {
    return this.current.id === 0 ? sealV1(this.current.secret, purpose, value) : sealWith(this.current, purpose, value);
  }

  /** What `seal` made, with whichever configured key it names, or null. */
  async unseal(purpose: string, sealed: string, maxBytes = 4096): Promise<unknown | null> {
    if (sealed.startsWith("v1.")) {
      const key = this.key(0);
      return key ? unsealV1(key.secret, purpose, sealed, maxBytes) : null;
    }
    const parts = sealed.split(".");
    if (parts.length !== 4 || parts[0] !== "v2" || !/^[1-9][0-9]*$/.test(parts[1]!)) return null;
    const key = this.key(Number(parts[1]));
    return key ? unsealWith(key, purpose, parts[2]!, parts[3]!, maxBytes) : null;
  }

  private keys(): Key[] {
    return this.previous ? [this.current, this.previous] : [this.current];
  }

  private key(id: KeyId | null): Key | undefined {
    return id === null ? undefined : this.keys().find((key) => key.id === id);
  }
}

/** The key a stored hash names: 0 if it is bare, null if it is no hash of ours. */
export function keyIdOfHash(stored: string): KeyId | null {
  if (/^[A-Za-z0-9_-]{43}$/.test(stored)) return 0;
  const keyed = KEYED_HASH.exec(stored);
  return keyed && /^[1-9][0-9]*$/.test(keyed[1]!) ? Number(keyed[1]) : null;
}

async function hashWith(key: Key, purpose: string, value: string): Promise<string> {
  if (key.id === 0) return hmac(key.secret, `${purpose}\0${value}`);
  const material = await crypto.subtle.importKey("raw", encoder.encode(key.secret), "HKDF", false, ["deriveKey"]);
  const derived = await crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: encoder.encode("axo-hash-v2"), info: encoder.encode(purpose) },
    material,
    { name: "HMAC", hash: "SHA-256", length: 256 },
    false,
    ["sign"],
  );
  return `k${key.id}.${base64Url(new Uint8Array(await crypto.subtle.sign("HMAC", derived, encoder.encode(value))))}`;
}

async function sealingKey(key: Key, purpose: string): Promise<CryptoKey> {
  const material = await crypto.subtle.importKey("raw", encoder.encode(key.secret), "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: encoder.encode("axo-seal-v2"), info: encoder.encode(purpose) },
    material,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

async function sealWith(key: Key, purpose: string, value: unknown): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await sealingKey(key, purpose), encoder.encode(JSON.stringify(value)));
  return `v2.${key.id}.${base64Url(iv)}.${base64Url(new Uint8Array(ciphertext))}`;
}

async function unsealWith(key: Key, purpose: string, ivText: string, ciphertextText: string, maxBytes: number): Promise<unknown | null> {
  try {
    const iv = fromBase64Url(ivText);
    const ciphertext = fromBase64Url(ciphertextText);
    if (iv.byteLength !== 12 || ciphertext.byteLength > maxBytes) return null;
    const plaintext = await crypto.subtle.decrypt({ name: "AES-GCM", iv: copy(iv) }, await sealingKey(key, purpose), copy(ciphertext));
    return JSON.parse(new TextDecoder().decode(plaintext)) as unknown;
  } catch {
    return null;
  }
}

function copy(bytes: Uint8Array): ArrayBuffer {
  const buffer = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buffer).set(bytes);
  return buffer;
}
