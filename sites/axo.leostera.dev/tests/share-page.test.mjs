import assert from "node:assert/strict";
import { test } from "node:test";
import { readSnapshot, sharePageHtml, shareRoute, transcriptResponse, SNAPSHOT_ELEMENT_ID } from "../src/share-page.ts";

const shareId = "fuVgs7XzUJNX7wpVhCTqWg";
const snapshot = {
  version: 1,
  title: "riot: zcaml toolchain",
  emoji: "🐫",
  model: { provider: "anthropic", id: "claude-opus-4-5", name: "Claude Opus 4.5" },
  publishedAt: "2026-11-06T23:14:19.610Z",
  messages: [
    { id: "u1", role: "user", text: "could you explore https://github.com/[redacted:internal-resource-identifier] as a toolchain? </script><script>alert(1)</script>", timestamp: 1, tool: null, images: [] },
    { id: "a1#0", role: "tool", text: "", timestamp: 2, images: [], tool: { callId: "t1", name: "bash", kind: "shell", subtitle: null, command: "ls", status: "completed", output: "x", outputTruncated: false } },
    { id: "a1#1", role: "assistant", text: "Done.", timestamp: 3, tool: null, images: [] },
  ],
};
const index = `<!doctype html><html><head>
<meta name="description" content="Axo: chat with the agents." />
<title>axo — your agentic experience olotl</title>
</head><body><div id="root"></div></body></html>`;

test("share paths: the page, and the transcript with .jsonl", () => {
  assert.deepEqual(shareRoute(`/s/${shareId}/riot-zcaml-toolchain`), { kind: "page", shareId });
  assert.deepEqual(shareRoute(`/s/${shareId}`), { kind: "page", shareId });
  assert.deepEqual(shareRoute(`/s/${shareId}/riot-zcaml-toolchain.jsonl`), { kind: "transcript", shareId });
  assert.deepEqual(shareRoute(`/s/${shareId}.jsonl`), { kind: "transcript", shareId });
  assert.equal(shareRoute("/s/short/slug"), null);
  assert.equal(shareRoute(`/s/${shareId}/a/b`), null);
});

test("a share's page carries its preview tags and its snapshot, safely inlined", () => {
  const html = sharePageHtml(index, "https://axo.leostera.dev", shareId, readSnapshot(JSON.stringify(snapshot)));
  assert.match(html, /<title>🐫 riot: zcaml toolchain · Axo<\/title>/);
  assert.match(html, /<meta property="og:title" content="🐫 riot: zcaml toolchain" \/>/);
  const description = /<meta name="description" content="([^"]*)"/.exec(html)?.[1];
  assert.ok(description?.startsWith("could you explore https://github.com/… as a toolchain?"), description);
  assert.ok(description.endsWith("Claude Opus 4.5 · 1 tool call · shared from Axo"), description);
  assert.equal((html.match(/name="description"/g) ?? []).length, 1);
  assert.match(html, /<link rel="alternate" type="application\/jsonl" title="ATXF transcript" href="https:\/\/axo.leostera.dev\/s\/fuVgs7XzUJNX7wpVhCTqWg\/riot-zcaml-toolchain.jsonl" \/>/);
  assert.match(html, /<meta name="robots" content="noindex" \/>/);

  // The prompt's </script> can't end the element early.
  const inline = new RegExp(`<script id="${SNAPSHOT_ELEMENT_ID}" type="application/json">(.*?)</script>`).exec(html)?.[1];
  assert.ok(inline);
  assert.doesNotMatch(inline, /</);
  assert.deepEqual(JSON.parse(inline), { shareId, snapshot });
});

test("older shares take their emoji from the title tool, which isn't counted as a step", () => {
  const { emoji: _emoji, model: _model, ...old } = snapshot;
  const titled = { ...old, messages: [{ id: "a0#0", role: "tool", text: "", timestamp: 1, images: [], tool: { callId: "t0", name: "axo_set_title", kind: "generic", subtitle: null, command: null, status: "completed", output: "Session named 🐫 riot: zcaml toolchain.", outputTruncated: false } }, ...old.messages] };
  const html = sharePageHtml(index, "https://axo.leostera.dev", shareId, readSnapshot(JSON.stringify(titled)));
  assert.match(html, /<title>🐫 riot: zcaml toolchain · Axo<\/title>/);
  assert.match(html, /— 1 tool call · shared from Axo"/);
});

test("a snapshot this version can't read is treated as missing", () => {
  assert.equal(readSnapshot("not json"), null);
  assert.equal(readSnapshot(JSON.stringify({ ...snapshot, version: 2 })), null);
});

test("the transcript downloads as an ATXF file named after the share", async () => {
  const response = transcriptResponse(shareId, readSnapshot(JSON.stringify(snapshot)), "GET");
  assert.equal(response.headers.get("Content-Type"), "application/jsonl; charset=utf-8");
  assert.equal(response.headers.get("Content-Disposition"), 'attachment; filename="riot-zcaml-toolchain.atxf.jsonl"');
  const [header] = (await response.text()).trim().split("\n").map(line => JSON.parse(line));
  assert.equal(header.type, "transcript");
  assert.equal(header.id, shareId);
});
