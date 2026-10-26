const encoder = new TextEncoder();

/** `byteLength` random bytes, base64url without padding. */
export function randomToken(byteLength = 32): string {
  return base64Url(crypto.getRandomValues(new Uint8Array(byteLength)));
}

export async function sha256(value: string): Promise<string> {
  return base64Url(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value))));
}

/** Keyed hash of `value`; the `purpose` inside `value` keeps one key's uses apart. */
export async function hmac(secret: string, value: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(requireSecret(secret)),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return base64Url(new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(value))));
}

export function constantTimeEqual(left: string, right: string): boolean {
  const a = encoder.encode(left);
  const b = encoder.encode(right);
  let difference = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) difference |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return difference === 0;
}

/**
 * Encrypts and authenticates `value`, so it can travel through a browser and come back
 * unreadable and unforged. `purpose` is bound in: something sealed for one purpose does not open
 * for another.
 */
export async function seal(secret: string, purpose: string, value: unknown): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const plaintext = encoder.encode(JSON.stringify(value));
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    await sealingKey(secret, purpose),
    plaintext,
  );
  return `v1.${base64Url(iv)}.${base64Url(new Uint8Array(ciphertext))}`;
}

/** The value `seal` made, or null if it is not exactly that: wrong key, purpose or any change. */
export async function unseal(secret: string, purpose: string, sealed: string): Promise<unknown | null> {
  try {
    const parts = sealed.split(".");
    if (parts.length !== 3 || parts[0] !== "v1") return null;
    const iv = fromBase64Url(parts[1]!);
    const ciphertext = fromBase64Url(parts[2]!);
    if (iv.byteLength !== 12 || ciphertext.byteLength > 4096) return null;
    const plaintext = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: toBuffer(iv) },
      await sealingKey(secret, purpose),
      toBuffer(ciphertext),
    );
    return JSON.parse(new TextDecoder().decode(plaintext)) as unknown;
  } catch {
    return null;
  }
}

export function requireSecret(secret: string): string {
  if (encoder.encode(secret).byteLength < 32) throw new Error("SESSION_SECRET must contain at least 32 bytes");
  return secret;
}

async function sealingKey(secret: string, purpose: string): Promise<CryptoKey> {
  const material = await crypto.subtle.importKey("raw", encoder.encode(requireSecret(secret)), "HKDF", false, [
    "deriveKey",
  ]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: encoder.encode("axo-seal-v1"), info: encoder.encode(purpose) },
    material,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

export function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

/** Strict: only canonical unpadded base64url decodes. */
export function fromBase64Url(value: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw new Error("Invalid base64url");
  const base64 = value.replaceAll("-", "+").replaceAll("_", "/");
  const decoded = Uint8Array.from(atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4)), (c) => c.charCodeAt(0));
  if (base64Url(decoded) !== value) throw new Error("Non-canonical base64url");
  return decoded;
}

function toBuffer(bytes: Uint8Array): ArrayBuffer {
  const buffer = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buffer).set(bytes);
  return buffer;
}
