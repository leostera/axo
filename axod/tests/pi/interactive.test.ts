import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile, lstat, symlink } from "node:fs/promises";
import { join } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { fixture, eventually, FixtureFailure, type Runtime } from "./interactive-fixture.ts";
const options = { timeout: 35000 };
const idle = (state: { busy: boolean; interactionId: string | null }) => !state.busy && state.interactionId === null;
const rejected = (code: string) => (error: unknown) => error instanceof FixtureFailure && error.code === code;

// All tests below run ambient CLI in the production Rust Manager's forkpty.
// Model transport/tools are controlled; Pi's TUI, loop and history are not simulated.
test("real interactive Pi: Rust owns PTY, all streams are terminals, readiness/reads never call a model", options, async t => {
  const f = await fixture(t); const pi = await f.launch(await f.profile()); const state = await pi.get();
  assert.equal(state.mode, "tui"); assert.equal(state.stdinTTY, true); assert.equal(state.stdoutTTY, true); assert.equal(state.stderrTTY, true);
  assert.equal(state.pid, pi.terminal.process.pid); assert.equal(state.busy, false); assert.equal(state.interactionId, null);
  assert.ok(state.chatId.length > 0); assert.ok(state.file.startsWith(pi.profile.sessions+"/"));
  await pi.history(); await pi.get(); assert.equal(f.requests(), 0);
});
test("public extension messages run real bash and Pi alone writes canonical Unicode history", options, async t => {
  const f = await fixture(t); const pi = await f.launch(await f.profile());
  assert.equal((await pi.send("WRITE Unicode λ 界 \u2028 \u2029")).disposition, "dispatched");
  await eventually(pi.get, idle);
  assert.equal(await readFile(join(pi.profile.directory, "marker.txt"), "utf8"), "Pi-owned-tool");
  const history = await pi.history(); const state = await pi.get();
  const persisted = (await readFile(state.file, "utf8")).trim().split("\n").map(line => JSON.parse(line));
  assert.equal(persisted[0].id, state.chatId);
  assert.ok(isDeepStrictEqual(persisted.slice(1), history.entries), "Canonical entries must come from Pi, unchanged");
  assert.ok(history.entries.some(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolName === "bash"));
  assert.equal(new Set(history.entries.map(entry => entry.id)).size, history.entries.length);
  assert.equal(f.requests(), 2);
});
test("typed terminal keyboard and extension messages reach the very same TUI/chat/process", options, async t => {
  const f = await fixture(t); const pi = await f.launch(await f.profile());
  const attachment = await f.call({ method: "attach", runtime: pi.runtime });
  await f.call({ method: "input", attachment, text: "Hello from actual terminal\r" });
  await eventually(pi.get, state => idle(state) && f.requests() === 1);
  await pi.send("Hello through extension"); await eventually(pi.get, state => idle(state) && f.requests() === 2);
  const history = await pi.history(); const users = history.entries.filter(entry => entry.type === "message" && entry.message.role === "user");
  assert.equal(users.length, 2); assert.equal((await pi.get()).chatId, pi.target.chatId);
  assert.ok(f.terminalBytes() > 0); // Counts only; terminal text is never parsed.
});
test("busy normal sends reject without conversion; explicit steering joins the captured interactive run", options, async t => {
  const f = await fixture(t); const pi = await f.launch(await f.profile());
  await assert.rejects(pi.steer(crypto.randomUUID(), "Not a normal send"), rejected("staleInteraction"));
  await pi.send("HOLD first interaction");
  const active = await eventually(pi.get, state => state.busy && state.interactionId !== null && f.requests() === 1);
  await assert.rejects(pi.send("Must never silently steer"), rejected("busy"));
  await assert.rejects(pi.steer(crypto.randomUUID(), "Wrong interaction"), rejected("staleInteraction"));
  await assert.rejects(pi.steer(active.interactionId!, "/new"), rejected("invalid"));
  await pi.steer(active.interactionId!, "Explicit steering"); f.release();
  await eventually(pi.get, state => idle(state) && f.requests() === 2);
  const users = (await pi.history()).entries.filter(entry => entry.type === "message" && entry.message.role === "user");
  assert.equal(users.length, 2);
});
test("cancel through public ctx.abort settles a real streamed run and does not cancel its sibling", options, async t => {
  const f = await fixture(t); const one = await f.launch(await f.profile()); const two = await f.launch(await f.profile("sibling"));
  await one.send("HOLD cancel target"); await two.send("HOLD preserve sibling");
  const active = await eventually(one.get, state => state.interactionId !== null && f.requests() === 1);
  const sibling = await eventually(two.get, state => state.interactionId !== null && f.requests("sibling") === 1);
  await one.cancel(active.interactionId!); await eventually(one.get, idle);
  assert.equal((await two.get()).interactionId, sibling.interactionId); assert.equal((await two.get()).busy, true);
  await assert.rejects(one.cancel(active.interactionId!), rejected("staleInteraction"));
  f.release(); await eventually(two.get, idle);
  const history = await one.history(); assert.ok(history.entries.some(entry => entry.type === "message" && entry.message.role === "assistant" && entry.message.stopReason === "aborted"));
});
test("actual TUI dialog blocks sends/steering; public abort dismisses it without approving", options, async t => {
  const f = await fixture(t); const pi = await f.launch(await f.profile()); await pi.send("ASK a real question");
  const question = await eventually(pi.get, state => state.uiWaits > 0 && state.interactionId !== null);
  await assert.rejects(pi.send("Blocked by real selector"), rejected("busy"));
  await assert.rejects(pi.steer(question.interactionId!, "Blocked by real selector"), rejected("blocked"));
  await pi.cancel(question.interactionId!); await eventually(pi.get, state => idle(state) && state.uiWaits === 0);
  const results = (await pi.history()).entries.filter(entry => entry.type === "message" && entry.message.role === "toolResult");
  assert.ok(results.every(entry => !JSON.stringify(entry.message.content).includes("selected:")), "Cancellation cannot become approval");
});
test("a real TUI selector can be answered by terminal input, not invented remote-approval RPC", options, async t => {
  const f = await fixture(t); const pi = await f.launch(await f.profile()); const attachment = await f.call({ method: "attach", runtime: pi.runtime });
  await pi.send("ASK a choice"); await eventually(pi.get, state => state.uiWaits > 0);
  await f.call({ method: "input", attachment, text: "\r" });
  await eventually(pi.get, state => idle(state) && state.uiWaits === 0);
  assert.ok((await pi.history()).entries.some(entry => entry.type === "message" && entry.message.role === "toolResult" && JSON.stringify(entry.message.content).includes("selected:Alpha")));
});
test("no visual terminal or attachment is required; detach and resize preserve accepted Pi work", options, async t => {
  const f = await fixture(t); const pi = await f.launch(await f.profile());
  const attachment = await f.call({ method: "attach", runtime: pi.runtime });
  await f.call({ method: "resize", attachment, rows: 41, columns: 93 });
  await eventually(pi.get, state => state.rows === 41 && state.columns === 93);
  await pi.send("HOLD WRITE after viewport detaches");
  await eventually(pi.get, state => state.busy && f.requests() === 1);
  await f.call({ method: "detach", attachment });
  await assert.rejects(f.call({ method: "input", attachment, text: "Stale input\r" }), rejected("stale_attachment"));
  f.release(); await eventually(pi.get, idle);
  assert.equal(await readFile(join(pi.profile.directory, "marker.txt"), "utf8"), "Pi-owned-tool");
  const next = await f.call({ method: "attach", runtime: pi.runtime });
  assert.notEqual(next.attachment_id, attachment.attachment_id); assert.equal((await pi.get()).pid, pi.terminal.process.pid);
});
test("exact interactive resume preserves actual chat/file/entry IDs and never replays a prompt", options, async t => {
  const f = await fixture(t); const profile = await f.profile(); const pi = await f.launch(profile);
  await pi.send("Persist before resume"); await eventually(pi.get, state => idle(state) && f.requests() === 1);
  const before = await pi.history(); const state = await pi.get(); const bytes = await readFile(state.file);
  await pi.stop(); await eventually(() => f.call({ method: "list" }), terminals => terminals.every((terminal: any) => terminal.process.kind === "exited"));
  const resumed = await f.launch(profile, { target: pi.runtime.target, resume: { file: state.file, chatId: state.chatId, cwd: profile.directory } });
  assert.equal(resumed.target.chatId, state.chatId); assert.notEqual(resumed.runtime.runtime_generation, pi.runtime.runtime_generation);
  assert.ok(JSON.stringify((await resumed.history()).entries) === JSON.stringify(before.entries), "Exact resume must preserve canonical tree");
  assert.ok((await readFile(state.file)).equals(bytes), "Readiness must not rewrite persisted history"); assert.equal(f.requests(), 1);
  await resumed.send("New explicit input after resume"); await eventually(resumed.get, s => idle(s) && f.requests() === 2);
  assert.equal((await resumed.history()).entries.filter(entry => entry.type === "message" && entry.message.role === "user").length, 2);
});
test("wrong resume bindings and symlinks fail before launch, preserving original bytes", options, async t => {
  const f = await fixture(t); const profile = await f.profile(); const pi = await f.launch(profile);
  await pi.send("Persist original"); await eventually(pi.get, s => idle(s) && f.requests() === 1); const state = await pi.get();
  await pi.stop(); await eventually(() => f.call({ method: "list" }), terminals => terminals.every((terminal: any) => terminal.process.kind === "exited"));
  const bytes = await readFile(state.file);
  await assert.rejects(f.launch(profile, { resume: { file: state.file, chatId: "wrong", cwd: profile.directory } }), rejected("badResume"));
  const link = join(profile.sessions, "alias.jsonl"); await symlink(state.file, link);
  await assert.rejects(f.launch(profile, { resume: { file: link, chatId: state.chatId, cwd: profile.directory } }), rejected("badResume"));
  assert.ok((await readFile(state.file)).equals(bytes)); assert.equal(f.requests(), 1);
});
test("wrong chat/runtime/host destinations cannot retarget interactive controls or run a model", options, async t => {
  const f = await fixture(t); const pi = await f.launch(await f.profile());
  await assert.rejects(f.command(pi.runtime, { method: "send", target: { ...pi.target, chatId: crypto.randomUUID() }, text: "Never deliver" }), rejected("stale"));
  const wrongRuntime: Runtime = { ...pi.runtime, host_generation: crypto.randomUUID() };
  await assert.rejects(f.command(pi.runtime, { method: "send", target: { ...pi.target, runtime: wrongRuntime }, text: "Never deliver" }), rejected("stale"));
  assert.equal(f.requests(), 0); assert.equal((await pi.get()).busy, false);
});
test("immediate concurrent sends dispatch once, with no extension-owned execution queue", options, async t => {
  const f = await fixture(t); const pi = await f.launch(await f.profile());
  const outcomes = await Promise.allSettled([pi.send("HOLD first"), pi.send("HOLD overlapping")]);
  assert.equal(outcomes.filter(value => value.status === "fulfilled").length, 1);
  assert.equal(outcomes.filter(value => value.status === "rejected").length, 1);
  await eventually(pi.get, state => state.busy && f.requests() === 1); f.release(); await eventually(pi.get, idle);
  assert.equal((await pi.history()).entries.filter(entry => entry.type === "message" && entry.message.role === "user").length, 1);
});
test("actual provider failure after dispatch is persisted by Pi, not reported as known rejection", options, async t => {
  const f = await fixture(t); const pi = await f.launch(await f.profile());
  assert.equal((await pi.send("FAIL_PROVIDER")).disposition, "dispatched");
  await eventually(pi.get, s => idle(s) && f.requests() === 1);
  assert.ok((await pi.history()).entries.some(entry => entry.type === "message" && entry.message.role === "assistant" && entry.message.stopReason === "error"));
});
test("high TUI output drains while detached and Rust backlog stays bounded", options, async t => {
  const f = await fixture(t); const pi = await f.launch(await f.profile()); await pi.send("FLOOD output without renderer");
  await eventually(pi.get, s => idle(s) && f.requests() === 1);
  const terminals = await f.call({ method: "list" });
  assert.ok(terminals[0].backlog_bytes > 0 && terminals[0].backlog_bytes <= 8192); assert.equal(terminals[0].attached, false);
});
test("owned runtime stop ends actual Pi/TTY resources and does not stop a sibling", options, async t => {
  const f = await fixture(t); const one = await f.launch(await f.profile()); const two = await f.launch(await f.profile("sibling"));
  await one.stop(); await eventually(() => f.call({ method: "list" }), terminals => terminals.find((terminal: any) => terminal.runtime.runtime_generation === one.runtime.runtime_generation).process.kind === "exited");
  assert.equal((await two.get()).busy, false); await two.send("Sibling remains usable"); await eventually(two.get, s => idle(s) && f.requests("sibling") === 1);
});
test("real bash tool cancellation stops its side effect before the interactive run settles", options, async t => {
  const f = await fixture(t); const pi = await f.launch(await f.profile()); await pi.send("SLOW_TOOL cancellation");
  const active = await eventually(pi.get, s => s.busy && s.interactionId !== null && s.tools.length > 0 && f.requests() === 1);
  await pi.cancel(active.interactionId!); await eventually(pi.get, idle);
  await assert.rejects(lstat(join(pi.profile.directory, "cancelled-tool.txt")), { code: "ENOENT" });
});
test("actual Pi tool children do not inherit the managed control endpoint", options, async t => {
  const f = await fixture(t); const pi = await f.launch(await f.profile()); await pi.send("PROBE_FD actual bash child");
  await eventually(pi.get, s => idle(s) && f.requests() === 2);
  assert.equal(await readFile(join(pi.profile.directory, "tool-fds.txt"), "utf8"), "[]");
  assert.equal((await pi.get()).mode, "tui");
});
test("two real interactive sessions have independent chat IDs, cwd, history and tool effects", options, async t => {
  const f = await fixture(t); const one = await f.launch(await f.profile()); const two = await f.launch(await f.profile("sibling"));
  await Promise.all([one.send("WRITE first session"), two.send("WRITE second session")]);
  await eventually(one.get, s => idle(s) && f.requests() === 2); await eventually(two.get, s => idle(s) && f.requests("sibling") === 2);
  assert.notEqual(one.target.chatId, two.target.chatId); assert.notEqual((await one.get()).file, (await two.get()).file);
  assert.equal(await readFile(join(one.profile.directory, "marker.txt"), "utf8"), "Pi-owned-tool");
  assert.equal(await readFile(join(two.profile.directory, "marker.txt"), "utf8"), "Pi-owned-tool");
  assert.ok(!(await one.history()).entries.some(entry => entry.type === "message" && entry.message.role === "user" && JSON.stringify(entry.message.content).includes("second session")));
});
test("a second live writer for the same owned pane rejects before another Pi is spawned", options, async t => {
  const f = await fixture(t); const profile = await f.profile(); const commandId = crypto.randomUUID(); const pi = await f.launch(profile, { commandId });
  await assert.rejects(f.launch(profile, { target: pi.runtime.target }), rejected("conflict"));
  await assert.rejects(f.launch(profile, { target: pi.runtime.target, commandId }), rejected("recovery_required"));
  assert.equal((await f.call({ method: "list" })).length, 1); assert.equal((await pi.get()).pid, pi.terminal.process.pid); assert.equal(f.requests(), 0);
});
test("invalid internal messages reject before Pi API dispatch and preserve idle state", options, async t => {
  const f = await fixture(t); const pi = await f.launch(await f.profile());
  for (const text of ["", "   ", "\ud800", "/new"]) {
    await assert.rejects(pi.send(text), rejected("invalid"));
  }
  assert.equal(f.requests(), 0); assert.equal((await pi.get()).busy, false);
});
test("interactive public abort removes queued steering from execution, unlike the discarded headless mode", options, async t => {
  const f = await fixture(t); const pi = await f.launch(await f.profile()); await pi.send("HOLD queued cancellation");
  const active = await eventually(pi.get, s => s.interactionId !== null && f.requests() === 1);
  await pi.steer(active.interactionId!, "Queued steering before abort"); await pi.cancel(active.interactionId!);
  const settled = await eventually(pi.get, idle);
  assert.equal(settled.pending, false); // Observed interactive behavior; no private clear-queue API.
  assert.equal(f.requests(), 1);
  assert.equal((await pi.history()).entries.filter(entry => entry.type === "message" && entry.message.role === "user").length, 1);
  await pi.send("New explicit input after cancellation"); await eventually(pi.get, s => idle(s) && f.requests() === 2);
  assert.equal((await pi.history()).entries.filter(entry => entry.type === "message" && entry.message.role === "user").length, 2);
});

test("private channel schema and byte budgets reject without executing Pi or stopping its TUI", options, async t => {
  const f = await fixture(t); const pi = await f.launch(await f.profile());
  await assert.rejects(f.command(pi.runtime, { method: "send", target: pi.target, text: "Would run", extra: true }), rejected("invalid"));
  await assert.rejects(f.command(pi.runtime, { method: "invented", target: pi.target }), rejected("invalid"));
  await assert.rejects(pi.send("界".repeat(23000)), rejected("capacity"));
  assert.equal(f.requests(), 0); assert.equal((await pi.get()).mode, "tui"); assert.equal((await pi.get()).busy, false);
});

test("an actual public input hook consuming a void send is uncertain dispatch, never fabricated execution or retry", options, async t => {
  const f = await fixture(t); const pi = await f.launch(await f.profile());
  assert.equal((await pi.send("FIXTURE_HANDLED_INPUT")).disposition, "dispatched");
  const state = await eventually(pi.get, state => state.recovery);
  assert.equal(state.interactionId, null); assert.equal(f.requests(), 0);
  assert.equal((await pi.history()).entries.filter(entry => entry.type === "message" && entry.message.role === "user").length, 0);
  await assert.rejects(pi.send("No replay after consumed dispatch"), rejected("recovery"));
  assert.equal(f.requests(), 0);
});

test("public Pi shutdown is observed as terminal EOF/reaping; reads cannot restart it", options, async t => {
  const f = await fixture(t); const pi = await f.launch(await f.profile());
  assert.equal((await f.command(pi.runtime, { method: "shutdown", target: pi.target })).disposition, "dispatched");
  await eventually(() => f.call({ method: "list" }), terminals => terminals.every((terminal: any) => terminal.process.kind === "exited"));
  await assert.rejects(pi.get(), rejected("controlGap"));
  assert.equal(f.requests(), 0); assert.equal((await f.call({ method: "list" })).length, 1);
});
