import { devicePublicKey, keyFingerprint, newDeviceKey, signAnswer, type DeviceProof } from "@axo/app";
import type { Sealed } from "@axo/protocol";

/**
 * This browser as a device that answers for the person (RFD0029, every remote answer is signed):
 * an ECDSA P-256 key whose private half cannot be read out, kept in IndexedDB, signing each
 * answer. A Mac takes answers only from devices allowed in Axo there.
 */
export interface AnswerDevice {
  proof(requestId: string, action: "accept" | "decline", sealed?: Sealed): Promise<DeviceProof>;
  /** As the Mac shows it, to compare before allowing this browser. */
  fingerprint(): Promise<string>;
}

/** A device whose key lives only as long as this object: for tests. */
export function memoryDevice(name = "Test browser"): AnswerDevice {
  const key = newDeviceKey();
  return {
    proof: async (requestId, action, sealed) => signAnswer(await key, name, requestId, action, sealed),
    fingerprint: async () => keyFingerprint(await devicePublicKey((await key).publicKey)),
  };
}

function request<T>(open: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    open.onsuccess = () => resolve(open.result);
    open.onerror = () => reject(open.error);
  });
}

async function storedKey(): Promise<CryptoKeyPair> {
  const opening = indexedDB.open("axo-device", 1);
  opening.onupgradeneeded = () => opening.result.createObjectStore("keys");
  const database = await request(opening);
  const found = await request(database.transaction("keys").objectStore("keys").get("answer") as IDBRequest<CryptoKeyPair | undefined>);
  if (found) return found;
  const made = await newDeviceKey();
  await request(database.transaction("keys", "readwrite").objectStore("keys").put(made, "answer"));
  return made;
}

/** "Safari on Mac", "Chrome on Windows": what the Mac shows when this browser first answers. */
export function browserName(userAgent: string): string {
  const browser = /Edg\//.test(userAgent) ? "Edge" : /Firefox\//.test(userAgent) ? "Firefox" : /Chrome\//.test(userAgent) ? "Chrome" : /Safari\//.test(userAgent) ? "Safari" : "A browser";
  const system = /iPhone|iPad/.test(userAgent) ? "iPhone" : /Mac OS X/.test(userAgent) ? "Mac" : /Windows/.test(userAgent) ? "Windows" : /Android/.test(userAgent) ? "Android" : /Linux/.test(userAgent) ? "Linux" : "";
  return system ? `${browser} on ${system}` : browser;
}

/** This browser's key in IndexedDB, made on first use. */
export function browserDevice(): AnswerDevice {
  let key: Promise<CryptoKeyPair> | undefined;
  const pair = () => (key ??= storedKey());
  const name = browserName(typeof navigator === "undefined" ? "" : navigator.userAgent);
  return {
    proof: async (requestId, action, sealed) => signAnswer(await pair(), name, requestId, action, sealed),
    fingerprint: async () => keyFingerprint(await devicePublicKey((await pair()).publicKey)),
  };
}
