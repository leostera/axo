import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import test from "node:test";
import { Aes256Gcm, CipherSuite, DhkemP256HkdfSha256, HkdfSha256 } from "@hpke/core";
import { INPUT_SEAL } from "@axo/protocol";
import { keyFingerprint, sealInput } from "../src/seal.ts";

/**
 * The browser seals as axod opens (RFD0029): every case in crates/axo-seal/testdata/vectors.json
 * is opened by axod's `axo-seal` tests. `AXO_WRITE_SEAL_VECTORS=1` replaces this file's case.
 */
const vectorsPath = new URL("../../../crates/axo-seal/testdata/vectors.json", import.meta.url);
const suite = new CipherSuite({ kem: new DhkemP256HkdfSha256(), kdf: new HkdfSha256(), aead: new Aes256Gcm() });
const fromBase64 = (text) => Uint8Array.from(Buffer.from(text, "base64"));

test("what the browser seals opens only with the Mac's key, for its request and address", async () => {
  const vectors = JSON.parse(readFileSync(vectorsPath, "utf8"));
  const recipientKey = await suite.kem.deserializePrivateKey(fromBase64(vectors.secretKey));
  const requestId = "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f5a";
  const origin = "https://github.com";
  const sealed = await sealInput(vectors.publicKey, requestId, origin, { f0: "me@example.com", f1: "hunter2 ✓" });
  const open = async (aad) => {
    const recipient = await suite.createRecipientContext({ recipientKey, enc: fromBase64(sealed.enc), info: new TextEncoder().encode(INPUT_SEAL.info) });
    return JSON.parse(new TextDecoder().decode(await recipient.open(fromBase64(sealed.ciphertext), new TextEncoder().encode(aad))));
  };
  assert.deepEqual(await open(INPUT_SEAL.aad(requestId, origin)), { values: { f0: "me@example.com", f1: "hunter2 ✓" } });
  await assert.rejects(open(INPUT_SEAL.aad(requestId, "https://github.co")));
  assert.equal(fromBase64(sealed.enc).length, 65);
  assert.match(await keyFingerprint(vectors.publicKey), /^[0-9a-f]{4}( [0-9a-f]{4}){3}$/);

  if (process.env.AXO_WRITE_SEAL_VECTORS) {
    vectors.cases = vectors.cases.filter((c) => c.from !== "webcrypto");
    vectors.cases.push({ from: "webcrypto", requestId, origin, ...sealed, plaintext: JSON.stringify({ values: { f0: "me@example.com", f1: "hunter2 ✓" } }) });
    writeFileSync(vectorsPath, `${JSON.stringify(vectors, null, 2)}\n`);
  }
});

test("what a browser signs is for that answer alone", async () => {
  const { answerMessage, newDeviceKey, signAnswer } = await import("../src/seal.ts");
  const device = await newDeviceKey();
  const requestId = "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f5a";
  const sealed = { enc: "QQ==", ciphertext: "Qg==" };
  const proof = await signAnswer(device, "Safari", requestId, "accept", sealed);
  const verify = async (action, id = requestId, s = sealed) =>
    crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, device.publicKey, fromBase64(proof.signature), await answerMessage(id, action, s ?? undefined));
  assert.equal(await verify("accept"), true);
  assert.equal(await verify("decline"), false);
  assert.equal(await verify("accept", "another"), false);
  assert.equal(await verify("accept", requestId, null), false);
  assert.equal(fromBase64(proof.key).length, 65);

  if (process.env.AXO_WRITE_SEAL_VECTORS) {
    const vectors = JSON.parse(readFileSync(vectorsPath, "utf8"));
    vectors.signed = (vectors.signed ?? []).filter((c) => c.from !== "webcrypto");
    vectors.signed.unshift({ from: "webcrypto", requestId, action: "accept", sealed, key: proof.key, signature: proof.signature, fingerprint: await keyFingerprint(proof.key) });
    writeFileSync(vectorsPath, `${JSON.stringify(vectors, null, 2)}\n`);
  }
});
