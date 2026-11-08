import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import type { AccountEvents, ClientRecord, ClientSession, OpenRequest } from "@axo/app";
import { inlineSpans, parseMarkdown } from "../src/chat/markdown.ts";
import { attachmentsIn, ChatTranscript } from "../src/chat/transcript.ts";
import { conversationRows, levelsOf, matchingCommands, modelsByProvider, pendingLabel, runtimeLabel, slashQuery, withCommand } from "../src/chat/pi-controls.ts";
import type { UploadAsset } from "../src/chat/assets.ts";
import { safeFileName } from "../src/chat/assets.ts";
import { appendTranscript, VoicePrompt, voiceMessages, waveformHeight, type DictationEngine, type HeardText } from "../src/chat/voice.ts";
import { appsResults } from "@axo/protocol";
import { parseRoute, parseSettingsRoute, routePath, settingsPath, type SettingsRoute } from "../src/chat/route.ts";
import { memoryDevice } from "../src/chat/device.ts";
import { chatSections, defaultGrouping, groupOf, holdingSections, parseGrouping, SessionPins, SessionSeen } from "../src/chat/sidebar.ts";
import { ChatWorkbench, inputKeyPins, lastActivity, recentChatList, shortAge, type AccountLink, type ChatBackend, type Session } from "../src/chat/workbench.ts";

const hostId = "1e1e7f91-3d8f-4f97-8f71-4fc7d53313c6";
const hostGeneration = "f9c5761c-3b2d-42a8-bb19-9a8c0b8cf230";
const workspaceId = "04d389d1-9896-420e-9b42-fc7835522937";
const hash = `sha256:${"0".repeat(64)}`;

/** A Pi session file line at `cursor`: a message entry. */
function said(cursor: number, role: string, content: unknown, extra: Record<string, unknown> = {}): ClientRecord {
  const id = `e${cursor}`;
  return { cursor, id, format: "pi/3", hash, line: JSON.stringify({ type: "message", id, parentId: cursor > 1 ? `e${cursor - 1}` : null, timestamp: "2026-10-16T12:00:00.000Z", message: { role, content, ...extra } }) };
}
/** The receipt the Session's Pi writes just before a client's prompt (RFD0024). */
function receipt(cursor: number, commandId: string): ClientRecord {
  return { cursor, id: `e${cursor}`, format: "pi/3", hash, line: JSON.stringify({ type: "custom", id: `e${cursor}`, parentId: null, timestamp: "2026-10-16T12:00:00.000Z", customType: "axo.command", data: { commandId } }) };
}
/** What the Session's Pi writes when it accepts a client's prompt it cannot take at once (RFD0033). */
function queued(cursor: number, commandId: string, text: string, delivery: "followUp" | "steer" | "interrupt" = "followUp", attachments: unknown[] = []): ClientRecord {
  return { cursor, id: `e${cursor}`, format: "pi/3", hash, line: JSON.stringify({ type: "custom", id: `e${cursor}`, parentId: null, timestamp: "2026-10-16T12:00:00.000Z", customType: "axo.command.queued", data: { commandId, delivery, text, attachments } }) };
}
function other(cursor: number): ClientRecord {
  return { cursor, id: `e${cursor}`, format: "pi/3", hash, line: JSON.stringify({ type: "model_change", id: `e${cursor}`, parentId: null, provider: "x", modelId: "y" }) };
}
function transcriptOf(records: ClientRecord[]): ChatTranscript {
  const transcript = new ChatTranscript();
  transcript.append(records);
  return transcript;
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
  const transcript = transcriptOf([
    said(1, "user", "list files"),
    said(2, "assistant", [
      { type: "text", text: "Looking." },
      { type: "toolCall", id: "call-1", name: "bash", arguments: { command: "ls" } },
    ]),
    other(3),
    said(4, "toolResult", [{ type: "text", text: "README.md" }], { toolCallId: "call-1" }),
  ]);
  assert.deepEqual(transcript.messages.map(message => message.role), ["user", "assistant", "tool"]);
  assert.deepEqual(transcript.messages.map(message => message.id), ["e1", "e2", "e2#1"]);
  const tool = transcript.messages[2]!.tool!;
  assert.equal(tool.command, "ls");
  assert.equal(tool.status, "completed");
  assert.equal(tool.output, "README.md");
});

test("a failed tool says so, and a result that came first is used when the call arrives", () => {
  const transcript = transcriptOf([
    said(1, "toolResult", "boom", { toolCallId: "call-9", isError: true }),
    said(2, "assistant", [{ type: "toolCall", id: "call-9", name: "read", arguments: { path: "a.txt" } }]),
  ]);
  assert.equal(transcript.messages[0]!.tool!.status, "failed");
  assert.equal(transcript.messages[0]!.tool!.subtitle, "a.txt");
});

test("records held are never repeated, and the reply being written goes once it is whole", () => {
  const transcript = new ChatTranscript();
  transcript.settle(true);
  transcript.progress("message", { message: { role: "assistant", content: [{ type: "text", text: "Hel" }] } });
  assert.equal(transcript.live[0]!.text, "Hel");
  transcript.append([said(1, "assistant", "Hello")]);
  transcript.append([said(1, "assistant", "Hello")]);
  assert.equal(transcript.live.length, 0);
  assert.equal(transcript.messages.length, 1);
  transcript.settle(false);
  assert.equal(transcript.working, false);
});

test("progress for a reply already recorded is not shown again, as when it arrives late or a chat reopens", () => {
  const transcript = new ChatTranscript();
  transcript.settle(true);
  transcript.append([said(1, "assistant", "Hello", { timestamp: 1000 })]);
  transcript.progress("message", { message: { role: "assistant", timestamp: 1000, content: [{ type: "text", text: "Hello" }] } });
  assert.equal(transcript.live.length, 0, "the recorded reply is not written out again");
  transcript.progress("message", { message: { role: "assistant", timestamp: 2000, content: [{ type: "text", text: "Next" }] } });
  assert.equal(transcript.live[0]!.text, "Next", "the next reply still shows as it is written");
});

test("a reply keeps its key from its first live words to its record, so the screen keeps it", () => {
  const transcript = new ChatTranscript();
  transcript.settle(true);
  transcript.progress("message", { message: { role: "assistant", timestamp: 3000, content: [{ type: "thinking", thinking: "Hmm" }, { type: "text", text: "Hel" }] } });
  const live = transcript.live.map(message => message.key);
  transcript.append([said(1, "assistant", [{ type: "thinking", thinking: "Hmm" }, { type: "text", text: "Hello" }], { timestamp: 3000 })]);
  assert.deepEqual(transcript.messages.map(message => message.key), live);
  assert.notEqual(transcript.messages[0]!.key, transcript.messages[1]!.key);
});

test("a running tool shows its output so far, until its result is recorded", () => {
  const transcript = transcriptOf([said(1, "assistant", [{ type: "toolCall", id: "call-1", name: "bash", arguments: { command: "make" } }])]);
  transcript.progress("call-1", { toolCallId: "call-1", partialResult: { content: [{ type: "text", text: "building" }] } });
  assert.equal(transcript.messages[0]!.tool!.output, "building");
  transcript.append([said(2, "toolResult", "built", { toolCallId: "call-1" })]);
  assert.deepEqual([transcript.messages[0]!.tool!.status, transcript.messages[0]!.tool!.output], ["completed", "built"]);
});

test("a question shows until its slot is cleared", () => {
  const transcript = new ChatTranscript();
  transcript.progress("question", { kind: "confirm", title: "Delete it?" });
  assert.deepEqual(transcript.question, { kind: "confirm", title: "Delete it?" });
  transcript.progress("question", null);
  assert.equal(transcript.question, null);
});

test("older pages go first, and a cut drops what came after it", () => {
  const transcript = transcriptOf([said(3, "user", "third"), said(4, "assistant", "fourth")]);
  transcript.prepend([said(1, "user", "first"), said(2, "assistant", "second"), said(3, "user", "third")]);
  assert.deepEqual(transcript.messages.map(message => message.text), ["first", "second", "third", "fourth"]);
  transcript.cut(2);
  assert.deepEqual(transcript.messages.map(message => message.text), ["first", "second"]);
  assert.equal(transcript.lastCursor, 2);
});

test("a picture without its data is named, and one with it is shown", () => {
  const transcript = transcriptOf([said(1, "user", [{ type: "text", text: "look" }, { type: "image", mimeType: "image/png", data: "iVBORw0KGgo=" }, { type: "image" }])]);
  const message = transcript.messages[0]!;
  assert.equal(message.text, "look\n[Image attachment]");
  assert.equal(message.images.length, 1);
  assert.match(message.images[0]!.src, /^data:image\/png;base64,/);
});

test("a line the format does not know, or a format it does not know, shows nothing", () => {
  const transcript = transcriptOf([
    { cursor: 1, id: null, format: "pi/3", hash, line: "not json" },
    { ...said(2, "user", "elsewhere"), format: "other/1" as never },
    said(3, "user", "here"),
  ]);
  assert.deepEqual(transcript.messages.map(message => message.text), ["here"]);
});

// MARK: - Menu

/** A Session ID for fixture `n`; they sort like the numbers they come from. */
const sid = (n: number) => `${n.toString(16).padStart(8, "0")}-0000-4000-8000-${n.toString(16).padStart(12, "0")}`;
function session(n: number, workspaceName: string | null = "Axo", extra: Partial<Session> = {}): Session {
  return {
    hostId, sessionId: sid(n), workspaceId: workspaceName ? workspaceId : null, workspaceName, name: `Chat ${n}`, emoji: null,
    hasAgent: true, createdAt: null, lastMessageAt: null, archived: false, status: "ready", ...extra,
  };
}
function host(sessions: Session[], status: "online" | "offline" = "online") {
  return { hostId, hostGeneration, label: "Studio", status, lastSeenAt: "2026-10-16T12:00:00.000Z", sessions };
}

const at = (iso: string) => Date.parse(iso) / 1000;

test("a chat's activity is its latest finished message, or its creation", () => {
  assert.equal(lastActivity(session(1, "Axo", { lastMessageAt: at("2026-10-27T09:00:00Z"), createdAt: at("2026-10-26T00:00:00Z") })),
    Date.parse("2026-10-27T09:00:00Z"));
  assert.equal(lastActivity(session(2, "Axo", { createdAt: at("2026-10-27T11:00:00Z") })),
    Date.parse("2026-10-27T11:00:00Z"), "a chat with no messages yet counts from its creation");
  assert.equal(lastActivity(session(3)), 0);
});

test("the recent list puts every chat on every Mac in one list, the most recently active first", () => {
  const laptop = { ...host([session(9, "Axo", { lastMessageAt: at("2026-10-27T10:30:00Z") })]), hostId: "11111111-2222-4333-8444-555555555555", label: "Laptop" };
  const list = recentChatList([host([
    session(1, "Axo", { lastMessageAt: at("2026-10-27T08:00:00Z") }),
    session(2, "Website", { lastMessageAt: at("2026-10-27T11:00:00Z") }),
    session(3, null, { hasAgent: false, lastMessageAt: at("2026-10-27T11:59:00Z") }),
    session(4, null, { createdAt: at("2026-10-27T10:00:00Z") }),
    session(5, null, { archived: true, lastMessageAt: at("2026-10-27T11:58:00Z") }),
  ]), laptop]);
  assert.deepEqual(list.map(entry => entry.session.sessionId), [2, 9, 4, 1].map(sid), "no bare terminals or archived chats; across Workspaces and Macs");
});

// MARK: - Pins and groups

test("pins toggle, drop duplicates and anything that is not an id, and keep only the newest 256", () => {
  const pins = SessionPins.parse(["a", "b", "a", 7, null]);
  assert.deepEqual(pins.ids, ["a", "b"]);
  assert.deepEqual(pins.toggled("c").ids, ["a", "b", "c"]);
  assert.deepEqual(pins.toggled("a").ids, ["b"]);
  assert.deepEqual(SessionPins.parse("nope").ids, []);
  const many = new SessionPins(Array.from({ length: 300 }, (_, index) => `s${index}`));
  assert.equal(many.ids.length, 256);
  assert.equal(many.ids[0], "s44", "the oldest pins go first");
});

test("settings load with the Mac's defaults, and anything missing or out of range takes its default", () => {
  assert.deepEqual(parseGrouping(undefined), defaultGrouping);
  assert.deepEqual(defaultGrouping, {
    activeWindowMinutes: 3, regroupIntervalSeconds: 30, unseenStayActive: true, unseenMarker: "dotAndBold",
    pinnedOrder: "pinned", activeOrder: "name", earlierOrder: "activity", showsGroupTitles: true,
    earlierCollapsed: false, earlierLimit: null,
  });
  const odd = parseGrouping({ activeWindowMinutes: 0, regroupIntervalSeconds: 99_999, activeOrder: "pinned", unseenMarker: "glow", earlierLimit: -3, earlierCollapsed: "yes" });
  assert.equal(odd.activeWindowMinutes, 1);
  assert.equal(odd.regroupIntervalSeconds, 3_600);
  assert.equal(odd.activeOrder, "name", "Active cannot be in pinned order");
  assert.equal(odd.unseenMarker, "dotAndBold");
  assert.equal(odd.earlierLimit, null);
  assert.equal(odd.earlierCollapsed, false);
  assert.equal(parseGrouping({ earlierLimit: 10 }).earlierLimit, 10);
});

test("chats group as on the Mac: pinned, then working, asking, unseen or just active, then earlier", () => {
  const now = Date.parse("2026-10-27T12:00:00Z");
  const seconds = (minutesAgo: number) => Math.floor((now - minutesAgo * 60_000) / 1000);
  const mac = host([
    session(1, "Axo", { name: "Zeta", lastMessageAt: seconds(1) }),
    session(2, "Axo", { name: "Alpha", lastMessageAt: seconds(2) }),
    session(3, "Axo", { name: "Busy", lastMessageAt: seconds(90), status: "working" }),
    session(4, "Axo", { name: "Quiet", lastMessageAt: seconds(60) }),
    session(5, "Axo", { name: "Older", lastMessageAt: seconds(120) }),
    session(6, "Axo", { name: "Pinned old", lastMessageAt: seconds(600) }),
    session(7, "Axo", { name: "Asking", lastMessageAt: seconds(500) }),
  ]);
  const entries = recentChatList([mac]);
  const pins = new SessionPins([sid(6)]);
  // Everything before now was seen, so only the window, status and pins decide.
  const seen = new SessionSeen(now);
  const state = { pins, seen, now, settings: defaultGrouping, asking: new Set([sid(7)]) };
  const sections = chatSections(entries, state);
  assert.deepEqual(sections.map(section => [section.group, section.entries.map(entry => entry.session.name)]), [
    ["pinned", ["Pinned old"]],
    ["active", ["Alpha", "Asking", "Busy", "Zeta"]],
    ["earlier", ["Quiet", "Older"]],
  ]);
  // A longer window keeps the hour-old chat Active.
  assert.equal(groupOf(entries.find(entry => entry.session.name === "Quiet")!, { ...state, settings: { ...defaultGrouping, activeWindowMinutes: 61 } }), "active");
  // Activity nobody saw keeps a chat Active until it is seen, unless that is turned off.
  const unseen = new SessionSeen(now - 200 * 60_000);
  const older = entries.find(entry => entry.session.name === "Older")!;
  assert.equal(groupOf(older, { ...state, seen: unseen }), "active");
  assert.equal(groupOf(older, { ...state, seen: unseen.marked(older, now) }), "earlier");
  assert.equal(groupOf(older, { ...state, seen: unseen, settings: { ...defaultGrouping, unseenStayActive: false } }), "earlier");
});

test("rows hold still under the pointer: held chats keep their group and place, new ones lead, pins apply at once", () => {
  const now = Date.parse("2026-10-27T12:00:00Z");
  const seconds = (minutesAgo: number) => Math.floor((now - minutesAgo * 60_000) / 1000);
  const before = recentChatList([host([
    session(1, "Axo", { name: "A", lastMessageAt: seconds(1) }),
    session(2, "Axo", { name: "B", lastMessageAt: seconds(100) }),
    session(3, "Axo", { name: "C", lastMessageAt: seconds(200) }),
  ])]);
  const state = { pins: new SessionPins(), seen: new SessionSeen(now), now, settings: defaultGrouping };
  const held = chatSections(before, state);
  // Later: C got busy, D is new, and B was pinned under the pointer.
  const after = recentChatList([host([
    session(1, "Axo", { name: "A", lastMessageAt: seconds(1) }),
    session(2, "Axo", { name: "B", lastMessageAt: seconds(100) }),
    session(3, "Axo", { name: "C", lastMessageAt: seconds(200), status: "working" }),
    session(4, "Axo", { name: "D", lastMessageAt: seconds(0) }),
  ])]);
  const live = chatSections(after, { ...state, now: now + 10 * 60_000, pins: new SessionPins([sid(2)]) });
  const names = (sections: ReturnType<typeof holdingSections>) => sections.map(section => [section.group, section.entries.map(entry => entry.session.name)]);
  // Ten minutes on, D (new) and A are past the Active window, and C works. Held, A and C stay put
  // and D leads Earlier, where it belongs now; released, everything takes its place.
  assert.deepEqual(names(holdingSections(held, live)), [["pinned", ["B"]], ["active", ["A"]], ["earlier", ["D", "C"]]]);
  assert.deepEqual(names(holdingSections(null, live)), [["pinned", ["B"]], ["active", ["C"]], ["earlier", ["D", "A"]]]);
});

test("ages are short, as on the Mac", () => {
  const now = Date.parse("2026-10-27T12:00:00Z");
  assert.deepEqual([30, 300, 3 * 3_600, 2 * 86_400, 4 * 604_800].map(seconds => shortAge(now - seconds * 1000, now)), ["now", "5m", "3h", "2d", "4w"]);
});

// MARK: - Routes and voice

test("the URL names the open chat on its Mac, and anything else is a new chat", () => {
  assert.deepEqual(parseRoute("/app", `/app/${hostId}/${sid(12)}`), { kind: "chat", hostId, sessionId: sid(12) });
  assert.deepEqual(parseRoute("/app", `/app/${hostId}/${sid(12)}/`), { kind: "chat", hostId, sessionId: sid(12) });
  for (const path of ["/app", "/app/", `/app/${hostId}`, `/app/${hostId}/12`, `/app/${hostId}/${sid(12).toUpperCase()}`, `/app/${hostId}/x`, `/app/${hostId}/${sid(1)}/more`, `/elsewhere/${hostId}/${sid(1)}`]) {
    assert.deepEqual(parseRoute("/app", path), { kind: "new" }, path);
  }
  assert.equal(routePath("/app", hostId, { kind: "chat", sessionId: sid(12) }), `/app/${hostId}/${sid(12)}`);
  assert.equal(routePath("/app", hostId, { kind: "new", workspaceId: null }), "/app");
  assert.equal(routePath("/app", null, null), "/app");
});

test("settings pages have their own URLs: Apps, each app, MCP servers and activity", () => {
  const pages: Array<[string, SettingsRoute]> = [
    ["/app/settings/apps", { kind: "apps" }],
    ["/app/settings/apps/gmail", { kind: "app", app: "gmail" }],
    ["/app/settings/apps/mcp", { kind: "servers" }],
    ["/app/settings/apps/activity", { kind: "activity" }],
  ];
  for (const [path, route] of pages) {
    assert.deepEqual(parseSettingsRoute("/app", path), route, path);
    assert.deepEqual(parseSettingsRoute("/app", `${path}/`), route, `${path}/`);
    assert.equal(settingsPath("/app", route), path);
    assert.deepEqual(parseRoute("/app", path), { kind: "new" }, "a settings page is not a chat");
  }
  assert.deepEqual(parseSettingsRoute("/app", "/app/apps"), { kind: "apps" }, "where sign-ins used to come back");
  assert.deepEqual(parseSettingsRoute("/app", "/app/settings"), { kind: "apps" });
  for (const path of ["/app", `/app/${hostId}/${sid(1)}`, "/app/settings/apps/Gmail", "/app/settings/apps/gmail/more", "/elsewhere/settings/apps"]) {
    assert.equal(parseSettingsRoute("/app", path), null, path);
  }
});

test("Apps reads a listing from a Worker one release older, without the newest display fields", () => {
  const older = { apps: [{ kind: "app", name: "apps.gmail", title: "Gmail", state: "ready", accounts: [], tools: ["request"], lastError: null }] };
  const [app] = appsResults["axo.apps.list"].parse(older).apps;
  assert.deepEqual(app?.kind === "app" && [app.description, app.provider, app.category, app.permissions], ["", "", "", []]);
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

function clientSession(n: number, extra: Partial<ClientSession> = {}): ClientSession {
  const { hostId: _host, sessionId, status, ...metadata } = session(n);
  return { hostId, sessionId, epoch: 1, head: 0, status, metadata, ...extra };
}

/** The account's socket, as the ClientDO would answer it. */
class FakeAccount implements AccountLink {
  active = true;
  commands: Array<{ method: string; params: Record<string, unknown> }> = [];
  opens: OpenRequest[] = [];
  closed: string[] = [];
  failNext: Error | null = null;
  /** The commands' failures after `failNext`, in turn. */
  failAfter: Error[] = [];
  workspaces = [{ workspaceId, name: "Axo" }];
  /** What a method answers, when not just `{accepted: true}`. */
  answers = new Map<string, unknown>();
  /** Each Session's records in the cloud. */
  records = new Map<string, ClientRecord[]>();
  events: AccountEvents = {};
  hello = { hosts: [{ hostId, hostGeneration, label: "Studio", hostKind: "macos", online: true, lastSeenAt: "2026-10-16T12:00:00.000Z" }], sessions: [clientSession(1)] };

  async refresh() { return this.hello; }

  renames: Array<{ hostId: string; name: string }> = [];
  async renameHost(hostId: string, name: string) {
    this.renames.push({ hostId, name });
    if (this.failNext) {
      const error = this.failNext;
      this.failNext = null;
      throw error;
    }
    return name.trim() || "Studio";
  }

  async open(request: OpenRequest) {
    this.opens.push(request);
    const all = this.records.get(request.sessionId) ?? [];
    const records = request.have ? all.filter(record => record.cursor > request.have!.cursor) : all.slice(-(request.window?.last ?? 20));
    return { epoch: all.length ? 1 : null, records, cursor: records.at(-1)?.cursor ?? request.have?.cursor ?? 0, older: !request.have && records[0] && records[0].cursor > 1 ? records[0].cursor : null, progress: [] };
  }

  async older(sessionId: string, before: number, limit: number) {
    const records = (this.records.get(sessionId) ?? []).filter(record => record.cursor < before).slice(-limit);
    return { epoch: 1, records, older: records[0] && records[0].cursor > 1 ? records[0].cursor : null };
  }

  closeSession(sessionId: string) { this.closed.push(sessionId); }

  resolves: Array<{ hostId: string; elicitationId: string; action: string; sealed?: { enc: string; ciphertext: string } }> = [];
  resolveFails: Error | null = null;
  devices: Array<{ key: string; signature: string }> = [];
  async resolveElicitation(hostId: string, elicitationId: string, action: "accept" | "decline", device: { key: string; signature: string }, sealed?: { enc: string; ciphertext: string }) {
    this.devices.push(device);
    this.resolves.push(sealed ? { hostId, elicitationId, action, sealed } : { hostId, elicitationId, action });
    if (this.resolveFails) throw this.resolveFails;
  }

  async command(method: string, params: Record<string, unknown>): Promise<never> {
    this.commands.push({ method, params });
    if (this.failNext) {
      const error = this.failNext;
      this.failNext = this.failAfter.shift() ?? null;
      throw error;
    }
    if (this.answers.has(method)) return this.answers.get(method) as never;
    if (method === "axo.remote.workspace.list") return { workspaces: this.workspaces } as never;
    if (method.endsWith("session.create")) return { session: { sessionId: sid(7), name: "Chat 7" } } as never;
    return { accepted: true } as never;
  }

  close() { this.active = false; }

  /** The ClientDO sends the next batch of an open Session. */
  push(sessionId: string, records: ClientRecord[]) {
    this.records.set(sessionId, [...(this.records.get(sessionId) ?? []), ...records]);
    this.events.records?.(sessionId, 1, records);
  }
}

const tick = () => new Promise(resolve => setTimeout(resolve, 0));

async function workbenchWith(account = new FakeAccount(), retryDelay = 60_000, uploadAsset?: UploadAsset) {
  let connects = 0;
  const backend: ChatBackend = {
    connect: async (_clientId, events) => {
      connects += 1;
      account.events = events;
      account.active = true;
      return account;
    },
  };
  let id = 0;
  const workbench = new ChatWorkbench(backend, { current: () => "client-test-1", renew: () => "client-test-2" }, [1], () => `pending-${++id}`, retryDelay, uploadAsset);
  workbench.device = memoryDevice();
  workbench.start();
  await tick();
  return { workbench, account, connects: () => connects };
}

test("hello lists every Mac and chat, and opens a Mac", async () => {
  const { workbench } = await workbenchWith();
  assert.equal(workbench.link, "connected");
  assert.equal(workbench.hostsPhase, "loaded");
  assert.equal(workbench.openHostId, hostId);
  assert.deepEqual(workbench.hosts[0]!.sessions.map(session => session.sessionId), [sid(1)]);
  workbench.dispose();
});

test("a chat opens with its newest page, older pages come on request, and new records follow", async () => {
  const account = new FakeAccount();
  account.records.set(sid(1), Array.from({ length: 60 }, (_, index) => said(index + 1, index % 2 ? "assistant" : "user", `m${index + 1}`)));
  const { workbench } = await workbenchWith(account);
  workbench.selectChat(hostId, sid(1));
  await tick();
  const chat = workbench.chat(sid(1));
  assert.deepEqual(account.opens.at(-1), { hostId, sessionId: sid(1), window: { last: 50 } });
  assert.deepEqual(chat.history, { kind: "loaded", records: 50, hasOlder: true });
  await workbench.loadOlderHistory(sid(1));
  assert.deepEqual(chat.history, { kind: "loaded", records: 60, hasOlder: false });
  assert.equal(chat.transcript!.messages[0]!.text, "m1");
  account.push(sid(1), [said(61, "user", "m61")]);
  assert.equal(chat.transcript!.messages.at(-1)!.text, "m61");
  workbench.dispose();
});

test("switching chats closes the one left, and coming back reads only what is new", async () => {
  const account = new FakeAccount();
  account.hello.sessions.push(clientSession(2));
  account.records.set(sid(1), [said(1, "user", "hi")]);
  const { workbench } = await workbenchWith(account);
  workbench.selectChat(hostId, sid(1));
  await tick();
  workbench.selectChat(hostId, sid(2));
  await tick();
  assert.deepEqual(account.closed, [sid(1)]);
  account.records.set(sid(1), [said(1, "user", "hi"), said(2, "assistant", "hello")]);
  workbench.selectChat(hostId, sid(1));
  await tick();
  assert.deepEqual(account.opens.at(-1)!.have, { epoch: 1, cursor: 1 });
  assert.deepEqual(workbench.chat(sid(1)).transcript!.messages.map(message => message.text), ["hi", "hello"]);
  workbench.dispose();
});

test("a reset drops the records after the cut", async () => {
  const account = new FakeAccount();
  account.records.set(sid(1), [said(1, "user", "a"), said(2, "assistant", "b"), said(3, "user", "c")]);
  const { workbench } = await workbenchWith(account);
  workbench.selectChat(hostId, sid(1));
  await tick();
  account.events.reset?.(sid(1), 2, 1);
  const chat = workbench.chat(sid(1));
  assert.deepEqual([chat.epoch, chat.transcript!.messages.map(message => message.text)], [2, ["a"]]);
  workbench.dispose();
});

test("status and progress from the socket show whether the agent works and what it writes", async () => {
  const { workbench, account } = await workbenchWith();
  workbench.selectChat(hostId, sid(1));
  await tick();
  account.events.sessions?.(hostId, [clientSession(1, { status: "working" })]);
  account.events.progress?.(sid(1), "message", { message: { role: "assistant", content: "Wor" } });
  const transcript = workbench.chat(sid(1)).transcript!;
  assert.equal(transcript.working, true);
  assert.equal(transcript.live[0]!.text, "Wor");
  account.events.sessions?.(hostId, [clientSession(1, { status: "ready" })]);
  assert.deepEqual([transcript.working, transcript.live.length], [false, 0]);
  workbench.dispose();
});

test("a new chat's first message starts it in the Mac's Home Workspace and moves the words there", async () => {
  const { workbench, account } = await workbenchWith();
  account.workspaces = [{ workspaceId, name: "Axo" }, { workspaceId: "8f8f8f8f-0000-4000-8000-000000000000", name: "Home" }];
  workbench.setDraft("Fix the bug");
  assert.deepEqual(await workbench.send(), { kind: "sent" });
  assert.deepEqual(workbench.selection, { kind: "chat", sessionId: sid(7) });
  assert.equal(workbench.selectedSession?.name, "Chat 7", "listed at once, before the Mac's own listing");
  const created = account.commands.filter(call => call.method.endsWith("session.create"));
  assert.deepEqual(created.map(call => call.method), ["axo.remote.session.create"], "however many Workspaces, a new chat goes Home");
  const prompt = account.commands.find(call => call.method === "axo.remote.session.prompt");
  assert.deepEqual([prompt?.params.text, prompt?.params.sessionId, prompt?.params.target], ["Fix the bug", sid(7), { hostId, hostGeneration }]);
  assert.equal(workbench.draft(), "");
  assert.equal(workbench.chat(sid(7)).pending[0]?.state, "sent");
  workbench.dispose();
});

test("a new chat started from a Workspace in the menu starts in that Workspace", async () => {
  const { workbench, account } = await workbenchWith();
  workbench.newChat(hostId, workspaceId);
  workbench.setDraft("Hello");
  assert.deepEqual(await workbench.send(), { kind: "sent" });
  const created = account.commands.filter(call => call.method.endsWith("session.create"));
  assert.deepEqual(created.map(call => [call.method, call.params.workspaceId]), [["axo.remote.workspace.session.create", workspaceId]]);
  workbench.dispose();
});

test("a refused message comes back to the box; one whose delivery is uncertain stays, marked", async () => {
  const { workbench, account } = await workbenchWith();
  workbench.selectChat(hostId, sid(1));
  workbench.setDraft("first");
  account.failNext = Object.assign(new Error("Host offline; nothing queued"), { code: -32005 });
  assert.deepEqual(await workbench.send(), { kind: "failed" });
  assert.equal(workbench.draft(), "first");
  assert.equal(workbench.chat(sid(1)).pending.length, 0);

  account.failNext = Object.assign(new Error("Outcome unknown; reconcile commandId"), { code: -32004 });
  assert.deepEqual(await workbench.send(), { kind: "uncertain" });
  assert.equal(workbench.draft(), "");
  assert.equal(workbench.chat(sid(1)).pending[0]?.state, "uncertain");
  workbench.dispose();
});

test("an uncertain message is sent again with its commandId, and an offline answer then keeps it (RFD0024)", async () => {
  const { workbench, account } = await workbenchWith(new FakeAccount(), 0);
  workbench.selectChat(hostId, sid(1));
  await tick();
  workbench.setDraft("yes");
  account.failNext = Object.assign(new Error("Outcome unknown; reconcile commandId"), { code: -32004 });
  // The retry finds the Mac offline: the first try may still land, so the words stay pending.
  account.failAfter = [Object.assign(new Error("Host offline; nothing queued"), { code: -32005 })];
  assert.deepEqual(await workbench.send(), { kind: "uncertain" });
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(workbench.draft(), "", "the words never come back to the box");
  assert.equal(workbench.chat(sid(1)).pending.length, 1);
  const prompts = account.commands.filter(call => call.method === "axo.remote.session.prompt");
  assert.ok(prompts.length >= 3);
  assert.deepEqual(new Set(prompts.map(call => call.params.commandId)), new Set(["pending-1"]), "every try is the same command");
  assert.equal(workbench.chat(sid(1)).pending[0]?.state, "sent");
  workbench.dispose();
});

test("a pending message is retired by its receipt, never by its words (RFD0024)", async () => {
  const { workbench, account } = await workbenchWith();
  workbench.selectChat(hostId, sid(1));
  await tick();
  workbench.setDraft("yes");
  await workbench.send();
  const commandId = account.commands.find(call => call.method === "axo.remote.session.prompt")!.params.commandId as string;
  assert.equal(commandId, "pending-1");
  // Someone types the same words on the Mac: that is not this message.
  account.push(sid(1), [said(1, "user", "yes")]);
  assert.equal(workbench.chat(sid(1)).pending.length, 1);
  // Its receipt alone does not show it yet; the user message after it does.
  account.push(sid(1), [receipt(2, commandId)]);
  assert.equal(workbench.chat(sid(1)).pending.length, 1);
  account.push(sid(1), [said(3, "user", "yes")]);
  assert.equal(workbench.chat(sid(1)).pending.length, 0);
  assert.deepEqual(workbench.chat(sid(1)).transcript?.messages.map(message => message.text), ["yes", "yes"]);
  workbench.dispose();
});

test("stop names the turn the chat shows running, once, only while the agent works (RFD0024)", async () => {
  const account = new FakeAccount();
  account.records.set(sid(1), [said(1, "user", "go"), said(2, "assistant", "on it")]);
  const { workbench } = await workbenchWith(account);
  workbench.selectChat(hostId, sid(1));
  await tick();
  await workbench.stop(sid(1));
  assert.equal(account.commands.filter(call => call.method === "axo.remote.session.stop").length, 0);
  account.events.sessions?.(hostId, [clientSession(1, { status: "working" })]);
  await Promise.all([workbench.stop(sid(1)), workbench.stop(sid(1))]);
  const stops = account.commands.filter(call => call.method === "axo.remote.session.stop");
  assert.deepEqual(stops.map(call => call.params.turnId), ["e1"]);
  assert.equal(account.commands.filter(call => call.method === "axo.remote.session.key").length, 0);
  workbench.dispose();
});

test("a lost connection is tried again, comes back connected, and reopens the chat from what is held", async () => {
  const account = new FakeAccount();
  account.records.set(sid(1), [said(1, "user", "hi")]);
  const { workbench, connects } = await workbenchWith(account);
  workbench.selectChat(hostId, sid(1));
  await tick();
  account.active = false;
  account.events.closed?.(new Error("WebSocket closed (1006)"));
  assert.equal(workbench.link, "reconnecting");
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(connects(), 2);
  assert.equal(workbench.link, "connected");
  assert.deepEqual(account.opens.at(-1)!.have, { epoch: 1, cursor: 1 });
  workbench.dispose();
});

test("a Mac is named by the person, and a name that could not be saved says so", async () => {
  const { workbench, account } = await workbenchWith();
  assert.equal(await workbench.renameHost(hostId, "Mac Studio"), true);
  assert.deepEqual(account.renames, [{ hostId, name: "Mac Studio" }]);
  assert.equal(workbench.hosts[0]!.label, "Mac Studio");
  account.failNext = new Error("offline");
  assert.equal(await workbench.renameHost(hostId, "Other"), false);
  assert.equal(workbench.hosts[0]!.label, "Mac Studio", "unchanged");
  assert.match(workbench.failure ?? "", /Could not rename the Mac/);
});

// MARK: - Attachments (RFD0030)

const photoHex = "ab".repeat(32);

test("a file attached in the box uploads at once; the message waits for it and carries it", async () => {
  let finish: (() => void) | null = null;
  const uploads: string[] = [];
  const upload: UploadAsset = (file, name) => {
    uploads.push(name);
    return new Promise(resolve => {
      finish = () => resolve({ asset: `sha256:${photoHex}`, name, mimeType: "image/png", size: file.size });
    });
  };
  const { workbench, account } = await workbenchWith(new FakeAccount(), 60_000, upload);
  workbench.selectChat(hostId, sid(1));
  workbench.attach([{ file: new Blob(["png"], { type: "image/png" }), name: "white/board.png" }]);
  assert.deepEqual(uploads, ["white_board.png"], "a name with a slash is made safe before it leaves");
  assert.equal(workbench.attachments()[0]!.state, "uploading");
  assert.equal(workbench.canSendDraft, false, "not while a file is on its way");
  assert.deepEqual(await workbench.send(), { kind: "failed" });
  finish!();
  await tick();
  assert.equal(workbench.canSendDraft, true, "files alone are a message");
  assert.deepEqual(await workbench.send(), { kind: "sent" });
  const prompt = account.commands.find(call => call.method === "axo.remote.session.prompt");
  assert.deepEqual(prompt?.params.attachments, [{ asset: `sha256:${photoHex}`, name: "white_board.png", mimeType: "image/png", size: 3 }]);
  assert.equal(prompt?.params.text, "");
  assert.deepEqual(workbench.attachments(), []);
  assert.equal(workbench.chat(sid(1)).pending[0]!.attachments.length, 1);
  workbench.dispose();
});

test("a failed upload holds the message until the file is taken out; a refused message gets its files back", async () => {
  const upload: UploadAsset = () => Promise.reject(new Error("The account's assets are full"));
  const account = new FakeAccount();
  const { workbench } = await workbenchWith(account, 60_000, upload);
  workbench.selectChat(hostId, sid(1));
  workbench.setDraft("see attached");
  workbench.attach([{ file: new Blob(["x"]), name: "a.bin" }]);
  await tick();
  const [failed] = workbench.attachments();
  assert.deepEqual([failed!.state, failed!.error], ["failed", "The account's assets are full"]);
  assert.equal(workbench.canSendDraft, false);
  workbench.detach(failed!.id);
  assert.equal(workbench.canSendDraft, true);
  workbench.dispose();

  const ok: UploadAsset = async (file, name) => ({ asset: `sha256:${photoHex}`, name, mimeType: "application/octet-stream", size: file.size });
  const refusing = new FakeAccount();
  const second = await workbenchWith(refusing, 60_000, ok);
  second.workbench.selectChat(hostId, sid(1));
  second.workbench.attach([{ file: new Blob(["x"]), name: "a.bin" }]);
  await tick();
  refusing.failNext = Object.assign(new Error("an attachment is no longer in the account"), { code: -32010 });
  assert.deepEqual(await second.workbench.send(), { kind: "failed" });
  assert.equal(second.workbench.attachments().length, 1, "the file comes back to the box");
  second.workbench.dispose();
});

test("at most eight files go in one message", async () => {
  const ok: UploadAsset = async (file, name) => ({ asset: `sha256:${photoHex}`, name, mimeType: "text/plain", size: file.size });
  const { workbench } = await workbenchWith(new FakeAccount(), 60_000, ok);
  workbench.selectChat(hostId, sid(1));
  workbench.attach(Array.from({ length: 10 }, (_, index) => ({ file: new Blob([String(index)]), name: `${index}.txt` })));
  assert.equal(workbench.attachments().length, 8);
  assert.match(workbench.failure ?? "", /at most 8 files/u);
  workbench.dispose();
});

test("pi-axo's attachment lines leave what the person said: an image's goes, a file's becomes a download", () => {
  const said = [
    "what is in these?",
    "",
    `[Attached image: board.png at /Users/leo/.axo/assets/${photoHex}/board.png axo-asset:sha256:${photoHex}]`,
    "",
    `[Attached file: invoice (final).pdf (application/pdf, 3.0 MB) at /Users/leo/.axo/assets/${photoHex}/invoice (final).pdf axo-asset:sha256:${photoHex}]`,
  ].join("\n");
  assert.deepEqual(attachmentsIn(said), {
    text: "what is in these?",
    files: [{ name: "invoice (final).pdf", mimeType: "application/pdf", size: "3.0 MB", hex: photoHex }],
  });
  assert.deepEqual(attachmentsIn("[Attached file: not really]"), { text: "[Attached file: not really]", files: [] });
  assert.equal(safeFileName("../.."), ".._..");
  assert.equal(safeFileName(".."), "file");
});

test("what a Mac asks shows in its chat until the Mac says it is settled, and only one answer goes", async () => {
  const { workbench, account } = await workbenchWith();
  const elicitation = { id: "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f5a", sessionId: sid(1), kind: "confirm" as const, message: "Delete the branch?", createdAt: 1, expiresAt: 2 };
  account.events.elicitationRequested?.(hostId, elicitation);
  account.events.elicitationRequested?.(hostId, elicitation);
  assert.equal(workbench.questions().length, 1);
  assert.equal(workbench.questions(sid(1))[0]!.elicitation.message, "Delete the branch?");
  assert.equal(workbench.questions(sid(2)).length, 0);

  const answering = workbench.answerQuestion(elicitation.id, "accept");
  assert.equal(workbench.questions()[0]!.answering, "accept");
  await workbench.answerQuestion(elicitation.id, "decline");
  await answering;
  assert.deepEqual(account.resolves, [{ hostId, elicitationId: elicitation.id, action: "accept" }]);
  // The card goes when the Mac says so, wherever the answer came from.
  assert.equal(workbench.questions().length, 1);
  account.events.elicitationResolved?.(hostId, { id: elicitation.id, sessionId: sid(1), action: "accept" });
  assert.equal(workbench.questions().length, 0);
});

test("an answer that came too late removes the card; another failure lets the person try again", async () => {
  const { workbench, account } = await workbenchWith();
  const elicitation = { id: "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f5b", sessionId: sid(1), kind: "confirm" as const, message: "Go?", createdAt: 1, expiresAt: 2 };
  account.events.elicitationRequested?.(hostId, elicitation);
  account.resolveFails = Object.assign(new Error("Host offline"), { code: -32005 });
  await workbench.answerQuestion(elicitation.id, "accept");
  assert.equal(workbench.questions()[0]!.answering, null);
  assert.equal(workbench.failure, "Host offline");
  account.resolveFails = Object.assign(new Error("Already answered"), { code: -32011 });
  await workbench.answerQuestion(elicitation.id, "decline");
  assert.equal(workbench.questions().length, 0);
});

test("a form's values leave only sealed, and only to the key first seen for that Mac", async () => {
  const { workbench, account } = await workbenchWith();
  const vectors = JSON.parse(readFileSync(new URL("../../../crates/axo-seal/testdata/vectors.json", import.meta.url), "utf8"));
  const input = { app: "Safari", window: "Sign in", origin: "https://github.com", fields: [{ id: "f0", label: "Password", kind: "password" as const }], key: vectors.publicKey };
  const ask = (id: string, key = input.key) => account.events.elicitationRequested?.(hostId, { id, sessionId: sid(1), kind: "input" as const, askedBy: "computerUse" as const, message: "Fill Password in Safari.", input: { ...input, key }, createdAt: 1, expiresAt: 2 });
  inputKeyPins.memory.clear();
  ask("6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f60");
  await workbench.answerQuestion("6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f60", "accept", { f0: "hunter2" });
  const [sent] = account.resolves;
  assert.equal(sent!.action, "accept");
  assert.ok(sent!.sealed && !JSON.stringify(sent).includes("hunter2"));

  // Another key for the same Mac gets nothing.
  const other = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=";
  ask("6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f61", other);
  await workbench.answerQuestion("6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f61", "accept", { f0: "hunter2" });
  assert.equal(account.resolves.length, 1);
  assert.match(workbench.failure ?? "", /key changed/);
  // Cancelling needs no key.
  await workbench.answerQuestion("6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f61", "decline");
  assert.deepEqual(account.resolves[1], { hostId, elicitationId: "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f61", action: "decline" });
});

test("every answer goes signed by this browser's key, each with its own signature", async () => {
  const { workbench, account } = await workbenchWith();
  const elicitation = { id: "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f70", sessionId: sid(1), kind: "confirm" as const, message: "Go?", createdAt: 1, expiresAt: 2 };
  account.events.elicitationRequested?.(hostId, elicitation);
  account.resolveFails = Object.assign(new Error("The answer's signature is not for this answer."), { code: -32015 });
  await workbench.answerQuestion(elicitation.id, "accept");
  assert.equal(account.devices[0]!.key.length, 88);
  account.resolveFails = null;
  await workbench.answerQuestion(elicitation.id, "accept");
  assert.equal(account.devices[1]!.key, account.devices[0]!.key);
  assert.notEqual(account.devices[1]!.signature, account.devices[0]!.signature);
});

test("a browser names itself by its browser and system", async () => {
  const { browserName } = await import("../src/chat/device.ts");
  assert.equal(browserName("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"), "Safari on Mac");
  assert.equal(browserName("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"), "Chrome on Windows");
});

// MARK: - Session controls (RFD0033)

const opus = { provider: "anthropic", id: "claude-opus-4-1", name: "Opus 4.1" };
const models = [
  { ...opus, thinkingLevels: ["off", "low", "medium", "high"] as const },
  { provider: "anthropic", id: "claude-haiku", name: "Haiku", thinkingLevels: ["off"] as const },
  { provider: "openai", id: "gpt-5", name: "GPT-5", thinkingLevels: ["minimal", "low", "medium", "high"] as const },
].map(model => ({ ...model, thinkingLevels: [...model.thinkingLevels] }));
const commands = [
  { name: "review", description: "Review the diff", source: "prompt" as const },
  { name: "axo-share", description: "Share this conversation", source: "extension" as const },
  { name: "hivemind", description: "Search the team's memory", source: "skill" as const },
];

test("a prompt queued in the log waits, as a follow-up or a steer, until its receipt; a reload sees it from the log alone", () => {
  const transcript = transcriptOf([said(1, "user", "go"), queued(2, "c-1", "and tests", "followUp", [{ asset: hash, name: "a.png", mimeType: "image/png", size: 3 }]), queued(3, "c-2", "use bun", "steer")]);
  assert.deepEqual(transcript.queued.map(prompt => [prompt.commandId, prompt.delivery, prompt.text, prompt.files]),
    [["c-1", "followUp", "and tests", ["a.png"]], ["c-2", "steer", "use bun", []]]);
  assert.deepEqual(transcript.messages.map(message => message.text), ["go"], "a queued prompt is not a message yet");
  transcript.append([receipt(4, "c-2"), said(5, "user", "use bun")]);
  assert.deepEqual(transcript.queued.map(prompt => prompt.commandId), ["c-1"]);
  // Read again from the start, as after a reload: the same is still waiting.
  const reloaded = transcriptOf(transcript.records as ClientRecord[]);
  assert.deepEqual(reloaded.queued.map(prompt => prompt.commandId), ["c-1"]);
  assert.equal(pendingLabel({ state: "queued", delivery: "steer" }), "Steering · read at the agent's next step");
  assert.equal(pendingLabel({ state: "queued", delivery: "followUp" }), "Queued · answered after the current reply");
});

test("the chat shows each waiting message once: sent from here, or queued in the log from anywhere", async () => {
  const { workbench, account } = await workbenchWith();
  workbench.selectChat(hostId, sid(1));
  await tick();
  workbench.setDraft("mine");
  await workbench.send("steer");
  const prompt = account.commands.find(call => call.method === "axo.remote.session.prompt")!;
  assert.equal(prompt.params.delivery, "steer");
  account.push(sid(1), [queued(1, "pending-1", "mine", "steer"), queued(2, "phone-1", "from the phone")]);
  const waiting = workbench.chat(sid(1)).waiting;
  assert.deepEqual(waiting.map(prompt => [prompt.id, prompt.state, prompt.delivery, prompt.mine]),
    [["pending-1", "queued", "steer", true], ["phone-1", "queued", "followUp", false]]);
  account.push(sid(1), [receipt(3, "phone-1"), said(4, "user", "from the phone")]);
  assert.deepEqual(workbench.chat(sid(1)).waiting.map(prompt => prompt.id), ["pending-1"]);
  workbench.dispose();
});

test("a follow-up goes without a delivery, as before; a prompt to a waking agent is sent again with its commandId, quietly", async () => {
  const { workbench, account } = await workbenchWith(new FakeAccount(), 0);
  workbench.selectChat(hostId, sid(1));
  await tick();
  workbench.setDraft("hello");
  account.failNext = Object.assign(new Error("Pi is still starting"), { code: -32008 });
  assert.deepEqual(await workbench.send("followUp"), { kind: "sent" });
  assert.equal(workbench.draft(), "", "the words are not handed back");
  assert.equal(workbench.failure, null);
  assert.equal(workbench.chat(sid(1)).pending[0]?.state, "waking");
  await new Promise(resolve => setTimeout(resolve, 20));
  const prompts = account.commands.filter(call => call.method === "axo.remote.session.prompt");
  assert.deepEqual(prompts.map(call => [call.params.commandId, "delivery" in call.params]), [["pending-1", false], ["pending-1", false]]);
  assert.equal(workbench.chat(sid(1)).pending[0]?.state, "sent");
  workbench.dispose();
});

test("restart asks the Mac once and says Restarting until the agent is ready again", async () => {
  const { workbench, account } = await workbenchWith();
  workbench.selectChat(hostId, sid(1));
  await tick();
  await Promise.all([workbench.restart(sid(1)), workbench.restart(sid(1))]);
  // A listing from before the restart took effect still says ready: that is not the restart done.
  account.events.sessions?.(hostId, [clientSession(1, { status: "ready" })]);
  assert.equal(workbench.chat(sid(1)).restarting, true, "ready from before the restart does not end it");
  assert.equal(account.commands.filter(call => call.method === "axo.remote.session.restart").length, 1);
  const chat = workbench.chat(sid(1));
  assert.equal(chat.restarting, true);
  account.events.sessions?.(hostId, [clientSession(1, { status: "starting" })]);
  assert.equal(chat.restarting, true, "starting is not ready");
  account.events.sessions?.(hostId, [clientSession(1, { status: "ready" })]);
  assert.equal(chat.restarting, false);

  account.failNext = Object.assign(new Error("Host offline"), { code: -32005 });
  await workbench.restart(sid(1));
  assert.equal(chat.restarting, false);
  assert.match(workbench.failure ?? "", /Could not restart/);
  workbench.dispose();
});

test("what Pi runs comes with the chat's listing; its models and commands are read when their menus open", async () => {
  const account = new FakeAccount();
  account.hello.sessions = [clientSession(1, { metadata: { ...clientSession(1).metadata, pi: { model: opus, thinkingLevel: "high" } } })];
  account.answers.set("axo.remote.session.models", { models });
  account.answers.set("axo.remote.session.commands", { commands });
  const { workbench } = await workbenchWith(account);
  workbench.selectChat(hostId, sid(1));
  const session = workbench.selectedSession!;
  assert.equal(runtimeLabel(session.pi), "Opus 4.1 · High");
  assert.equal(runtimeLabel({ model: opus, thinkingLevel: "off" }), "Opus 4.1");
  assert.equal(runtimeLabel(undefined), null, "nothing shows until Pi has said");

  await workbench.loadModels(sid(1));
  const read = workbench.chat(sid(1)).models;
  assert.equal(read?.kind, "loaded");
  const items = read?.kind === "loaded" ? read.items : [];
  assert.deepEqual(modelsByProvider(items).map(group => [group.provider, group.models.map(model => model.id)]),
    [["anthropic", ["claude-opus-4-1", "claude-haiku"]], ["openai", ["gpt-5"]]]);
  assert.deepEqual(levelsOf(items, session.pi), ["off", "low", "medium", "high"]);

  assert.equal(await workbench.setModel(sid(1), { model: { provider: "openai", id: "gpt-5" } }), true);
  assert.deepEqual(account.commands.at(-1), { method: "axo.remote.session.model.set", params: { target: { hostId, hostGeneration }, sessionId: sid(1), model: { provider: "openai", id: "gpt-5" } } });
  account.failNext = Object.assign(new Error("no credentials"), { code: -32007 });
  assert.equal(await workbench.setModel(sid(1), { thinkingLevel: "low" }), false);
  assert.match(workbench.failure ?? "", /not signed in/);

  await workbench.loadCommands(sid(1));
  assert.equal(workbench.chat(sid(1)).commands?.kind, "loaded");
  account.failNext = new Error("Pi is not running");
  await workbench.loadCommands(sid(1));
  assert.deepEqual(workbench.chat(sid(1)).commands, { kind: "failed", message: "Pi is not running" });
  workbench.dispose();
});

test("the / list opens only while a command is being named, and narrows as it is typed", () => {
  assert.equal(slashQuery("/"), "");
  assert.equal(slashQuery("/rev"), "rev");
  assert.equal(slashQuery("/review the diff"), null, "arguments close it");
  assert.equal(slashQuery("see /review"), null, "only at the start");
  assert.deepEqual(matchingCommands(commands, "").map(command => command.name), ["review", "axo-share", "hivemind"]);
  assert.deepEqual(matchingCommands(commands, "sh").map(command => command.name), ["axo-share"]);
  assert.deepEqual(matchingCommands(commands, "memory").map(command => command.name), ["hivemind"], "a description matches last");
  assert.deepEqual(matchingCommands(commands, "zzz"), []);
  assert.equal(withCommand(commands[0]!), "/review ");
});

test("a stop names what this tab saw of the run: its newest record however long the run, and its own messages before any record", async () => {
  const account = new FakeAccount();
  account.answers.set("axo.remote.session.stop", { stopped: true });
  // A long run: the newest page holds tool records only, no user message.
  account.records.set(sid(1), Array.from({ length: 60 }, (_, index) => said(index + 1, "assistant", `step ${index + 1}`)));
  const { workbench } = await workbenchWith(account);
  workbench.selectChat(hostId, sid(1));
  await tick();
  account.events.sessions?.(hostId, [clientSession(1, { status: "working" })]);
  assert.equal(workbench.chat(sid(1)).transcript?.lastUserEntry, null);
  await workbench.stop(sid(1));
  const stops = () => account.commands.filter(call => call.method === "axo.remote.session.stop").map(call => call.params);
  assert.deepEqual(stops().map(({ turnId, seen, commandIds }) => ({ turnId, seen, commandIds })), [{ turnId: undefined, seen: "e60", commandIds: undefined }]);
  assert.equal(workbench.chat(sid(1)).stopping, true, "stopping until Pi says it is idle");
  account.events.sessions?.(hostId, [clientSession(1, { status: "ready" })]);

  // A message from here, then at once the stop: none of the new run's records are here yet.
  workbench.setDraft("go");
  await workbench.send();
  account.events.sessions?.(hostId, [clientSession(1, { status: "working" })]);
  await workbench.stop(sid(1));
  assert.deepEqual(stops().at(-1)!.commandIds, ["pending-1"]);
  workbench.dispose();
});

test("a stop that stopped nothing ends at once, so the next tap tries again", async () => {
  const account = new FakeAccount();
  account.answers.set("axo.remote.session.stop", { stopped: false });
  account.records.set(sid(1), [said(1, "user", "go")]);
  const { workbench } = await workbenchWith(account);
  workbench.selectChat(hostId, sid(1));
  await tick();
  account.events.sessions?.(hostId, [clientSession(1, { status: "working" })]);
  await workbench.stop(sid(1));
  assert.equal(workbench.chat(sid(1)).stopping, false);
  await workbench.stop(sid(1));
  assert.equal(account.commands.filter(call => call.method === "axo.remote.session.stop").length, 2);

  // A Mac from before `seen` and commandIds refuses them: the stop goes again with the turn alone.
  account.failNext = Object.assign(new Error("Invalid params"), { code: -32602 });
  await workbench.stop(sid(1));
  const stops = account.commands.filter(call => call.method === "axo.remote.session.stop").map(call => call.params);
  assert.deepEqual(stops.slice(-2).map(params => Object.keys(params).sort()), [["seen", "sessionId", "target", "turnId"], ["sessionId", "target", "turnId"]]);
  assert.equal(workbench.failure, null);
  workbench.dispose();
});

// MARK: - Where the person's messages show

/** The conversation as the screen lists it: messages by their words, waiting ones marked. */
function rowsOf(workbench: ChatWorkbench, sessionId: string): string[] {
  const chat = workbench.chat(sessionId);
  return conversationRows(chat.transcript?.messages ?? [], chat.waiting)
    .map(row => row.kind === "message" ? `${row.message.role}: ${row.message.text}` : `waiting(${row.prompt.state}): ${row.prompt.text}`);
}

test("sent while idle: one copy, shown last until the log has it, then in its place before its reply", async () => {
  const account = new FakeAccount();
  account.records.set(sid(1), [said(1, "user", "hi"), said(2, "assistant", "hello")]);
  const { workbench } = await workbenchWith(account);
  workbench.selectChat(hostId, sid(1));
  await tick();
  workbench.setDraft("fix it");
  await workbench.send();
  assert.deepEqual(rowsOf(workbench, sid(1)), ["user: hi", "assistant: hello", "waiting(sent): fix it"]);
  account.push(sid(1), [receipt(3, "pending-1"), said(4, "user", "fix it"), said(5, "assistant", "on it")]);
  assert.deepEqual(rowsOf(workbench, sid(1)), ["user: hi", "assistant: hello", "user: fix it", "assistant: on it"]);
  workbench.dispose();
});

test("sent while a run streams: it stays after the reply it was sent under, not below every reply that follows", async () => {
  const account = new FakeAccount();
  account.records.set(sid(1), [said(1, "user", "go")]);
  const { workbench } = await workbenchWith(account);
  workbench.selectChat(hostId, sid(1));
  await tick();
  account.events.sessions?.(hostId, [clientSession(1, { status: "working" })]);
  account.events.progress?.(sid(1), "message", { message: { role: "assistant", timestamp: 10, content: [{ type: "text", text: "step one" }] } });
  workbench.setDraft("and the tests");
  await workbench.send("followUp");
  workbench.setDraft("use bun");
  await workbench.send("steer");
  // pi-axo writes them to the log before it accepts them, while the reply is still being written.
  account.push(sid(1), [queued(2, "pending-1", "and the tests"), queued(3, "pending-2", "use bun", "steer")]);
  assert.deepEqual(rowsOf(workbench, sid(1)), ["user: go", "waiting(queued): and the tests", "waiting(queued): use bun"]);
  // The reply they were sent under is recorded, and the run goes on: many more replies.
  account.push(sid(1), [said(4, "assistant", "step one", { timestamp: 10 }), said(5, "assistant", "step two"), said(6, "assistant", "step three")]);
  assert.deepEqual(rowsOf(workbench, sid(1)), [
    "user: go", "assistant: step one", "waiting(queued): and the tests", "waiting(queued): use bun", "assistant: step two", "assistant: step three",
  ], "never at the end, below replies they did not ask for");
  const labels = workbench.chat(sid(1)).waiting.map(prompt => pendingLabel(prompt));
  assert.deepEqual(labels, ["Queued · answered after the current reply", "Steering · read at the agent's next step"]);
  // The steer joins the run at a turn's end; the follow-up starts the next run. Each shows once, before its replies.
  account.push(sid(1), [receipt(7, "pending-2"), said(8, "user", "use bun"), said(9, "assistant", "using bun")]);
  account.push(sid(1), [receipt(10, "pending-1"), said(11, "user", "and the tests"), said(12, "assistant", "tests pass")]);
  assert.deepEqual(rowsOf(workbench, sid(1)), [
    "user: go", "assistant: step one", "assistant: step two", "assistant: step three",
    "user: use bun", "assistant: using bun", "user: and the tests", "assistant: tests pass",
  ]);
  workbench.dispose();
});

test("reloaded mid-run, a queued message shows from the log alone, once, in the same place", async () => {
  const account = new FakeAccount();
  account.records.set(sid(1), [said(1, "user", "go"), queued(2, "c0ffee00-0000-4000-8000-000000000001", "and the tests"), said(3, "assistant", "step one"), said(4, "assistant", "step two")]);
  const { workbench } = await workbenchWith(account);
  workbench.selectChat(hostId, sid(1));
  await tick();
  assert.deepEqual(rowsOf(workbench, sid(1)), ["user: go", "assistant: step one", "waiting(queued): and the tests", "assistant: step two"]);
  workbench.dispose();
});

test("records that come twice, as after a reconnect, show the message once", async () => {
  const account = new FakeAccount();
  account.records.set(sid(1), [said(1, "user", "go")]);
  const { workbench } = await workbenchWith(account);
  workbench.selectChat(hostId, sid(1));
  await tick();
  workbench.setDraft("again");
  await workbench.send();
  const batch = [receipt(2, "pending-1"), said(3, "user", "again"), said(4, "assistant", "done")];
  account.push(sid(1), batch);
  account.events.records?.(sid(1), 1, batch);
  await workbench.openChat(sid(1));
  assert.deepEqual(rowsOf(workbench, sid(1)), ["user: go", "user: again", "assistant: done"]);
  workbench.dispose();
});

test("a command sent from here, which writes no user message, is not left waiting at the end", async () => {
  const account = new FakeAccount();
  account.records.set(sid(1), [said(1, "user", "go"), said(2, "assistant", "done")]);
  const { workbench } = await workbenchWith(account);
  workbench.selectChat(hostId, sid(1));
  await tick();
  workbench.setDraft("/axo-share");
  await workbench.send();
  account.push(sid(1), [receipt(3, "pending-1")]);
  account.push(sid(1), [said(4, "assistant", "Shared at https://axo.leostera.dev/s/abc")]);
  assert.deepEqual(rowsOf(workbench, sid(1)), ["user: go", "assistant: done", "assistant: Shared at https://axo.leostera.dev/s/abc"]);
  workbench.dispose();
});

test("Send interrupts a working agent by default; Steer and Follow up are asked for", async () => {
  const { workbench, account } = await workbenchWith();
  workbench.selectChat(hostId, sid(1));
  await tick();
  for (const [text, delivery] of [["now", undefined], ["at its next step", "steer"], ["after", "followUp"]] as const) {
    workbench.setDraft(text);
    await (delivery ? workbench.send(delivery) : workbench.send());
  }
  const prompts = account.commands.filter(call => call.method === "axo.remote.session.prompt");
  assert.deepEqual(prompts.map(call => [call.params.text, call.params.delivery]), [
    ["now", "interrupt"], ["at its next step", "steer"], ["after", undefined],
  ]);
  // In the log while the reply stops: it says so.
  account.push(sid(1), [queued(1, "pending-1", "now", "interrupt")]);
  assert.equal(pendingLabel(workbench.chat(sid(1)).waiting[0]!), "Interrupting · answered next");
  workbench.dispose();
});

test("a Mac from before interrupts gets the message as a follow-up, at once, with the same commandId", async () => {
  const { workbench, account } = await workbenchWith();
  workbench.selectChat(hostId, sid(1));
  await tick();
  workbench.setDraft("now");
  account.failNext = Object.assign(new Error("Invalid params"), { code: -32602 });
  assert.deepEqual(await workbench.send(), { kind: "sent" });
  const prompts = account.commands.filter(call => call.method === "axo.remote.session.prompt");
  assert.deepEqual(prompts.map(call => [call.params.commandId, call.params.delivery]), [["pending-1", "interrupt"], ["pending-1", undefined]]);
  assert.equal(workbench.failure, null);
  workbench.dispose();
});
