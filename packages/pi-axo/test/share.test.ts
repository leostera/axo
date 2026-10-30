import assert from "node:assert/strict";
import test from "node:test";
import {
  buildSharedMessages,
  parseFindings,
  redactSnapshot,
  scrubText,
  slugify,
  type RedactionModels,
  type RedactionReport,
  type SharedSnapshot,
} from "../src/share.js";

const emptyReport = (): RedactionReport => ({ categories: {}, fieldsChecked: 0, fieldsSentToRedactor: 0, classifierUsed: false });

function snapshot(messages: SharedSnapshot["messages"], title = "axo: share sessions"): SharedSnapshot {
  return { version: 1, title, publishedAt: "2026-01-01T00:00:00.000Z", messages };
}

test("the snapshot keeps words and tools, never reasoning or images, and cuts long tool output", () => {
  const branch = [
    { type: "message", id: "u1", message: { role: "user", timestamp: 1, content: [{ type: "text", text: "hi" }, { type: "image", data: "AAAA", mimeType: "image/png" }] } },
    {
      type: "message", id: "a1", message: {
        role: "assistant", timestamp: 2, content: [
          { type: "thinking", thinking: "private musing" },
          { type: "text", text: "Running it." },
          { type: "toolCall", id: "t1", name: "bash", arguments: { command: "ls" } },
        ],
      },
    },
    { type: "message", id: "r1", message: { role: "toolResult", toolCallId: "t1", content: [{ type: "text", text: "x".repeat(5_000) }] } },
    { type: "custom", id: "c1" },
  ];
  const messages = buildSharedMessages(branch);
  assert.deepEqual(messages.map(message => message.role), ["user", "assistant", "tool"]);
  assert.equal(messages[0]!.text, "hi\n[Image omitted]");
  assert.ok(!JSON.stringify(messages).includes("private musing"));
  const tool = messages[2]!.tool!;
  assert.equal(tool.command, "ls");
  assert.equal(tool.status, "completed");
  assert.equal(tool.outputTruncated, true);
  assert.ok(tool.output.length < 4_100);
});

test("known secret shapes and home directories are scrubbed before any model sees them", () => {
  const report = emptyReport();
  const text = [
    "export CLOUDFLARE_API_TOKEN=abcdef1234567890",
    "Authorization: Bearer abcdefghijklmnopqrstuvwxyz",
    "postgres://admin:hunter22@db.internal:5432/app",
    "key ghp_abcdefghijklmnopqrstuvwxyz0123456789",
    "mail leo@example.com",
    "cd /Users/leostera/Developer",
  ].join("\n");
  const scrubbed = scrubText(text, report);
  for (const secret of ["abcdef1234567890", "abcdefghijklmnopqrstuvwxyz", "hunter22", "ghp_", "leo@example.com", "leostera"]) {
    assert.ok(!scrubbed.includes(secret), `${secret} survived:\n${scrubbed}`);
  }
  assert.match(scrubbed, /CLOUDFLARE_API_TOKEN=\[redacted:secret\]/);
  assert.match(scrubbed, /Bearer \[redacted:authorization\]/);
  assert.match(scrubbed, /postgres:\/\/\[redacted:url-credentials\]db\.internal/);
  assert.match(scrubbed, /cd ~\/Developer/);
});

test("Clef sends only likely-sensitive fields to the redactor, and what it names goes everywhere", async () => {
  const seen: string[] = [];
  const models: RedactionModels = {
    triage: async text => text.includes("acme-prod-db") ? 0.9 : 0.01,
    findSensitive: async text => {
      seen.push(text);
      return [{ text: "acme-prod-db", category: "internal-host" }, { text: "db", category: "noise" }];
    },
  };
  const shared = snapshot([
    { id: "1", role: "user", text: "connect to acme-prod-db please", timestamp: null, tool: null, images: [] },
    { id: "2", role: "assistant", text: "Sure, the acme-prod-db cluster.", timestamp: null, tool: null, images: [] },
    { id: "3", role: "assistant", text: "All done.", timestamp: null, tool: null, images: [] },
  ]);
  const report = await redactSnapshot(shared, models);
  assert.equal(report.classifierUsed, true);
  assert.equal(seen.length, 2);
  assert.ok(!JSON.stringify(shared).includes("acme-prod-db"));
  assert.equal(shared.messages[1]!.text, "Sure, the [redacted:internal-host] cluster.");
  assert.equal(shared.messages[2]!.text, "All done.");
  assert.equal(report.categories["internal-host"], 2);
  assert.equal(report.categories.noise, undefined, "names shorter than three characters are ignored");
});

test("without a classifier every field goes to the redactor", async () => {
  let calls = 0;
  const models: RedactionModels = { triage: async () => null, findSensitive: async () => { calls += 1; return []; } };
  const report = await redactSnapshot(snapshot([
    { id: "1", role: "user", text: "one", timestamp: null, tool: null, images: [] },
    { id: "2", role: "assistant", text: "two", timestamp: null, tool: null, images: [] },
  ]), models);
  assert.equal(report.classifierUsed, false);
  assert.equal(calls, 3, "title and both messages");
});

test("any model failure fails the redaction instead of publishing half-checked", async () => {
  const models: RedactionModels = { triage: async () => 0.9, findSensitive: async () => { throw new Error("rate limited"); } };
  await assert.rejects(redactSnapshot(snapshot([
    { id: "1", role: "user", text: "hello", timestamp: null, tool: null, images: [] },
  ]), models), /rate limited/);
});

test("redactor answers must be the expected JSON", () => {
  assert.deepEqual(parseFindings("```json\n{\"redactions\":[{\"text\":\"x-secret\",\"category\":\"api-key\"}]}\n```"), [{ text: "x-secret", category: "api-key" }]);
  assert.deepEqual(parseFindings("{\"redactions\":[{\"text\":\"abc\",\"category\":\"Not Valid!\"}]}"), [{ text: "abc", category: "sensitive" }]);
  assert.throws(() => parseFindings("nothing to see"));
  assert.throws(() => parseFindings("{\"items\":[]}"));
  assert.throws(() => parseFindings("{\"redactions\":[{\"category\":\"x\"}]}"));
});

test("snapshot file names are readable slugs", () => {
  assert.equal(slugify("axo: share sessions"), "axo-share-sessions");
  assert.equal(slugify("[redacted:secret]"), "session");
});
