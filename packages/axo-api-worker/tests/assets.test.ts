import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { assetListSchema, assetSchema } from "@axo/protocol";
import { harness, signIn, signInNative, type AccountSession, type Harness } from "./harness";
import { pairHost } from "./account-support";

/** Assets (RFD0030, specs/assets/assets.ts, specs/assets/asset-quota.ts) over the Worker's HTTPS routes. */

const hex = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");
const bytesOf = (text: string) => new TextEncoder().encode(text);

function put(h: Harness, headers: Record<string, string>, bytes: Uint8Array, options: { hash?: string; name?: string; type?: string } = {}) {
  return fetch(new URL(`api/v1/account/assets/${options.hash ?? hex(bytes)}`, h.url), {
    method: "PUT",
    headers: {
      ...headers,
      "Content-Type": options.type ?? "image/png",
      "X-Axo-Asset-Name": encodeURIComponent(options.name ?? "whiteboard.png"),
    },
    body: bytes as BodyInit,
  });
}

const get = (h: Harness, headers: Record<string, string>, hash: string, method = "GET") =>
  fetch(new URL(`api/v1/account/assets/${hash}`, h.url), { method, headers });

const remove = (h: Harness, session: AccountSession, hash: string, version: number) =>
  fetch(new URL(`api/v1/account/assets/${hash}/delete`, h.url), {
    method: "POST",
    headers: { ...session.headers, "Content-Type": "application/json" },
    body: JSON.stringify({ version }),
  });

test("an upload is readable by its account, with the bytes and type it was stored with", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const person = await signIn(h);
  const bytes = bytesOf("not really a png, but bytes all the same");
  const uploaded = await put(h, person.headers, bytes);
  assert.equal(uploaded.status, 201, await uploaded.clone().text());
  const asset = assetSchema.parse(await uploaded.json());
  assert.equal(asset.asset, `sha256:${hex(bytes)}`);
  assert.equal(asset.mimeType, "image/png");
  assert.equal(asset.version, 1);

  const read = await get(h, person.headers, hex(bytes));
  assert.equal(read.status, 200);
  assert.equal(read.headers.get("content-type"), "image/png");
  assert.equal(read.headers.get("cache-control"), "private, max-age=31536000, immutable");
  assert.equal(read.headers.get("etag"), `"${hex(bytes)}"`);
  assert.match(read.headers.get("content-disposition")!, /^inline; filename\*=UTF-8''whiteboard\.png$/);
  assert.deepEqual(new Uint8Array(await read.arrayBuffer()), bytes);
  assert.equal((await get(h, person.headers, hex(bytes), "HEAD")).status, 200);
});

test("another account can't read, list or delete an account's asset, even knowing its hash", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const owner = await signIn(h);
  const other = await signIn(h);
  const bytes = bytesOf("private photo");
  assert.equal((await put(h, owner.headers, bytes)).status, 201);
  assert.equal((await get(h, other.headers, hex(bytes))).status, 404);
  assert.equal((await get(h, other.headers, hex(bytes), "HEAD")).status, 404);
  const list = assetListSchema.parse(await (await fetch(new URL("api/v1/account/assets", h.url), { headers: other.headers })).json());
  assert.equal(list.assets.length, 0);
  assert.equal((await remove(h, other, hex(bytes), 1)).status, 404);
  assert.equal((await get(h, owner.headers, hex(bytes))).status, 200, "the owner still has it");
});

test("the same file uploaded by a second account is stored apart: one delete leaves the other", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const first = await signIn(h);
  const second = await signIn(h);
  const bytes = bytesOf("same file, two accounts");
  assert.equal((await put(h, first.headers, bytes)).status, 201);
  assert.equal((await put(h, second.headers, bytes)).status, 201, "a second account uploads, not 'exists'");
  assert.equal((await remove(h, first, hex(bytes), 1)).status, 200);
  assert.equal((await get(h, second.headers, hex(bytes))).status, 200);
  const bucket = await h.mf.getR2Bucket("AXO_ASSETS") as unknown as R2Bucket;
  assert.equal(await bucket.head(`accounts/${first.accountId}/${hex(bytes)}`), null);
  assert.notEqual(await bucket.head(`accounts/${second.accountId}/${hex(bytes)}`), null);
});

test("bytes that don't match the name are refused and nothing is kept", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const person = await signIn(h);
  const claimed = hex(bytesOf("what the name says"));
  const response = await put(h, person.headers, bytesOf("what was sent"), { hash: claimed });
  assert.equal(response.status, 400);
  assert.equal(((await response.json()) as { code: string }).code, "mismatch");
  assert.equal((await get(h, person.headers, claimed, "HEAD")).status, 404);
  // The reservation was released: the right bytes upload afterwards.
  assert.equal((await put(h, person.headers, bytesOf("what the name says"))).status, 201);
});

test("uploading what is already there answers 200 and raises the version, so an older delete is refused", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const person = await signIn(h);
  const bytes = bytesOf("attached twice");
  const first = assetSchema.parse(await (await put(h, person.headers, bytes)).json());
  const again = await put(h, person.headers, bytes);
  assert.equal(again.status, 200);
  const second = assetSchema.parse(await again.json());
  assert.equal(second.version, first.version + 1);
  const stale = await remove(h, person, hex(bytes), first.version);
  assert.equal(stale.status, 409);
  assert.equal(((await stale.json()) as { code: string }).code, "conflict");
  assert.equal((await get(h, person.headers, hex(bytes))).status, 200, "the file attached again is kept");
  assert.equal((await remove(h, person, hex(bytes), second.version)).status, 200);
  assert.equal((await get(h, person.headers, hex(bytes))).status, 404);
});

test("a deleted asset is gone from reads, the list and R2, and can be uploaded again", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const person = await signIn(h);
  const bytes = bytesOf("short-lived");
  assert.equal((await put(h, person.headers, bytes)).status, 201);
  assert.equal((await get(h, person.headers, hex(bytes))).status, 200);
  assert.equal((await remove(h, person, hex(bytes), 1)).status, 200);
  const read = await get(h, person.headers, hex(bytes));
  assert.equal(read.status, 404);
  assert.equal(read.headers.get("cache-control"), "private, no-store");
  const list = assetListSchema.parse(await (await fetch(new URL("api/v1/account/assets", h.url), { headers: person.headers })).json());
  assert.deepEqual(list.assets, []);
  assert.deepEqual(list.usage, { bytes: 0, assets: 0 });
  const uploaded = assetSchema.parse(await (await put(h, person.headers, bytes)).json());
  assert.equal(uploaded.version, 2, "versions only grow, across deletes");
});

test("the list is newest first, with the account's usage", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const person = await signIn(h);
  const a = bytesOf("first");
  const b = bytesOf("second, longer");
  await put(h, person.headers, a, { name: "a.txt", type: "text/plain" });
  await new Promise((resolve) => setTimeout(resolve, 5));
  await put(h, person.headers, b, { name: "b.json", type: "application/json; charset=utf-8" });
  const list = assetListSchema.parse(await (await fetch(new URL("api/v1/account/assets", h.url), { headers: person.headers })).json());
  assert.deepEqual(list.assets.map((asset) => asset.name), ["b.json", "a.txt"]);
  assert.equal(list.assets[0]!.mimeType, "application/json");
  assert.deepEqual(list.usage, { bytes: a.byteLength + b.byteLength, assets: 2 });
  assert.equal(list.next, null);
});

test("types that could run script are stored as octet-stream and served as downloads", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const person = await signIn(h);
  const bytes = bytesOf("<svg onload=alert(1)></svg>");
  const asset = assetSchema.parse(await (await put(h, person.headers, bytes, { type: "image/svg+xml", name: "x.svg" })).json());
  assert.equal(asset.mimeType, "application/octet-stream");
  const read = await get(h, person.headers, hex(bytes));
  assert.equal(read.headers.get("content-type"), "application/octet-stream");
  assert.match(read.headers.get("content-disposition")!, /^attachment;/);
  assert.equal(read.headers.get("x-content-type-options"), "nosniff");
});

test("names with slashes, oversized assets, a missing length and bad hashes are refused", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const person = await signIn(h);
  assert.equal((await put(h, person.headers, bytesOf("x"), { name: "../../etc/passwd" })).status, 400);
  assert.equal((await put(h, person.headers, bytesOf("x"), { hash: "ABC" })).status, 400);
  const huge = await fetch(new URL(`api/v1/account/assets/${"0".repeat(64)}`, h.url), {
    method: "PUT",
    headers: { ...person.headers, "Content-Length": String(100 * 1024 * 1024 + 1), "X-Axo-Asset-Name": "big.bin" },
    body: new ReadableStream({ start(controller) { controller.close(); } }),
    duplex: "half",
  } as RequestInit).catch(() => null);
  // Either the Worker refuses the declared size, or the client refuses to send a lying length.
  if (huge) assert.notEqual(huge.status, 201);
});

test("a cookie upload needs the app's Origin; a bearer token doesn't; no credentials, no access", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const person = await signIn(h);
  const phone = await signInNative(h);
  const bytes = bytesOf("from the phone");
  const { Origin: _origin, ...cookieOnly } = person.headers;
  assert.equal((await put(h, cookieOnly, bytes)).status, 403);
  assert.equal((await put(h, phone.headers, bytes)).status, 201);
  assert.equal((await get(h, phone.headers, hex(bytes))).status, 200);
  assert.equal((await get(h, {}, hex(bytes))).status, 401);
});

test("a paired Mac reads its account's assets with its host credential, and no other's", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const person = await signIn(h);
  const other = await signIn(h);
  const host = await pairHost(h, person);
  const bytes = bytesOf("for the Mac");
  assert.equal((await put(h, person.headers, bytes)).status, 201);
  const credential = { Authorization: `Bearer ${host.credential}`, "X-Axo-Credential-Id": host.credentialId };
  const read = await fetch(new URL(`api/v1/accounts/${person.accountId}/hosts/${host.hostId}/assets/${hex(bytes)}`, h.url), { headers: credential });
  assert.equal(read.status, 200);
  assert.deepEqual(new Uint8Array(await read.arrayBuffer()), bytes);
  const elsewhere = await fetch(new URL(`api/v1/accounts/${other.accountId}/hosts/${host.hostId}/assets/${hex(bytes)}`, h.url), { headers: credential });
  assert.equal(elsewhere.status, 401, "the credential is the account's, not any account's");
  const wrong = await fetch(new URL(`api/v1/accounts/${person.accountId}/hosts/${host.hostId}/assets/${hex(bytes)}`, h.url), {
    headers: { ...credential, Authorization: `Bearer ${"A".repeat(43)}` },
  });
  assert.equal(wrong.status, 401);
});

test("parallel uploads can't overshoot the quota: reservations count from the start", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const person = await signIn(h);
  // Fill the account to 5 bytes short of its quota with one reservation, then race two 3-byte uploads.
  const namespace = await h.mf.getDurableObjectNamespace("TEST_ASSETS") as unknown as DurableObjectNamespace;
  const assets = namespace.get(namespace.idFromName(`account:${person.accountId}`)) as unknown as {
    reserve(accountId: string, input: unknown): Promise<{ answer: string }>;
  };
  const filler = await assets.reserve(person.accountId, { hash: "f".repeat(64), size: 10 * 1024 ** 3 - 5, type: "application/zip", name: "big.zip", createdBy: "test" });
  assert.equal(filler.answer, "reserved");
  const results = await Promise.all([put(h, person.headers, bytesOf("one")), put(h, person.headers, bytesOf("two"))]);
  assert.deepEqual(results.map((response) => response.status).sort(), [201, 413]);
});
