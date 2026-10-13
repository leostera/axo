import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import { isDeepStrictEqual } from "node:util";
import { execFileSync, spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import { once } from "node:events";
import fc from "fast-check";
import {
  decode, callSchema, remoteMethods, serveProfileMessage, createProfileServer,
  stateMutationMethods,
} from "@axo/protocol";

const root = fileURLToPath(new URL("../../", import.meta.url));
const seed = 0x41584f;
function codec(raw: string): unknown {
  const message = decode(raw);
  if ("error" in message) {
    assert.ok("error" in message.error);
    return { error: message.error.error.code };
  }
  return { batch: message.batch, entries: message.entries.map(entry => {
    const parsed = callSchema.safeParse(entry);
    if (!parsed.success) return { error: -32600 };
    return {
      method: parsed.data.method,
      idPresent: parsed.data.id !== undefined,
      id: parsed.data.id ?? null,
      params: parsed.data.params ?? null,
    };
  }) };
}
class Oracle {
  private lines: string[] = [];
  private waiters: Array<(line: string) => void> = [];
  private failure: Error | undefined;
  constructor(readonly child: ChildProcessWithoutNullStreams) {
    createInterface({ input: child.stdout }).on("line", line => {
      const waiting = this.waiters.shift();
      if (waiting) waiting(line); else this.lines.push(line);
    });
    child.on("error", () => this.fail());
    child.on("exit", () => this.fail());
    child.stderr.resume(); // Never echo payload-bearing exceptions or process diagnostics.
  }
  private fail() {
    this.failure = new Error("Rust oracle exited");
    for (const waiter of this.waiters.splice(0)) waiter('{"oracleFailure":true}');
  }
  async next(): Promise<unknown> {
    if (this.failure) throw this.failure;
    const line = this.lines.shift() ?? await new Promise<string>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.fail();
        this.child.kill("SIGKILL"); // Only this fixture's child handle.
        reject(new Error("Rust oracle reply deadline"));
      }, 5000);
      this.waiters.push(line => { clearTimeout(timer); resolve(line); });
    });
    let parsed: { oracleFailure?: boolean };
    try { parsed = JSON.parse(line); } catch { throw new Error("Invalid Rust oracle reply"); }
    if (parsed.oracleFailure) throw new Error("Rust oracle unavailable");
    return parsed;
  }
  async query(input: unknown): Promise<unknown> {
    if (!this.child.stdin.write(JSON.stringify(input) + "\n")) await once(this.child.stdin, "drain");
    return this.next();
  }
}
async function fixture(t: TestContext) {
  execFileSync("cargo", ["build", "--locked", "--offline", "--example", "rpc-oracle"], {
    cwd: join(root, "axod"), stdio: "pipe", timeout: 60000,
  });
  const directory = await mkdtemp("/tmp/axo-properties-");
  const child = spawn(join(root, "axod/target/debug/examples/rpc-oracle"), [directory], { stdio: "pipe" });
  const oracle = new Oracle(child);
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) {
      const exited = once(child, "exit");
      child.stdin.end();
      const timer = setTimeout(() => child.kill("SIGKILL"), 3000);
      try { await exited; } finally { clearTimeout(timer); }
    }
    await rm(directory, { recursive: true, force: true });
  });
  const hello = await oracle.next() as { target: { machineId: string; hostGeneration: string } };
  return { oracle, target: hello.target };
}
async function check(property: Parameters<typeof fc.check>[0], numRuns: number) {
  const requestedSeed = process.env.AXO_PROPERTY_SEED;
  const path = process.env.AXO_PROPERTY_PATH;
  if ((requestedSeed !== undefined && (!/^\d{1,10}$/.test(requestedSeed) || Number(requestedSeed) > 0xffffffff)) ||
      (path !== undefined && (requestedSeed === undefined || path.length > 4096 || !/^\d+(?::\d+)*$/.test(path)))) {
    throw new Error("Invalid property replay configuration");
  }
  const seeds = requestedSeed === undefined ? [seed, 20261011, 0xc0ffee] : [Number(requestedSeed)];
  for (const replaySeed of seeds) {
    const result = await fc.check(property, { seed: replaySeed, numRuns, ...(path === undefined ? {} : { path }) });
    if (result.failed) {
      // Seed/path replay and shrinking without dumping counterexample bodies to diagnostics.
      throw new Error(`Property failed: seed=${result.seed}, path=${result.counterexamplePath}, runs=${result.numRuns}`);
    }
  }
}
function nested(depth: number) { return "[".repeat(depth) + "0" + "]".repeat(depth); }

test("synthetic interoperability edge corpus agrees with the actual Rust codec", { timeout: 60000 }, async t => {
  const { oracle } = await fixture(t);
  const cases = [
    JSON.stringify({ jsonrpc: "2.0", id: "😃".repeat(65), method: "read" }),
    JSON.stringify({ jsonrpc: "2.0", id: 1, method: "😃".repeat(65) }),
    '{"jsonrpc":"2.0","id":1e309,"method":"read"}',
    '{"jsonrpc":"2.0","id":1,"method":"read","params":{"nested":1e309}}',
    '{"jsonrpc":"2.0","id":1,"method":"\\ud800"}',
    '{"jsonrpc":"2.0","id":0.14472694642056844,"method":"read"}',
    '{"jsonrpc":"2.0","id":1,"method":"read","params":{"__proto__":1}}',
    ...[126, 127, 128, 129].map(nested),
    ...[65536, 65537].map(size => '{"jsonrpc":"2.0","id":1,"method":"read"}'.padEnd(size, " ")),
    JSON.stringify({ jsonrpc: "2.0", id: 1, method: "read", params: { text: "😃".repeat(17000) } }),
    ...[126, 127, 128].map(depth => `{"jsonrpc":"2.0","id":1,"method":"read","params":${nested(depth)}}`),
  ];
  for (const [index, raw] of cases.entries()) {
    assert.ok(isDeepStrictEqual(codec(raw), await oracle.query({ mode: "decode", raw })), `Synthetic codec edge ${index}`);
  }
});

test("seeded malformed-input differential fuzzing has matching bounded codec dispositions", { timeout: 60000 }, async t => {
  const { oracle } = await fixture(t);
  const scalar = fc.constantFrom("a", "界", "😃", "\u0000", "\ud800", "\udfff");
  const text = fc.array(scalar, { maxLength: 140 }).map(parts => parts.join(""));
  const envelope = fc.record({
    jsonrpc: fc.constantFrom("2.0", "1.0", null),
    method: fc.oneof(text, fc.jsonValue()),
    id: fc.oneof(text, fc.jsonValue()),
    params: fc.jsonValue(),
  });
  const raw = fc.oneof(
    fc.jsonValue().map(value => JSON.stringify(value)),
    envelope.map(value => JSON.stringify(value)),
    fc.array(envelope, { maxLength: 10 }).map(value => JSON.stringify(value)),
    envelope.map(value => JSON.stringify(value).slice(0, -1)),
    fc.integer({ min: 1, max: 140 }).map(nested),
    fc.constantFrom("{", "", "null", "1e309", '"\\ud800"'),
  );
  let mismatch = "";
  function difference(a: unknown, b: unknown, path = ""): string {
    if (isDeepStrictEqual(a, b)) return "";
    if (a && b && typeof a === "object" && typeof b === "object") {
      for (const key of new Set([...Object.keys(a), ...Object.keys(b)])) {
        const label = ["entries", "error", "batch", "method", "id", "idPresent", "params"].includes(key) || /^\d{1,5}$/.test(key) ? key : "dictionary-key";
        const next = difference((a as Record<string, unknown>)[key], (b as Record<string, unknown>)[key], path + "/" + label);
        if (next) return next;
      }
    }
    return path;
  }
  try {
    await check(fc.asyncProperty(raw, async raw => {
      const left = codec(raw), right = await oracle.query({ mode: "decode", raw });
      const equal = isDeepStrictEqual(left, right);
      if (!equal) mismatch = difference(left, right);
      return equal;
    }), 2000);
  } catch (error) { throw new Error(`Codec property mismatch at ${mismatch}; ${(error as Error).message}`); }
});

test("read admission properties match Rust and shared schemas for UUID and numeric representations", { timeout: 60000 }, async t => {
  const { oracle, target } = await fixture(t);
  const uuid = "12345678-1234-4234-8234-123456789abc";
  const ids = fc.constantFrom(uuid, uuid.toUpperCase(), uuid.replaceAll("-", ""), `{${uuid}}`, `urn:uuid:${uuid}`, "not-a-uuid", "00000000-0000-0000-0000-000000000000", "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", "12345678-1234-0234-7234-123456789abc", null);
  // This oracle exercises the native PTY harness, not a removed JSON catalog.
  // Central address/cursor admission is covered by the central RPC fixtures.
  const entries = fc.oneof(
    ids.map(after => ({ method: "axo.runtime.list" as const, params: { target, after } })),
    fc.integer({ min: -2, max: 53 }).map(limit => ({ method: "axo.runtime.list" as const, params: { target, limit } })),
  );
  await check(fc.asyncProperty(entries, async ({ method, params }) => isDeepStrictEqual(
    { valid: remoteMethods[method].safeParse(params).success },
    await oracle.query({ mode: "params", method, raw: JSON.stringify(params) }),
  )), 500);
  for (const number of ["1.0", "1e0", "1E+0", "2.5", "-0", "0.1e1"]) {
    const raw = `{"target":${JSON.stringify(target)},"limit":${number}}`;
    const valid = remoteMethods["axo.runtime.list"].safeParse(JSON.parse(raw)).success;
    assert.ok(isDeepStrictEqual({ valid }, await oracle.query({ mode: "params", method: "axo.runtime.list", raw })), `Numeric representation ${number}`);
  }
});

test("property-generated mutation notifications cannot dispatch and post-dispatch errors preserve hop IDs", async () => {
  const server = createProfileServer(); let mutations = 0;
  for (const method of stateMutationMethods) server.addMethod(method, () => { mutations++; return {}; });
  await check(fc.asyncProperty(fc.array(fc.constantFrom(...stateMutationMethods), { minLength: 1, maxLength: 8 }), async methods => {
    const reply = await serveProfileMessage(server, JSON.stringify(methods.map(method => ({ jsonrpc: "2.0", method, params: {} }))), undefined);
    return reply === null && mutations === 0;
  }), 500);
  server.addMethod("large", () => "x".repeat(65536));
  await check(fc.asyncProperty(fc.array(fc.uuid(), { minLength: 1, maxLength: 8 }), async ids => {
    const result = await serveProfileMessage(server, JSON.stringify(ids.map(id => ({ jsonrpc: "2.0", id, method: "large" }))), undefined);
    return Array.isArray(result) && result.length === ids.length && result.every((reply, i) => reply.id === ids[i] && "error" in reply && reply.error.code === -32004) && Buffer.byteLength(JSON.stringify(result)) <= 65536;
  }), 100);
  for (const [name, result] of [
    ["deep", JSON.parse(nested(128))],
    ["surrogate", "\ud800"],
    ["omitted", { toJSON: () => undefined }],
  ] as const) {
    server.addMethod(name, () => result);
    const reply = await serveProfileMessage(server, JSON.stringify({ jsonrpc: "2.0", id: name, method: name }), undefined);
    assert.ok(reply && !Array.isArray(reply) && "error" in reply);
    assert.equal(reply.id, name);
    assert.equal(reply.error.code, -32004);
  }
});
