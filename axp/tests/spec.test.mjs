// Checks that the AXP documents, schemas and examples agree:
//
// - every schema compiles, against JSON Schema 2020-12 and ATXF's schema;
// - every message in every example validates against the schema of its method;
// - every ATXF record and Offer in the examples carries the hash and chain the example log gives;
// - the host's auth signature verifies with the public key it paired with;
// - every method the documents name has a schema, and every schema method is documented.

import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash, createPublicKey, verify } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { TranscriptHasher } from "@leostera/atxf";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (path) => readFileSync(join(ROOT, path), "utf8");
const json = (path) => JSON.parse(read(path));
const jsonl = (path) => read(path).split("\n").filter((line) => line.trim() !== "").map((line) => JSON.parse(line));

const ATXF_SCHEMA = JSON.parse(
  readFileSync(new URL("../schema/v0.1/atxf.schema.json", import.meta.resolve("@leostera/atxf")), "utf8"),
);

const CORE = json("schema/v0.1/axp.schema.json");
const EXTENSIONS = Object.fromEntries(
  readdirSync(join(ROOT, "schema/v0.1/ext")).map((id) => [id, json(`schema/v0.1/ext/${id}/0.1/${id}.schema.json`)]),
);

const ajv = new Ajv2020({ strict: true, strictTypes: false, strictRequired: false, allErrors: true });
addFormats(ajv);
ajv.addSchema(ATXF_SCHEMA);
ajv.addSchema(CORE);
for (const schema of Object.values(EXTENSIONS)) ajv.addSchema(schema);

/** The schema that defines a method: the core for `axp.*`, otherwise the extension it is named after. */
function schemaFor(method) {
  const prefix = method.split(".")[0];
  return prefix === "axp" ? CORE : EXTENSIONS[prefix];
}
function check(method, part, value, where) {
  const schema = schemaFor(method);
  assert.ok(schema, `${where}: no schema for ${method}`);
  const name = `${method}.${part}`;
  assert.ok(schema.$defs[name], `${where}: ${schema.$id} has no $defs["${name}"]`);
  const validate = ajv.getSchema(`${schema.$id}#/$defs/${name}`);
  assert.ok(validate(value), `${where}: ${name} is invalid: ${ajv.errorsText(validate.errors)}`);
}

test("every schema compiles", () => {
  for (const schema of [CORE, ...Object.values(EXTENSIONS)]) {
    for (const name of Object.keys(schema.$defs)) assert.ok(ajv.getSchema(`${schema.$id}#/$defs/${name}`), `${schema.$id}#/$defs/${name}`);
  }
});

// ─── Examples ───────────────────────────────────────────────────────────────

const EXAMPLES = readdirSync(join(ROOT, "examples")).filter((file) => file.endsWith(".axp.jsonl"));
const PEER = /^(host|hub|client)(:[a-z0-9-]+)?$/;

/** Validates every message of an exchange; returns the messages, fragments joined. */
function walk(file) {
  const pending = new Map();
  const partials = new Map();
  const messages = [];
  const visit = (message, from, to, where) => {
    assert.equal(message.jsonrpc, "2.0", `${where}: not JSON-RPC 2.0`);
    if ("method" in message) {
      check(message.method, "params", message.params, where);
      if ("id" in message) pending.set(`${from}>${to}#${message.id}`, message.method);
      messages.push({ from, to, message });
      if (message.method === "axp.fragment") {
        const { message: id, part, parts, data } = message.params;
        const list = partials.get(id) ?? [];
        list[part] = Buffer.from(data, "base64url");
        partials.set(id, list);
        if (list.filter(Boolean).length === parts) {
          partials.delete(id);
          visit(JSON.parse(Buffer.concat(list).toString("utf8")), from, to, `${where} (message ${id} reassembled)`);
        }
      }
      return;
    }
    const key = `${to}>${from}#${message.id}`;
    const method = pending.get(key);
    assert.ok(method, `${where}: response ${message.id} answers no request`);
    pending.delete(key);
    if ("error" in message) {
      assert.ok(Number.isInteger(message.error.code), `${where}: error without a code`);
      const validate = ajv.getSchema(`${CORE.$id}#/$defs/errorData`);
      assert.ok(validate(message.error.data), `${where}: error data is invalid: ${ajv.errorsText(validate.errors)}`);
    } else {
      check(method, "result", message.result, where);
    }
    messages.push({ from, to, message, method });
  };
  jsonl(`examples/${file}`).forEach((line, index) => {
    const where = `${file}:${index + 1}`;
    assert.deepEqual(Object.keys(line).filter((key) => !["from", "to", "note", "message"].includes(key)), [], `${where}: unknown fields`);
    assert.match(line.from, PEER, `${where}: from`);
    assert.match(line.to, PEER, `${where}: to`);
    visit(line.message, line.from, line.to, where);
  });
  assert.equal(partials.size, 0, `${file}: unfinished fragments`);
  return messages;
}

for (const file of EXAMPLES) test(`examples/${file} validates`, () => walk(file));

test("records and offers in the examples match the example log", () => {
  const [header, ...records] = jsonl("examples/session.atxf.jsonl");
  const { hash: _ignored, ...bare } = header;
  const hasher = new TranscriptHasher(bare);
  assert.equal(hasher.header.hash, header.hash, "header hash");
  const chains = [hasher.commitment().chain];
  const byId = new Map();
  for (const record of records) {
    const { hash, ...unhashed } = record;
    assert.equal(hasher.push(unhashed).hash, hash, `hash of ${record.id}`);
    chains.push(hasher.commitment().chain);
    byId.set(record.id, record);
  }
  const offers = [];
  const visit = (value) => {
    if (Array.isArray(value)) return value.forEach(visit);
    if (value === null || typeof value !== "object") return;
    if (typeof value.count === "number" && typeof value.chain === "string") offers.push(value);
    if (typeof value.hash === "string" && typeof value.id === "string" && byId.has(value.id)) {
      assert.deepEqual(value, byId.get(value.id), `record ${value.id} differs from the log`);
    }
    if (value.type === "transcript") assert.deepEqual(value, header, "header differs from the log");
    Object.values(value).forEach(visit);
  };
  for (const file of EXAMPLES) for (const { message } of walk(file)) visit(message);
  assert.ok(offers.length > 0);
  for (const offer of offers) assert.equal(offer.chain, chains[offer.count], `chain at ${offer.count}`);
  for (const file of EXAMPLES) {
    for (const { message } of walk(file)) {
      const batch = message.method === "axp.log.records" ? message.params : message.result;
      if (!batch || !Array.isArray(batch.records) || batch.from === undefined) continue;
      batch.records.forEach((record, i) => assert.equal(record.id, records[batch.from + i].id, `${file}: record at ${batch.from + i}`));
      if (batch.have) assert.equal(batch.have.count, batch.from + batch.records.length, `${file}: have.count`);
    }
  }
});

test("the host's auth signature verifies with its paired key", () => {
  const lines = jsonl("examples/pairing.axp.jsonl");
  const redeem = lines.find((line) => line.message.method === "axp.pair.redeem").message.params;
  const device = lines.find((line) => line.message.result?.device).message.result.device;
  const challenge = Buffer.from(lines.find((line) => line.message.result?.challenge).message.result.challenge, "base64url");
  const signature = Buffer.from(lines.find((line) => line.message.method === "axp.auth").message.params.signature, "base64url");
  const key = createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: redeem.publicKey }, format: "jwk" });
  const signed = Buffer.concat([Buffer.from("axp/0.1/auth\n"), challenge, Buffer.from(`\n${device}\nwss://hub.example`)]);
  assert.ok(verify(null, signed, key, signature));
});

// assets §1.1: asset algorithms, the Node digest that computes each, and their RFC 6920 names.
const HASHES = { sha256: "sha256", sha384: "sha384", sha512: "sha512", "sha3-256": "sha3-256", "sha3-512": "sha3-512" };
const NI_NAMES = { "sha-256": "sha256", "sha-384": "sha384", "sha-512": "sha512", "sha3-256": "sha3-256", "sha3-512": "sha3-512" };

test("the asset algorithm table, the schema and the hashes agree", () => {
  const schema = EXTENSIONS.assets;
  assert.deepEqual(schema.$defs.algorithm.enum, Object.keys(HASHES));
  const name = new RegExp(schema.$defs.asset.pattern);
  const uri = new RegExp(schema.$defs.uri.pattern);
  for (const [niName, algorithm] of Object.entries(NI_NAMES)) {
    const digest = createHash(HASHES[algorithm]).update("axp").digest();
    assert.match(`${algorithm}:${digest.toString("hex")}`, name);
    assert.match(`ni:///${niName};${digest.toString("base64url")}`, uri);
    assert.doesNotMatch(`${algorithm}:${digest.subarray(1).toString("hex")}`, name, `${algorithm} accepts a truncated digest`);
    assert.doesNotMatch(`ni:///${niName};${digest.subarray(1).toString("base64url")}`, uri, `${niName} accepts a truncated digest`);
  }
  assert.doesNotMatch(`md5:${createHash("md5").update("axp").digest("hex")}`, name);
});

test("asset bytes hash to their names, and ni: URIs in the log name assets the examples carry", () => {
  const assets = new Map();
  for (const file of EXAMPLES) {
    const uploads = new Map();
    const parts = new Map();
    const add = (asset, offset, data) => {
      const list = parts.get(asset) ?? [];
      list.push({ offset, bytes: Buffer.from(data, "base64url") });
      parts.set(asset, list);
    };
    const messages = walk(file);
    for (const [index, { message, method }] of messages.entries()) {
      if (method === "assets.put" && message.result?.upload) {
        const request = messages.slice(0, index).reverse().find((m) => m.message.method === "assets.put" && m.message.id === message.id);
        uploads.set(message.result.upload, request.message.params.asset);
      }
      if (message.method === "assets.chunk") add(uploads.get(message.params.upload), message.params.offset, message.params.data);
      if (method === "assets.get" && message.result) add(message.result.asset.asset, message.result.offset, message.result.data);
    }
    for (const [asset, list] of parts) {
      const seen = new Map();
      for (const part of list) {
        if (seen.has(part.offset)) assert.ok(seen.get(part.offset).equals(part.bytes), `${file}: two copies of ${asset} differ at ${part.offset}`);
        seen.set(part.offset, part.bytes);
      }
      const ordered = [...seen.entries()].sort((a, b) => a[0] - b[0]);
      let offset = 0;
      for (const [start, bytes] of ordered) {
        assert.equal(start, offset, `${file}: ${asset} has a gap at ${offset}`);
        offset += bytes.length;
      }
      const bytes = Buffer.concat(ordered.map(([, b]) => b));
      const [algorithm] = asset.split(":");
      assert.equal(`${algorithm}:${createHash(HASHES[algorithm]).update(bytes).digest("hex")}`, asset, `${file}: bytes of ${asset}`);
      assets.set(asset, bytes);
    }
  }
  assert.ok(assets.size > 0, "no asset bytes in the examples");
  const log = read("examples/session.atxf.jsonl");
  const uris = [...log.matchAll(/ni:\/\/\/([a-z0-9-]+);([A-Za-z0-9_-]+)/g)];
  assert.ok(uris.length > 0, "the example log refers to no asset");
  for (const [, niName, digest] of uris) {
    const algorithm = NI_NAMES[niName];
    assert.ok(algorithm, `unknown ni algorithm ${niName}`);
    const asset = `${algorithm}:${Buffer.from(digest, "base64url").toString("hex")}`;
    assert.ok(assets.has(asset), `the log refers to ${asset}, which no example carries`);
  }
});

// ─── Documents and schemas agree ────────────────────────────────────────────

const DOCS = ["SPEC.md", ...readdirSync(join(ROOT, "extensions")).filter((f) => f !== "README.md").map((f) => `extensions/${f}`)];
const NAMESPACES = ["axp", ...Object.keys(EXTENSIONS)].join("|");
const METHOD = new RegExp(`\`((?:${NAMESPACES})\\.[a-z][a-zA-Z]*(?:\\.[a-z][a-zA-Z]*)*)\``, "g");
const NOT_METHODS = new Set(["axp.command", "agent.md"]);

test("every documented method has a schema, and every schema method is documented", () => {
  const documented = new Set();
  for (const doc of DOCS) for (const [, name] of read(doc).matchAll(METHOD)) if (!NOT_METHODS.has(name)) documented.add(name);
  const defined = new Set();
  for (const schema of [CORE, ...Object.values(EXTENSIONS)]) {
    for (const name of Object.keys(schema.$defs)) {
      const match = name.match(/^(.+)\.(params|result)$/);
      if (match && match[1].includes(".") && new RegExp(`^(${NAMESPACES})\\.`).test(match[1])) defined.add(match[1]);
    }
  }
  const missing = [...documented].filter((name) => !defined.has(name) && ![...defined].some((d) => d.startsWith(`${name}.`)));
  assert.deepEqual(missing, [], "documented but without a schema");
  const undocumented = [...defined].filter((name) => !documented.has(name));
  assert.deepEqual(undocumented, [], "in a schema but not documented");
});

test("the registry lists every extension with a document and a schema", () => {
  const registry = read("extensions/README.md");
  for (const id of Object.keys(EXTENSIONS)) {
    assert.match(registry, new RegExp(`\\| \`${id}\` \\| 0\\.1 \\|`), `${id} in the registry`);
    assert.match(read(`extensions/${id}.md`), new RegExp(`Identifier: ${id}\\n`), `${id}.md front matter`);
  }
});
