import assert from "node:assert/strict";
import { test } from "node:test";
import { inlineSpans, parseMarkdown } from "../src/chat/markdown.ts";
import { ChatTranscript, type PiEventRecord } from "../src/chat/transcript.ts";
import { appendTranscript, VoicePrompt, voiceMessages, waveformHeight, type DictationEngine, type HeardText } from "../src/chat/voice.ts";
import { parseRoute, routePath } from "../src/chat/route.ts";
import { ChatWorkbench, lastActivity, recentChatList, shortAge, type ChatBackend, type MacConnection } from "../src/chat/workbench.ts";

const stream = "41c77dd7-f2dc-4e91-b481-1507b62ec118";
const hostId = "1e1e7f91-3d8f-4f97-8f71-4fc7d53313c6";
const hostGeneration = "f9c5761c-3b2d-42a8-bb19-9a8c0b8cf230";
const workspaceId = "04d389d1-9896-420e-9b42-fc7835522937";

function event(sequence: number, name: string, data: unknown): PiEventRecord {
  return { streamId: stream, sequence, name, data };
}
function said(sequence: number, role: string, content: unknown, extra: Record<string, unknown> = {}): PiEventRecord {
  return event(sequence, "message.end", { message: { role, content, ...extra } });
}

// MARK: - Markdown

test("markdown splits a reply where its look changes", () => {
  const blocks = parseMarkdown("# Title\n\nSome **bold** words.\n\n- one\n  - two\n1. first\n> quoted\n\n---\n| a | b |\n|---|:-:|\n| 1 | 2 |\n```ts\nconst x = 1;\n```");
  assert.deepEqual(blocks.map(block => block.kind), ["heading", "paragraph", "listItem", "listItem", "listItem", "quote", "rule", "table", "code"]);
  assert.deepEqual(blocks[3], { kind: "listItem", marker: { kind: "bullet" }, depth: 1, text: "two" });
  assert.deepEqual(blocks[4], { kind: "listItem", marker: { kind: "number", value: 1 }, depth: 0, text: "first" });
  assert.deepEqual(blocks[7], { kind: "table", header: ["a", "b"], rows: [["1", "2"]] });
  assert.deepEqual(blocks[8], { kind: "code", language: "ts", text: "const x = 1;" });
});

test("an unclosed code fence runs to the end, so a reply still arriving keeps its code", () => {
  assert.deepEqual(parseMarkdown("Look:\n```\nline one\nline two"), [
    { kind: "paragraph", text: "Look:" },
    { kind: "code", language: null, text: "line one\nline two" },
  ]);
});

test("inline links are kept only for http and https; other targets leave the label", () => {
  assert.deepEqual(inlineSpans("see [docs](https://x.dev), [bad](javascript:alert) and [`a.ts`](src/a.ts)"), [
    { kind: "text", text: "see " },
    { kind: "link", children: [{ kind: "text", text: "docs" }], href: "https://x.dev" },
    { kind: "text", text: ", " },
    { kind: "text", text: "bad" },
    { kind: "text", text: " and " },
    { kind: "code", text: "a.ts" },
  ]);
});

test("bold and italics hold code and links, as replies write them", () => {
  assert.deepEqual(inlineSpans("**`agent` Worker** — *very* nice, snake_case_name stays"), [
    { kind: "strong", children: [{ kind: "code", text: "agent" }, { kind: "text", text: " Worker" }] },
    { kind: "text", text: " — " },
    { kind: "emphasis", children: [{ kind: "text", text: "very" }] },
    { kind: "text", text: " nice, snake_case_name stays" },
  ]);
});

// MARK: - Transcript

test("a tool's result fills in the tool that asked, and is not a message of its own", () => {
  const transcript = new ChatTranscript();
  transcript.apply(said(1, "user", "list files"));
  transcript.apply(said(2, "assistant", [
    { type: "text", text: "Looking." },
    { type: "toolCall", id: "call-1", name: "bash", arguments: { command: "ls" } },
  ]));
  transcript.apply(said(3, "toolResult", [{ type: "text", text: "README.md" }], { toolCallId: "call-1" }));
  assert.deepEqual(transcript.messages.map(message => message.role), ["user", "assistant", "tool"]);
  const tool = transcript.messages[2]!.tool!;
  assert.equal(tool.command, "ls");
  assert.equal(tool.status, "completed");
  assert.equal(tool.output, "README.md");
});

test("a failed tool says so, and a result that came first is used when the call arrives", () => {
  const transcript = new ChatTranscript();
  transcript.apply(said(1, "toolResult", "boom", { toolCallId: "call-9", isError: true }));
  transcript.apply(said(2, "assistant", [{ type: "toolCall", id: "call-9", name: "read", arguments: { path: "a.txt" } }]));
  assert.equal(transcript.messages[0]!.tool!.status, "failed");
  assert.equal(transcript.messages[0]!.tool!.subtitle, "a.txt");
});

test("replaying an event never repeats a message, and the reply being written goes once it is whole", () => {
  const transcript = new ChatTranscript();
  transcript.apply(event(1, "agent.start", {}));
  transcript.apply(event(2, "message.update", { message: { role: "assistant", content: [{ type: "text", text: "Hel" }] } }));
  assert.equal(transcript.live[0]!.text, "Hel");
  assert.equal(transcript.working, true);
  transcript.apply(said(3, "assistant", "Hello"));
  transcript.apply(said(3, "assistant", "Hello"));
  assert.equal(transcript.live.length, 0);
  assert.equal(transcript.messages.length, 1);
  transcript.apply(event(4, "agent.end", {}));
  assert.equal(transcript.working, false);
});

test("a question shows until Pi says it is answered", () => {
  const transcript = new ChatTranscript();
  transcript.apply(event(1, "ui.prompt.start", { kind: "confirm", title: "Delete it?" }));
  assert.deepEqual(transcript.question, { kind: "confirm", title: "Delete it?" });
  transcript.apply(event(2, "ui.prompt.end", {}));
  assert.equal(transcript.question, null);
});

test("history overlapping what arrived live is merged without repeats, and older pages go first", () => {
  const live = new ChatTranscript();
  live.apply(said(3, "user", "third"));
  live.apply(said(4, "assistant", "fourth"));
  live.mergeNewest(ChatTranscript.fromHistory([said(2, "assistant", "second"), said(3, "user", "third")]), false);
  assert.deepEqual(live.messages.map(message => message.text), ["second", "third", "fourth"]);
  live.prependOlder(ChatTranscript.fromHistory([said(1, "user", "first"), said(2, "assistant", "second")]));
  assert.deepEqual(live.messages.map(message => message.text), ["first", "second", "third", "fourth"]);
});

test("a picture without its data is named, and one with it is shown", () => {
  const transcript = new ChatTranscript();
  transcript.apply(said(1, "user", [{ type: "text", text: "look" }, { type: "image", mimeType: "image/png", data: "iVBORw0KGgo=" }, { type: "image" }]));
  const message = transcript.messages[0]!;
  assert.equal(message.text, "look\n[Image attachment]");
  assert.equal(message.images.length, 1);
  assert.match(message.images[0]!.src, /^data:image\/png;base64,/);
});

// MARK: - Menu

function session(sessionId: number, updatedAt: string, workspaceName: string | null = "Axo", extra: Record<string, unknown> = {}) {
  return { hostId, sessionId, workspaceId: workspaceName ? workspaceId : null, workspaceName, name: `Chat ${sessionId}`, hasAgent: true, shells: [], layout: null, updatedAt, ...extra };
}
function host(sessions: ReturnType<typeof session>[], status: "online" | "offline" = "online") {
  return { hostId, hostGeneration, label: "Studio", hostKind: "macos", status, stale: false, lastSeenAt: "2026-10-16T12:00:00.000Z", sessions } as never;
}

// The time every snapshot from one Mac shares: when it was sent, not when a chat was active.
const sent = "2026-10-27T12:00:00Z";
const at = (iso: string) => Date.parse(iso) / 1000;

test("a chat's activity is its latest finished message, or its creation, not the snapshot's time", () => {
  assert.equal(lastActivity(session(1, sent, "Axo", { lastMessageAt: at("2026-10-27T09:00:00Z"), createdAt: at("2026-10-26T00:00:00Z") }) as never),
    Date.parse("2026-10-27T09:00:00Z"));
  assert.equal(lastActivity(session(2, sent, "Axo", { lastMessageAt: null, createdAt: at("2026-10-27T11:00:00Z") }) as never),
    Date.parse("2026-10-27T11:00:00Z"), "a chat with no messages yet counts from its creation");
  assert.equal(lastActivity(session(3, sent) as never), 0, "a Mac that reports neither: never the snapshot's time");
});

test("the recent list puts every chat on every Mac in one list, the most recently active first", () => {
  const other = { ...(host([session(9, sent, "Axo", { lastMessageAt: at("2026-10-27T10:30:00Z") })]) as object), hostId: "11111111-2222-4333-8444-555555555555", label: "Laptop" } as never;
  const list = recentChatList([host([
    session(1, sent, "Axo", { lastMessageAt: at("2026-10-27T08:00:00Z") }),
    session(2, sent, "Website", { lastMessageAt: at("2026-10-27T11:00:00Z") }),
    session(3, sent, null, { hasAgent: false, lastMessageAt: at("2026-10-27T11:59:00Z") }),
    session(4, sent, null, { createdAt: at("2026-10-27T10:00:00Z") }),
  ]), other]);
  assert.deepEqual(list.map(entry => entry.session.sessionId), [2, 9, 4, 1], "no bare terminals; across Workspaces and Macs");
});

test("the list does not move when snapshots are sent again, only when a chat is active", () => {
  const before = recentChatList([host([session(1, sent), session(2, sent), session(3, sent, "Axo", { lastMessageAt: at("2026-10-27T11:00:00Z") })])]);
  const resent = recentChatList([host([session(1, sent), session(2, "2026-10-27T12:05:00Z"), session(3, sent, "Axo", { lastMessageAt: at("2026-10-27T11:00:00Z") })])]);
  assert.deepEqual(before.map(entry => entry.session.sessionId), [3, 2, 1]);
  assert.deepEqual(resent.map(entry => entry.session.sessionId), [3, 2, 1]);
});

test("ages are short, as on the Mac", () => {
  const now = Date.parse(sent);
  assert.deepEqual([30, 300, 3 * 3_600, 2 * 86_400, 4 * 604_800].map(seconds => shortAge(now - seconds * 1000, now)), ["now", "5m", "3h", "2d", "4w"]);
});

// MARK: - Routes and voice

test("the URL names the open chat on its Mac, and anything else is a new chat", () => {
  assert.deepEqual(parseRoute("/app", `/app/${hostId}/12`), { kind: "chat", hostId, sessionId: 12 });
  assert.deepEqual(parseRoute("/app", `/app/${hostId}/12/`), { kind: "chat", hostId, sessionId: 12 });
  for (const path of ["/app", "/app/", `/app/${hostId}`, `/app/${hostId}/0`, `/app/${hostId}/x`, `/app/${hostId}/1/more`, `/elsewhere/${hostId}/1`]) {
    assert.deepEqual(parseRoute("/app", path), { kind: "new" }, path);
  }
  assert.equal(routePath("/app", hostId, { kind: "chat", sessionId: 12 }), `/app/${hostId}/12`);
  assert.equal(routePath("/app", hostId, { kind: "new", workspaceId: null }), "/app");
  assert.equal(routePath("/app", null, null), "/app");
});

/** A stand-in for the microphone and recogniser, driven by the test. */
class FakeDictation implements DictationEngine {
  audioLevel = 0.5;
  allowed = true;
  heard: ((text: HeardText) => void) | null = null;
  interrupted: ((message: string) => void) | null = null;
  final = "";
  cancelled = 0;
  async requestPermission() { return this.allowed; }
  async start(heard: (text: HeardText) => void, interrupted: (message: string) => void) {
    this.heard = heard;
    this.interrupted = interrupted;
  }
  async finish() { return this.final; }
  cancel() { this.cancelled += 1; }
}

test("voice: words show as heard, Stop puts them in the box and Send sends them", async () => {
  const engine = new FakeDictation();
  const voice = new VoicePrompt(engine);
  await voice.start();
  assert.equal(voice.state.kind, "listening");
  engine.heard!({ settled: "look at", tentative: "the lo" });
  assert.deepEqual(voice.state, { kind: "listening", heard: { settled: "look at", tentative: "the lo" } });
  engine.final = " look at the logs ";
  await voice.finish("draft");
  assert.equal(voice.state.kind, "idle");
  assert.deepEqual({ text: voice.transcript?.text, delivery: voice.transcript?.delivery }, { text: "look at the logs", delivery: "draft" });
  voice.consume(voice.transcript!);
  assert.equal(voice.transcript, null);

  await voice.start();
  engine.final = "ship it";
  await voice.finish("send");
  assert.equal(voice.transcript?.delivery, "send");
});

test("voice: a cancel forgets what was heard, and failures say why", async () => {
  const engine = new FakeDictation();
  const voice = new VoicePrompt(engine);
  await voice.start();
  voice.cancel();
  assert.equal(voice.state.kind, "idle");
  engine.heard!({ settled: "too late", tentative: "" });
  assert.equal(voice.state.kind, "idle", "words after a cancel never come back");

  await voice.start();
  engine.final = "  ";
  await voice.finish("draft");
  assert.deepEqual(voice.state, { kind: "failed", message: voiceMessages.noSpeech });
  voice.dismissFailure();

  engine.allowed = false;
  await voice.start();
  assert.deepEqual(voice.state, { kind: "failed", message: voiceMessages.microphoneDenied });

  engine.allowed = true;
  await voice.start();
  engine.interrupted!("No microphone is available.");
  assert.deepEqual(voice.state, { kind: "failed", message: "No microphone is available." });
});

test("voice: dictated words go after what was typed, with one space", () => {
  assert.equal(appendTranscript("", "hello there"), "hello there");
  assert.equal(appendTranscript("Look at", "the logs"), "Look at the logs");
  assert.equal(appendTranscript("Look at\n", "the logs"), "Look at\nthe logs");
});

test("voice: the waveform shows quiet speech, stays flat in silence and tops out at -18 dB", () => {
  assert.equal(waveformHeight(0), 0);
  assert.equal(waveformHeight(Number.NaN), 0);
  assert.equal(waveformHeight(0.001), 0);
  assert.equal(waveformHeight(10 ** (-18 / 20)), 1);
  assert.ok(waveformHeight(0.01) > 0 && waveformHeight(0.01) < 1);
});

// MARK: - Workbench

class FakeMac implements MacConnection {
  active = true;
  calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  failNext: Error | null = null;
  workspaces = [{ workspaceId, name: "Axo" }];
  onEvent: ((event: never) => void) | null = null;

  async call(method: string, params: Record<string, unknown>): Promise<never> {
    this.calls.push({ method, params });
    if (this.failNext) {
      const error = this.failNext;
      this.failNext = null;
      throw error;
    }
    if (method === "axo.remote.workspace.list") return { workspaces: this.workspaces } as never;
    if (method === "axo.remote.session.create" || method === "axo.remote.workspace.session.create") return { session: session(7, "2026-10-16T14:00:00Z") } as never;
    return { accepted: true } as never;
  }

  close(): void { this.active = false; }
}

async function workbenchWith(sessions = [session(1, "2026-10-16T10:00:00Z")]) {
  const mac = new FakeMac();
  const backend: ChatBackend = {
    listHosts: async () => [host(sessions)],
    listPiEvents: async () => ({ events: [], next: null }),
    connectHost: async (_reference, onEvent) => {
      mac.onEvent = onEvent as never;
      return mac;
    },
  };
  let id = 0;
  const workbench = new ChatWorkbench(backend, [1], () => `pending-${++id}`);
  await workbench.refreshHosts();
  await new Promise(resolve => setTimeout(resolve, 0));
  return { workbench, mac };
}

test("a new chat's first message starts it in the Mac's Home Workspace and moves the words there", async () => {
  const { workbench, mac } = await workbenchWith();
  mac.workspaces = [{ workspaceId, name: "Axo" }, { workspaceId: "8f8f8f8f-0000-4000-8000-000000000000", name: "Home" }];
  assert.equal(workbench.link, "connected");
  workbench.setDraft("Fix the bug");
  assert.deepEqual(await workbench.send(), { kind: "sent" });
  assert.deepEqual(workbench.selection, { kind: "chat", sessionId: 7 });
  const created = mac.calls.filter(call => call.method.endsWith("session.create"));
  assert.deepEqual(created.map(call => call.method), ["axo.remote.session.create"], "however many Workspaces, a new chat goes Home");
  const prompt = mac.calls.find(call => call.method === "axo.remote.session.prompt");
  assert.equal(prompt?.params.text, "Fix the bug");
  assert.equal(prompt?.params.sessionId, 7);
  assert.equal(workbench.draft(), "");
  assert.equal(workbench.chat(7).pending[0]?.state, "sent");
  workbench.dispose();
});

test("a new chat started from a Workspace in the menu starts in that Workspace", async () => {
  const { workbench, mac } = await workbenchWith();
  workbench.newChat(hostId, workspaceId);
  workbench.setDraft("Hello");
  assert.deepEqual(await workbench.send(), { kind: "sent" });
  const created = mac.calls.filter(call => call.method.endsWith("session.create"));
  assert.deepEqual(created.map(call => [call.method, call.params.workspaceId]), [["axo.remote.workspace.session.create", workspaceId]]);
  workbench.dispose();
});

test("a refused message comes back to the box; one whose delivery is uncertain stays, marked", async () => {
  const { workbench, mac } = await workbenchWith();
  workbench.selectChat(hostId, 1);
  workbench.setDraft("first");
  mac.failNext = Object.assign(new Error("busy"), { code: -32000 });
  assert.deepEqual(await workbench.send(), { kind: "failed" });
  assert.equal(workbench.draft(), "first");
  assert.equal(workbench.chat(1).pending.length, 0);

  mac.failNext = new Error("Axo API request timed out: axo.remote.session.prompt");
  assert.deepEqual(await workbench.send(), { kind: "uncertain" });
  assert.equal(workbench.draft(), "");
  assert.equal(workbench.chat(1).pending[0]?.state, "uncertain");
  workbench.dispose();
});

test("a pending message is retired when the agent records it", async () => {
  const { workbench, mac } = await workbenchWith();
  workbench.selectChat(hostId, 1);
  workbench.setDraft("hello there");
  await workbench.send();
  assert.equal(workbench.chat(1).pending.length, 1);
  mac.onEvent!({ type: "host.data", hostId, hostGeneration, event: { type: "pi.event", sessionId: 1, piSessionId: "p", ...said(1, "user", "hello there") } } as never);
  assert.equal(workbench.chat(1).pending.length, 0);
  assert.equal(workbench.chat(1).transcript?.messages[0]?.text, "hello there");
  workbench.dispose();
});

test("stop presses Escape once, only while the agent works", async () => {
  const { workbench, mac } = await workbenchWith();
  workbench.selectChat(hostId, 1);
  await workbench.stop(1);
  assert.equal(mac.calls.filter(call => call.method === "axo.remote.session.key").length, 0);
  mac.onEvent!({ type: "host.data", hostId, hostGeneration, event: { type: "pi.event", sessionId: 1, piSessionId: "p", ...event(1, "agent.start", {}) } } as never);
  await Promise.all([workbench.stop(1), workbench.stop(1)]);
  const keys = mac.calls.filter(call => call.method === "axo.remote.session.key");
  assert.deepEqual(keys.map(call => call.params.key), ["escape"]);
  workbench.dispose();
});

test("a lost connection is tried again, and comes back connected", async () => {
  const { workbench, mac } = await workbenchWith();
  let connects = 0;
  (workbench as unknown as { backend: ChatBackend }).backend.connectHost = async () => {
    connects += 1;
    mac.active = true;
    return mac;
  };
  mac.active = false;
  (workbench as unknown as { connectionLost(): void }).connectionLost();
  assert.equal(workbench.link, "reconnecting");
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(connects, 1);
  assert.equal(workbench.link, "connected");
  workbench.dispose();
});
