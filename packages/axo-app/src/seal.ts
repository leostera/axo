import { Aes256Gcm, CipherSuite, DhkemP256HkdfSha256, HkdfSha256 } from "@hpke/core";
import { INPUT_SEAL, type DeviceProof, type Sealed } from "@axo/protocol";

/**
 * Seals what the person typed into an input request's form to the Mac's input key (RFD0029, the
 * side channel for input), so the cloud carries only ciphertext. The same suite as axod's
 * `axo-seal` and the phone's CryptoKit: DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-256-GCM.
 */
const suite = new CipherSuite({ kem: new DhkemP256HkdfSha256(), kdf: new HkdfSha256(), aead: new Aes256Gcm() });

function bytes(base64: string): Uint8Array<ArrayBuffer> {
  const binary = atob(base64);
  const out = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) out[index] = binary.charCodeAt(index);
  return out;
}

function base64(data: ArrayBuffer | Uint8Array): string {
  const view = data instanceof Uint8Array ? data : new Uint8Array(data);
  let binary = "";
  for (const byte of view) binary += String.fromCharCode(byte);
  return btoa(binary);
}

/** `values` by field id, sealed to `key` (base64 SEC1) for this request and the address shown. */
export async function sealInput(key: string, requestId: string, origin: string | undefined, values: Record<string, string>): Promise<Sealed> {
  const recipientPublicKey = await suite.kem.deserializePublicKey(bytes(key));
  const plaintext = new TextEncoder().encode(JSON.stringify({ values }));
  const aad = new TextEncoder().encode(INPUT_SEAL.aad(requestId, origin));
  const sender = await suite.createSenderContext({ recipientPublicKey, info: new TextEncoder().encode(INPUT_SEAL.info) });
  const ciphertext = await sender.seal(plaintext, aad);
  return { enc: base64(sender.enc), ciphertext: base64(ciphertext) };
}

/**
 * A short fingerprint of a Mac's input key, to compare with what the Mac app shows: the first
 * 8 bytes of its SHA-256, as four groups of hex.
 */
export async function keyFingerprint(key: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes(key)));
  const hex = [...digest.slice(0, 8)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return hex.match(/.{4}/g)!.join(" ");
}

/**
 * What a device signs for one answer (RFD0029, every remote answer is signed): the request, the
 * action, and the sealed values if any, so a signature is good for that answer alone. The same
 * bytes as axod's `axo_seal::answer_message`.
 */
export async function answerMessage(requestId: string, action: string, sealed?: Sealed): Promise<Uint8Array<ArrayBuffer>> {
  let digest = "";
  if (sealed) {
    const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${sealed.enc}\n${sealed.ciphertext}`)));
    digest = [...hash].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  }
  return new TextEncoder().encode(`axo-answer/v1\n${requestId}\n${action}\n${digest}`);
}

/** A device's signing key: ECDSA P-256, its private half never extractable. */
export async function newDeviceKey(): Promise<CryptoKeyPair> {
  return crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"]);
}

/** A device key's public half as the Mac knows it: base64 of the uncompressed point. */
export async function devicePublicKey(key: CryptoKey): Promise<string> {
  return base64(await crypto.subtle.exportKey("raw", key));
}


export async function signAnswer(device: CryptoKeyPair, name: string, requestId: string, action: string, sealed?: Sealed): Promise<DeviceProof> {
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, device.privateKey, await answerMessage(requestId, action, sealed));
  return { key: await devicePublicKey(device.publicKey), name, signature: base64(signature) };
}
