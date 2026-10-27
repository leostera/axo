import assert from "node:assert/strict";
import { test } from "node:test";
import { inlineSpans, parseMarkdown } from "../src/chat/markdown.ts";
import { ChatTranscript, type PiEventRecord } from "../src/chat/transcript.ts";
import { chatMenu, ChatWorkbench, recentChats, type ChatBackend, type MacConnection } from "../src/chat/workbench.ts";

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

test("the menu keeps Workspaces in alphabetical order, chats newest first within each, and no bare terminals", () => {
  const sections = chatMenu([host([
    session(1, "2026-10-16T10:00:00Z"),
    session(2, "2026-10-16T12:00:00Z"),
    session(3, "2026-10-16T13:00:00Z", null, { hasAgent: false }),
    session(4, "2026-10-16T14:00:00Z", "Website"),
  ])], hostId, [{ workspaceId: "8f8f8f8f-0000-4000-8000-000000000000", name: "home" }]);
  // Website has the newest chat and home has none: neither moves.
  assert.deepEqual(sections.map(section => section.title), ["Axo", "home", "Website"]);
  assert.deepEqual(sections[0]!.chats.map(chat => chat.session.sessionId), [2, 1]);
  assert.equal(sections[1]!.chats.length, 0);
});

test("a section lists chats active in the last 8 hours, busy ones, and the open one; the rest wait", () => {
  const now = Date.parse("2026-10-27T12:00:00Z");
  const [section] = chatMenu([host([
    session(1, "2026-10-27T11:00:00Z"),
    session(2, "2026-10-27T04:00:01Z"),
    session(3, "2026-10-27T03:59:59Z"),
    session(4, "2026-10-20T00:00:00Z", "Axo", { status: "working" }),
    session(5, "2026-10-19T00:00:00Z", "Axo", { status: "needsAttention" }),
    session(6, "2026-10-18T00:00:00Z"),
    session(7, "2026-10-17T00:00:00Z"),
  ])], hostId, []);
  const ids = (entries: { session: { sessionId: number } }[]) => entries.map(entry => entry.session.sessionId);
  assert.deepEqual(ids(recentChats(section!, now)), [1, 2, 4, 5]);
  assert.deepEqual(ids(recentChats(section!, now, entry => entry.session.sessionId === 7)), [1, 2, 4, 5, 7]);
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
    if (method === "axo.remote.workspace.session.create") return { session: session(7, "2026-10-16T14:00:00Z") } as never;
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

test("a new chat's first message starts it in the Mac's only Workspace and moves the words there", async () => {
  const { workbench, mac } = await workbenchWith();
  assert.equal(workbench.link, "connected");
  workbench.setDraft("Fix the bug");
  assert.deepEqual(await workbench.send(), { kind: "sent" });
  assert.deepEqual(workbench.selection, { kind: "chat", sessionId: 7 });
  const prompt = mac.calls.find(call => call.method === "axo.remote.session.prompt");
  assert.equal(prompt?.params.text, "Fix the bug");
  assert.equal(prompt?.params.sessionId, 7);
  assert.equal(workbench.draft(), "");
  assert.equal(workbench.chat(7).pending[0]?.state, "sent");
  workbench.dispose();
});

test("with several Workspaces the person picks one before anything is sent", async () => {
  const { workbench, mac } = await workbenchWith();
  mac.workspaces = [{ workspaceId, name: "Axo" }, { workspaceId: "8f8f8f8f-0000-4000-8000-000000000000", name: "Home" }];
  workbench.setDraft("Hello");
  const outcome = await workbench.send();
  assert.equal(outcome.kind, "chooseWorkspace");
  assert.equal(mac.calls.some(call => call.method === "axo.remote.workspace.session.create"), false);
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
