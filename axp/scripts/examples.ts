// Writes axp/examples/*.axp.jsonl: whole AXP exchanges, one message per line, with real ATXF
// hashes, chains and Ed25519 signatures, so the examples double as test vectors.
//
//   node axp/scripts/examples.ts
//
// Every value is fixed (keys come from fixed seeds, times are constants), so running it again
// writes the same bytes. tests/examples.test.mjs checks the files against the schemas and
// recomputes every hash, chain and signature.

import { createPrivateKey, createPublicKey, sign } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { TranscriptHasher, validateTranscript } from "@leostera/atxf";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const OUT = join(ROOT, "examples");

// ─── Identities ─────────────────────────────────────────────────────────────

const HUB = "wss://hub.example";
const ACCOUNT = "3f2a9c4e-8b1d-4e6f-a0c2-5d7e9f1b3a64";
const HOST_ID = "8d9c4a1b-e183-4b4a-9c3b-7ab8b90b01d1";
const GENERATION = "09d10cb9-0f8f-4fc0-865d-8f5f7f672932";
const NEXT_GENERATION = "4b8e2f6a-1c3d-4e5f-8a9b-0c1d2e3f4a5b";
const HOST_DEVICE = "c6e1b2a3-4d5f-4a6b-8c7d-9e0f1a2b3c4d";
const PHONE_DEVICE = "7a4c1f0e-2b1d-4c0a-9a55-0d2f6c8e1b3a";
const SESSION = "5b7d9f1a-3c5e-4a7b-9d1f-2a4c6e8b0d13";
const SHELL = "e2d4f6a8-0b1c-4d3e-8f5a-6b7c8d9e0f12";
const WORKSPACE = "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d";

/** An Ed25519 key from a fixed 32-byte seed (PKCS#8: a fixed prefix, then the seed). */
function keyFromSeed(byte: number) {
  const der = Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), Buffer.alloc(32, byte)]);
  const privateKey = createPrivateKey({ key: der, format: "der", type: "pkcs8" });
  const spki = createPublicKey(privateKey).export({ format: "der", type: "spki" });
  return { privateKey, publicKey: b64url(spki.subarray(spki.length - 32)) };
}
const b64url = (bytes: Uint8Array) => Buffer.from(bytes).toString("base64url");

const hostKey = keyFromSeed(0x11);
const phoneKey = keyFromSeed(0x22);

/** The signature SPEC §5.2 asks for. */
function authSignature(key: ReturnType<typeof keyFromSeed>, challenge: Buffer, device: string): string {
  const message = Buffer.concat([
    Buffer.from("axp/0.1/auth\n"),
    challenge,
    Buffer.from(`\n${device}\n${HUB}`),
  ]);
  return b64url(sign(null, message, key.privateKey));
}

const HOST_CHALLENGE = Buffer.alloc(32, 0xa1);
const PHONE_CHALLENGE = Buffer.alloc(32, 0xb2);

// ─── The Session's log ──────────────────────────────────────────────────────

const hasher = new TranscriptHasher({
  type: "transcript",
  atxf: "0.1",
  id: SESSION,
  time: "2026-11-02T09:00:00Z",
  source: { agent: "pi", version: "0.70.0" },
  fidelity: { topology: "tree", instructions: "full", tools: "full", ids: "stable" },
} as never);
const header = hasher.header;

type Rec = Record<string, unknown> & { hash: string };
const records: Rec[] = [];
const offers: { count: number; chain: string; heads: string[] }[] = [hasher.commitment()];
function push(record: Record<string, unknown>): Rec {
  const hashed = hasher.push(record as never) as unknown as Rec;
  records.push(hashed);
  offers.push(hasher.commitment());
  return hashed;
}
const offer = (count: number) => ({ count, chain: offers[count].chain });

push({ type: "context", id: "c1", parentId: null, time: "2026-11-02T09:00:00Z", mode: "replace", instructions: [{ name: "preamble", text: "You are a coding assistant." }], toolsAdded: [{ name: "read" }, { name: "bash" }] });
push({ type: "message", id: "u1", parentId: "c1", time: "2026-11-02T09:00:05Z", role: "user", content: "What does README.md say?" });
push({ type: "message", id: "a1", parentId: "u1", time: "2026-11-02T09:00:07Z", role: "assistant", content: [{ type: "tool_call", id: "call-1", name: "read", arguments: { path: "README.md" } }], stop: "tool_use" });
push({ type: "message", id: "t1", parentId: "a1", time: "2026-11-02T09:00:07Z", role: "tool", toolCallId: "call-1", content: "# Demo\n\nA demo project." });
push({ type: "message", id: "a2", parentId: "t1", time: "2026-11-02T09:00:09Z", role: "assistant", content: [{ type: "text", text: "It is a one-line description of a demo project." }], stop: "end" });
// The phone's prompt (command.axp.jsonl) and the reply to it.
const COMMAND_ID = "cmd_q8ZpL2vR7sKx";
push({ type: "message", id: "u2", parentId: "a2", time: "2026-11-02T09:01:00Z", role: "user", content: "Add a section on pairing.", ext: { axp: { commandId: COMMAND_ID } } });
push({ type: "message", id: "a3", parentId: "u2", time: "2026-11-02T09:01:04Z", role: "assistant", content: [{ type: "text", text: "Added a Pairing section to README.md." }], stop: "end" });

{
  const text = [header, ...records].map((r) => JSON.stringify(r)).join("\n") + "\n";
  const problems = validateTranscript(text).diagnostics.filter((d: { severity: string }) => d.severity === "error");
  if (problems.length) throw new Error(`the example log is not valid ATXF: ${JSON.stringify(problems)}`);
  mkdirSync(OUT, { recursive: true });
  writeFileSync(join(OUT, "session.atxf.jsonl"), text);
}

// ─── Exchanges ──────────────────────────────────────────────────────────────

type Line = { from: string; to: string; note?: string; message: Record<string, unknown> };
const req = (id: number, method: string, params: unknown) => ({ jsonrpc: "2.0", id, method, params });
const ok = (id: number, result: unknown) => ({ jsonrpc: "2.0", id, result });
const fail = (id: number, code: number, message: string, data: unknown) => ({ jsonrpc: "2.0", id, error: { code, message, data } });
const notify = (method: string, params: unknown) => ({ jsonrpc: "2.0", method, params });

function write(name: string, lines: Line[]) {
  writeFileSync(join(OUT, `${name}.axp.jsonl`), lines.map((line) => JSON.stringify(line)).join("\n") + "\n");
}

const EXTENSIONS = { sessions: "0.1", pi: "0.1", terminal: "0.1", upgrade: "0.1" };
const metadata = (name: string | null, lastActivityAt: string | null) => ({
  name,
  createdAt: "2026-11-02T09:00:00Z",
  lastActivityAt,
  archived: false,
  agent: "pi",
  ext: { sessions: { workspaceId: WORKSPACE, workspaceName: "demo" } },
});
const hostEntry = (presence: string, generation: string | null) => ({
  hostId: HOST_ID,
  generation,
  kind: "macos",
  label: "Studio",
  presence,
  lastSeenAt: "2026-11-02T09:00:00Z",
  extensions: EXTENSIONS,
  ext: { sessions: { agents: ["pi"] } },
});

function hostConnects(): Line[] {
  return [
    { from: "host", to: "hub", note: "The host dials the hub and says who it is.", message: req(1, "axp.hello", { axp: "0.1", role: "host", device: HOST_DEVICE, host: { hostId: HOST_ID, generation: GENERATION, kind: "macos", label: "Studio" }, extensions: EXTENSIONS, limits: { messageBytes: 1048576 } }) },
    { from: "hub", to: "host", note: "The negotiated extensions, the hub's limits, and a challenge.", message: ok(1, { axp: "0.1", role: "hub", challenge: b64url(HOST_CHALLENGE), extensions: EXTENSIONS, limits: { messageBytes: 65536 } }) },
    { from: "host", to: "hub", note: "The host signs the challenge with its device key.", message: req(2, "axp.auth", { signature: authSignature(hostKey, HOST_CHALLENGE, HOST_DEVICE) }) },
    { from: "hub", to: "host", message: ok(2, { account: ACCOUNT, device: HOST_DEVICE, role: "host" }) },
  ];
}
function phoneConnects(): Line[] {
  return [
    { from: "client", to: "hub", message: req(1, "axp.hello", { axp: "0.1", role: "client", device: PHONE_DEVICE, extensions: { sessions: "0.1", pi: "0.1", terminal: "0.1" } }) },
    { from: "hub", to: "client", message: ok(1, { axp: "0.1", role: "hub", challenge: b64url(PHONE_CHALLENGE), extensions: { sessions: "0.1", pi: "0.1", terminal: "0.1" }, limits: { messageBytes: 65536 } }) },
    { from: "client", to: "hub", message: req(2, "axp.auth", { signature: authSignature(phoneKey, PHONE_CHALLENGE, PHONE_DEVICE) }) },
    { from: "hub", to: "client", message: ok(2, { account: ACCOUNT, device: PHONE_DEVICE, role: "client" }) },
  ];
}

write("pairing", [
  { from: "client", to: "hub", note: "A signed-in phone asks for a code to add a Mac.", message: req(7, "axp.pair.create", { role: "host", label: "Studio" }) },
  { from: "hub", to: "client", note: "The phone shows the code, or the URI as a QR code or an install link.", message: ok(7, { code: "7KQ2-M9XD", uri: "axp://hub.example/pair/7KQ2-M9XD", expiresAt: "2026-11-02T08:10:00Z" }) },
  { from: "host", to: "hub", note: "On a fresh connection, the Mac redeems the code with a key it just generated. No hello: this is the only call allowed.", message: req(1, "axp.pair.redeem", { code: "7kq2-m9xd", publicKey: hostKey.publicKey, role: "host", kind: "macos", label: "Studio", hostId: HOST_ID }) },
  { from: "hub", to: "host", note: "The hub binds the key and the hostId to a new device, answers, and closes the connection.", message: ok(1, { account: ACCOUNT, device: HOST_DEVICE, pairedAt: "2026-11-02T08:01:12Z" }) },
  ...hostConnects().map((line) => (line.message.id === 1 && line.from === "host" ? { ...line, note: "From now on the Mac connects with hello and auth." } : line)),
]);

const SUMMARY = { sessionId: SESSION, metadataVersion: 3, metadata: metadata("README tour", "2026-11-02T09:00:09Z"), status: "ready", log: offer(5) };

write("replication", [
  ...hostConnects(),
  { from: "host", to: "hub", note: "The host announces its Sessions and what each log holds.", message: req(3, "axp.host.announce", { sessions: [SUMMARY] }) },
  { from: "hub", to: "host", note: "The hub holds the first two records of this log.", message: ok(3, { sessions: [{ sessionId: SESSION, log: offer(2) }] }) },
  { from: "hub", to: "host", note: "So it opens the log on the host from there. The hub serves clients from its replica; the host serves the hub.", message: req(100, "axp.log.open", { hostId: HOST_ID, sessionId: SESSION, have: offer(2) }) },
  { from: "host", to: "hub", note: "The records after position 2. The hub checks every hash and that the chain ends at `have.chain`, then stores them.", message: ok(100, { header: null, from: 2, records: records.slice(2, 5), have: offer(5), older: null, slots: [] }) },
  { from: "host", to: "hub", note: "Later, Pi writes two records. The log is still open, so the host pushes them.", message: notify("axp.log.records", { hostId: HOST_ID, sessionId: SESSION, from: 5, records: records.slice(5, 7), have: offer(7) }) },
  { from: "hub", to: "host", note: "The hub acknowledges once the batch is durable.", message: notify("axp.log.ack", { hostId: HOST_ID, sessionId: SESSION, count: 7 }) },
  { from: "host", to: "hub", message: req(4, "axp.session.update", { sessionId: SESSION, status: "ready", log: offer(7) }) },
  { from: "hub", to: "host", message: ok(4, { applied: true }) },
]);

const SESSION_ENTRY = (count: number, status: string) => ({ hostId: HOST_ID, ...SUMMARY, status, log: offer(count) });

write("reading", [
  ...phoneConnects(),
  { from: "client", to: "hub", message: req(3, "axp.hosts.list", {}) },
  { from: "hub", to: "client", message: ok(3, { hosts: [hostEntry("online", GENERATION)] }) },
  { from: "client", to: "hub", message: req(4, "axp.sessions.list", { hostId: HOST_ID }) },
  { from: "hub", to: "client", message: ok(4, { sessions: [SESSION_ENTRY(5, "ready")] }) },
  { from: "client", to: "hub", message: req(5, "axp.subscribe", {}) },
  { from: "hub", to: "client", message: ok(5, {}) },
  { from: "client", to: "hub", note: "The phone holds nothing yet and wants the last two records first.", message: req(6, "axp.log.open", { hostId: HOST_ID, sessionId: SESSION, window: 2 }) },
  { from: "hub", to: "client", note: "The header, the last two records, and `older: 3`: records below position 3 exist and were not sent.", message: ok(6, { header, from: 3, records: records.slice(3, 5), have: offer(5), older: 3, slots: [] }) },
  { from: "client", to: "hub", note: "Scrolling up pages back.", message: req(7, "axp.log.older", { hostId: HOST_ID, sessionId: SESSION, before: 3, limit: 64 }) },
  { from: "hub", to: "client", note: "Now the phone holds the start, and checks the whole chain.", message: ok(7, { from: 0, records: records.slice(0, 3), older: null }) },
  { from: "hub", to: "client", note: "The agent is writing a reply: a slot, never stored.", message: notify("axp.slot", { hostId: HOST_ID, sessionId: SESSION, slot: "reply", value: { type: "message", id: "a3", parentId: "u2", time: "2026-11-02T09:01:02Z", role: "assistant", content: [{ type: "text", text: "Adding a Pair" }] }, at: "2026-11-02T09:01:02Z" }) },
  { from: "hub", to: "client", message: notify("axp.log.records", { hostId: HOST_ID, sessionId: SESSION, from: 5, records: records.slice(5, 7), have: offer(7) }) },
  { from: "client", to: "hub", message: notify("axp.log.ack", { hostId: HOST_ID, sessionId: SESSION, count: 7 }) },
  { from: "hub", to: "client", message: notify("axp.slot", { hostId: HOST_ID, sessionId: SESSION, slot: "reply", value: null, at: "2026-11-02T09:01:04Z" }) },
  { from: "hub", to: "client", message: notify("axp.sessions.changed", { hostId: HOST_ID, sessions: [SESSION_ENTRY(7, "ready")] }) },
]);

write("command", [
  { from: "client", to: "hub", note: "The phone sends a prompt. It names the host, the Session and a fresh commandId.", message: req(8, "pi.prompt", { hostId: HOST_ID, generation: GENERATION, sessionId: SESSION, commandId: COMMAND_ID, text: "Add a section on pairing." }) },
  { from: "hub", to: "host", note: "The hub checks the account owns the host, then forwards the call with its own id and `from`.", message: req(57, "pi.prompt", { hostId: HOST_ID, generation: GENERATION, sessionId: SESSION, commandId: COMMAND_ID, text: "Add a section on pairing.", from: { device: PHONE_DEVICE } }) },
  { from: "host", to: "hub", note: "The connection drops before the receipt arrives.", message: notify("axp.bye", { reason: "network" }) },
  { from: "hub", to: "client", note: "So the outcome is unknown. The prompt may or may not have been taken.", message: fail(8, -32012, "Outcome unknown", { retry: "unknown" }) },
  { from: "client", to: "hub", note: "Commands are safe to resend with the same commandId.", message: req(9, "pi.prompt", { hostId: HOST_ID, generation: GENERATION, sessionId: SESSION, commandId: COMMAND_ID, text: "Add a section on pairing." }) },
  { from: "hub", to: "host", note: "The host has reconnected; the hub forwards the resent prompt.", message: req(58, "pi.prompt", { hostId: HOST_ID, generation: GENERATION, sessionId: SESSION, commandId: COMMAND_ID, text: "Add a section on pairing.", from: { device: PHONE_DEVICE } }) },
  { from: "host", to: "hub", note: "The host had taken it the first time, so it does not prompt again.", message: ok(58, { receipt: "accepted", duplicate: true }) },
  { from: "hub", to: "client", message: ok(9, { receipt: "accepted", duplicate: true }) },
  { from: "hub", to: "client", note: "The effect arrives in the log: a user message carrying the commandId, covered by its hash.", message: notify("axp.log.records", { hostId: HOST_ID, sessionId: SESSION, from: 5, records: records.slice(5, 6), have: offer(6) }) },
  { from: "client", to: "hub", message: notify("axp.log.ack", { hostId: HOST_ID, sessionId: SESSION, count: 6 }) },
]);

// The host lost its last two records (a restored disk) and wrote nothing new yet.
write("divergence", [
  ...hostConnects().map((line) => line.message.method === "axp.hello" ? { ...line, message: req(1, "axp.hello", { ...(line.message.params as object), host: { hostId: HOST_ID, generation: NEXT_GENERATION, kind: "macos", label: "Studio" } }) } : line),
  { from: "host", to: "hub", note: "After a restore, the host's log holds five records.", message: req(3, "axp.host.announce", { sessions: [{ ...SUMMARY, log: offer(5) }] }) },
  { from: "hub", to: "host", note: "The hub's replica holds seven.", message: ok(3, { sessions: [{ sessionId: SESSION, log: offer(7) }] }) },
  { from: "hub", to: "host", message: req(200, "axp.log.open", { hostId: HOST_ID, sessionId: SESSION, have: offer(7) }) },
  { from: "host", to: "hub", note: "The host cannot serve a reader that is ahead of it.", message: fail(200, -32020, "Diverged", { retry: "never", have: offer(5) }) },
  { from: "host", to: "hub", note: "The host stops writing and checks where the copies agree.", message: req(5, "axp.log.chains", { hostId: HOST_ID, sessionId: SESSION, positions: [5] }) },
  { from: "hub", to: "host", note: "They agree at five, so the host's log is a prefix of the replica.", message: ok(5, { chains: [offers[5].chain] }) },
  { from: "host", to: "hub", note: "The host reads back what it lost.", message: req(6, "axp.log.open", { hostId: HOST_ID, sessionId: SESSION, have: offer(5) }) },
  { from: "hub", to: "host", message: ok(6, { header: null, from: 5, records: records.slice(5, 7), have: offer(7), older: null, slots: [] }) },
  { from: "host", to: "hub", message: req(7, "axp.log.close", { hostId: HOST_ID, sessionId: SESSION }) },
  { from: "hub", to: "host", message: ok(7, {}) },
  { from: "host", to: "hub", note: "Recovered, the host reports its log again.", message: req(8, "axp.session.update", { sessionId: SESSION, log: offer(7) }) },
  { from: "hub", to: "host", message: ok(8, { applied: true }) },
]);

const screen = { rows: 3, cols: 40, cursor: { row: 2, col: 2 }, lines: ["~/demo $ ls", "README.md  src", "$ "] };
write("terminal", [
  { from: "client", to: "hub", message: req(10, "terminal.attach", { hostId: HOST_ID, sessionId: SESSION, shellId: SHELL }) },
  { from: "hub", to: "host", message: req(70, "terminal.attach", { hostId: HOST_ID, sessionId: SESSION, shellId: SHELL, from: { device: PHONE_DEVICE } }) },
  { from: "host", to: "hub", note: "The screen as text, and the output position it reflects.", message: ok(70, { screen, seq: 4096 }) },
  { from: "hub", to: "client", message: ok(10, { screen, seq: 4096 }) },
  { from: "client", to: "hub", note: "`seq` counts the bytes this client sent to the shell, so a resend is not typed twice.", message: req(11, "terminal.input", { hostId: HOST_ID, sessionId: SESSION, shellId: SHELL, seq: 0, data: b64url(Buffer.from("git status\r")) }) },
  { from: "hub", to: "host", message: req(71, "terminal.input", { hostId: HOST_ID, sessionId: SESSION, shellId: SHELL, seq: 0, data: b64url(Buffer.from("git status\r")), from: { device: PHONE_DEVICE } }) },
  { from: "host", to: "hub", message: ok(71, { seq: 11 }) },
  { from: "hub", to: "client", message: ok(11, { seq: 11 }) },
  { from: "host", to: "hub", note: "Output goes only to attached connections and is never stored.", message: notify("terminal.output", { hostId: HOST_ID, sessionId: SESSION, shellId: SHELL, seq: 4096, data: b64url(Buffer.from("git status\r\nOn branch main\r\n$ ")) }) },
  { from: "hub", to: "client", message: notify("terminal.output", { hostId: HOST_ID, sessionId: SESSION, shellId: SHELL, seq: 4096, data: b64url(Buffer.from("git status\r\nOn branch main\r\n$ ")) }) },
]);

// A batch too large for the hub's 64 KiB messages travels in fragments.
{
  const big = notify("axp.log.records", { hostId: HOST_ID, sessionId: SESSION, from: 5, records: records.slice(5, 7), have: offer(7) });
  const bytes = Buffer.from(JSON.stringify(big));
  const size = Math.ceil(bytes.length / 3);
  const parts = [0, 1, 2].map((i) => bytes.subarray(i * size, (i + 1) * size));
  write("fragments", [
    { from: "host", to: "hub", note: "Say the hub accepted only small messages: the host cuts the batch's UTF-8 bytes into parts.", message: notify("axp.fragment", { message: "m1", part: 0, parts: 3, priority: "durable", data: b64url(parts[0]) }) },
    { from: "host", to: "hub", message: notify("axp.fragment", { message: "m1", part: 1, parts: 3, priority: "durable", data: b64url(parts[1]) }) },
    { from: "hub", to: "host", message: req(300, "axp.ping", {}) },
    { from: "host", to: "hub", note: "A response can overtake the rest of a durable message: it is in the control class.", message: ok(300, {}) },
    { from: "host", to: "hub", note: "The hub joins the parts and handles the result as one `axp.log.records`.", message: notify("axp.fragment", { message: "m1", part: 2, parts: 3, priority: "durable", data: b64url(parts[2]) }) },
  ]);
}

console.log(`wrote ${OUT}`);
