import assert from "node:assert/strict";
import { test } from "node:test";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { PiElicitations, selectElicitation, terminalQuestion, type PiElicitation, type PiElicitationAnswer } from "../src/elicitations.js";
import { parsePiControlCommand } from "../src/protocol.js";

const request = (n = 1): PiElicitation => ({ id: `0000000${n}-0000-4000-8000-00000000000${n}`,
  title: "Agent asks", message: "Deploy the tested relay? No mail or billing changes.", expiresAt: Date.now() + 60_000 });
const tick = () => new Promise(resolve => setImmediate(resolve));
const context = { hasUI: true, ui: { notify: () => {} } } as unknown as ExtensionContext;

function fixture() {
  const shown: Array<{ request: PiElicitation; signal: AbortSignal; choose: (answer: PiElicitationAnswer) => void }> = [];
  const answers: Array<{ id: string; action: PiElicitationAnswer }> = [];
  const controller = new PiElicitations(async (id, action) => { answers.push({ id, action }); },
    async (_context, request, signal) => new Promise(resolve => {
      shown.push({ request, signal, choose: resolve });
      signal.addEventListener("abort", () => resolve("cancel"), { once: true });
    }));
  return { controller, shown, answers };
}

test("yes and no settle exactly the displayed request, once", async () => {
  for (const action of ["accept", "decline"] as const) {
    const f = fixture(), q = request();
    assert.equal(f.controller.present(q, context, () => true), "shown");
    assert.deepEqual(f.shown[0].request, q);
    f.shown[0].choose(action);
    await tick();
    assert.deepEqual(f.answers, [{ id: q.id, action }]);
    assert.equal(f.controller.present(q, context, () => true), "stale");
    f.controller.close();
  }
});

test("remote resolution, expiry, identity changes, disconnect and shutdown cannot become Yes", async () => {
  for (const end of ["dismiss", "expire", "identity", "disconnect", "shutdown"]) {
    const f = fixture(), q = request();
    let current = true;
    assert.equal(f.controller.present(q, context, () => current), "shown");
    if (end === "dismiss") f.controller.dismiss(q.id);
    if (end === "expire") q.expiresAt = Date.now() - 1;
    if (end === "identity") current = false;
    if (end === "disconnect") f.controller.disconnect();
    if (end === "shutdown") f.controller.close();
    f.shown[0].choose("accept");
    await tick();
    assert.deepEqual(f.answers, [], end);
    f.controller.close();
  }
});

test("dismissal before presentation fences an out-of-order show", () => {
  const f = fixture(), q = request();
  f.controller.dismiss(q.id);
  assert.equal(f.controller.present(q, context, () => true), "stale");
  assert.equal(f.shown.length, 0);
});

test("multiple requests are shown serially and a resolved queued request never opens", async () => {
  const f = fixture(), first = request(1), second = request(2), third = request(3);
  for (const q of [first, second, third]) assert.equal(f.controller.present(q, context, () => true), "shown");
  assert.equal(f.shown.length, 1);
  f.controller.dismiss(second.id);
  f.shown[0].choose("decline");
  await tick();
  assert.equal(f.shown.length, 2);
  assert.equal(f.shown[1].request.id, third.id);
  f.controller.close();
  await tick();
  assert.deepEqual(f.answers, [{ id: first.id, action: "decline" }]);
});

test("headless mode refuses UI; cancellation is not approval", async () => {
  const f = fixture();
  assert.equal(f.controller.present(request(), { hasUI: false } as ExtensionContext, () => true), "unavailable");
  assert.equal(f.controller.present(request(), context, () => true), "shown");
  f.shown[0].choose("cancel");
  await tick();
  assert.equal(f.answers[0].action, "cancel");
});

test("UI transport failure is not retried", async () => {
  let attempts = 0, warnings = 0;
  const controller = new PiElicitations(async () => { attempts++; throw Error("disconnected"); }, async () => "accept");
  controller.present(request(), { hasUI: true, ui: { notify: () => { warnings++; } } } as unknown as ExtensionContext, () => true);
  await tick();
  assert.equal(attempts, 1);
  assert.equal(warnings, 1);
  controller.close();
});

test("the terminal renders a bold title, complete wrapped message, and Yes/No keyboard selection", async () => {
  type Component = { render(width: number): string[]; handleInput(data: string): void };
  let view: Component | undefined;
  const ui = { hasUI: true, mode: "tui", ui: {
    custom: async (factory: (...args: any[]) => Component) => new Promise(resolve => {
      view = factory({ requestRender() {} }, { bold: (s: string) => `\x1b[1m${s}\x1b[22m`, fg: (_: string, s: string) => s }, {}, resolve);
    }),
  } } as unknown as ExtensionContext;
  const answer = selectElicitation(ui, request(), new AbortController().signal);
  assert.ok(view);
  const rendered = view.render(80).join("\n");
  assert.ok(rendered.includes("\x1b[1mAgent asks"));
  assert.ok(rendered.includes(request().message));
  assert.ok(rendered.includes("Yes") && rendered.includes("No"));
  view.handleInput("\x1b[B");
  view.handleInput("\r");
  assert.equal(await answer, "decline");
});

test("terminal data cannot inject escape/control sequences", () => {
  const text = terminalQuestion("Full question\n\x1b[2JStill visible\x07");
  assert.equal(text.includes("\x1b"), false);
  assert.equal(text.includes("\x07"), false);
  assert.ok(text.includes("Full question\n"));
});

test("bridge parses bounded confirm-only requests and rejects secret input fields", () => {
  const q = request(), session = "00000001-0000-4000-8000-000000000001";
  const command = { type: "command", requestId: "q-1", axoSessionId: session, action: { kind: "elicitation", ...q } };
  const parse = (value: unknown) => parsePiControlCommand(value, session);
  assert.equal(parse(command).ok, true);
  assert.equal(parse({ ...command, action: { ...command.action, input: {} } }).ok, false);
  assert.equal(parse({ ...command, action: { ...command.action, message: "a".repeat(1001) } }).ok, false);
  assert.equal(parse({ ...command, action: { ...command.action, expiresAt: Infinity } }).ok, false);
});
