import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile, writeFile, symlink, mkdir, rename, lstat, rm } from "node:fs/promises";
import { join } from "node:path";
import { fixture, eventually } from "./fixture.ts";
import { ManagedPi } from "../../pi/runtime.ts";
import { PiFailure, PiProcess } from "../../pi/process.ts";
import { AmbientPi } from "../../pi/ambient.ts";
const rejected = (error: unknown) => error instanceof PiFailure && error.kind === "rejected";

test("real Pi fresh start admits canonical identity without running a model; reads do not execute", { timeout: 20000 }, async t => {
  const f = await fixture(t); const profile = await f.profile(); const pi = await f.start(profile);
  const snapshot = await pi.snapshot(pi.target);
  assert.match(pi.target.chatId, /^[a-f0-9-]{36}$/);
  assert.equal(snapshot.busy, false); assert.equal(snapshot.interactionId, null);
  assert.deepEqual((await pi.history(pi.target)).entries.filter((entry: any) => entry.type === "message"), []);
  assert.equal(f.requests(), 0);
  await assert.rejects(ManagedPi.start(profile, { kind: "fresh" }), error => error instanceof PiFailure && error.kind === "recovery");
  assert.equal(f.requests(), 0);
});

test("real Pi messages, Unicode framing and tool execution persist only through Pi", { timeout: 20000 }, async t => {
  const f = await fixture(t); const profile = await f.profile(); const pi = await f.start(profile);
  assert.equal(await pi.send(pi.target, "WRITE a marker"), "started");
  await eventually(() => pi.snapshot(pi.target), state => !state.busy && state.interactionId === null);
  assert.equal(await readFile(join(profile.cwd, "marker.txt"), "utf8"), "Pi-owned-tool");
  const history = await pi.history(pi.target);
  const messages = history.entries.filter((entry: any) => entry.type === "message") as any[];
  assert.ok(messages.some(entry => entry.message.role === "user"));
  assert.ok(messages.some(entry => entry.message.role === "toolResult"));
  assert.ok(messages.some(entry => entry.message.role === "assistant" && JSON.stringify(entry.message.content).includes("\u2028output\u2029")));
  assert.ok(messages.every(entry => typeof entry.id === "string" && "parentId" in entry));
  const records = (await readFile(pi.persistence.file, "utf8")).trim().split("\n").map(line => JSON.parse(line));
  assert.equal(records[0].id, pi.target.chatId);
  assert.ok(records.some(entry => entry.type === "message" && entry.message.role === "toolResult"));
  const requests = f.requests();
  const after = await pi.history(pi.target, history.leafId!);
  assert.deepEqual(after.entries, []); assert.equal(after.leafId, history.leafId);
  assert.equal(f.requests(), requests);
});

test("exact resume restores the same Pi tree, rotates runtime identity and never replays a prompt", { timeout: 25000 }, async t => {
  const f = await fixture(t); const profile = await f.profile(); const pi = await f.start(profile);
  await pi.send(pi.target, "First persisted prompt");
  await eventually(() => pi.snapshot(pi.target), state => !state.busy && state.interactionId === null);
  const original = await pi.history(pi.target); const persistence = pi.persistence; const oldTarget = pi.target;
  await pi.stop(); const count = f.requests();
  const resumed = await f.start(profile, { kind: "resume", ...persistence });
  assert.equal(resumed.target.chatId, oldTarget.chatId);
  assert.notEqual(resumed.target.runtimeGeneration, oldTarget.runtimeGeneration);
  assert.deepEqual(await resumed.history(resumed.target), original);
  await assert.rejects(resumed.send(oldTarget, "Must never execute"), rejected);
  assert.equal(f.requests(), count);
  await resumed.send(resumed.target, "Second explicit prompt");
  await eventually(() => resumed.snapshot(resumed.target), state => !state.busy && state.interactionId === null);
  assert.equal(f.requests(), count + 1);
  assert.ok((await resumed.history(resumed.target)).entries.length > original.entries.length);
});

test("missing, wrong-ID, cross-context, symlink and legacy resume bindings reject without rewriting originals", { timeout: 25000 }, async t => {
  const f = await fixture(t); const profile = await f.profile(); const pi = await f.start(profile);
  await pi.send(pi.target, "Persist original");
  await eventually(() => pi.snapshot(pi.target), state => !state.busy);
  const persistence = pi.persistence; await pi.stop();
  const original = await readFile(persistence.file);
  const count = f.requests();
  const missing = { ...persistence, file: join(profile.sessionDirectory, "missing.jsonl") };
  await assert.rejects(f.start(profile, { kind: "resume", ...missing }));
  await assert.rejects(f.start(profile, { kind: "resume", ...persistence, chatId: crypto.randomUUID() }));
  const alias = join(profile.sessionDirectory, "alias.jsonl"); await symlink(persistence.file, alias);
  await assert.rejects(f.start(profile, { kind: "resume", ...persistence, file: alias }));
  const alternate = await f.profile("alternate");
  await assert.rejects(f.start(alternate, { kind: "resume", ...persistence }));
  const legacy = join(profile.sessionDirectory, "legacy.jsonl");
  const legacyBytes = Buffer.from(JSON.stringify({ type: "session", version: 1, id: persistence.chatId, cwd: profile.cwd }) + "\n");
  await writeFile(legacy, legacyBytes, { mode: 0o600 });
  await assert.rejects(f.start(profile, { kind: "resume", ...persistence, file: legacy }));
  assert.deepEqual(await readFile(legacy), legacyBytes);
  const corrupt = join(profile.sessionDirectory, "corrupt.jsonl");
  for (const bytes of [Buffer.concat([original, Buffer.from("{malformed}\n")]), original.subarray(0, original.length - 1)]) {
    await writeFile(corrupt, bytes, { mode: 0o600 });
    await assert.rejects(f.start(profile, { kind: "resume", ...persistence, file: corrupt }));
    assert.deepEqual(await readFile(corrupt), bytes);
  }
  assert.deepEqual(await readFile(persistence.file), original);
  assert.equal(f.requests(), count);
});

test("normal input never steers busy Pi; explicit steering reaches the captured interaction", { timeout: 25000 }, async t => {
  const f = await fixture(t); const pi = await f.start(await f.profile());
  await assert.rejects(pi.steer({ ...pi.target, interactionId: crypto.randomUUID() }, "idle steering"), rejected);
  assert.equal(f.requests(), 0);
  await pi.send(pi.target, "HOLD this interaction");
  const running = await eventually(() => pi.snapshot(pi.target), state => state.busy && state.interactionId !== null && f.requests() === 1);
  await assert.rejects(pi.send(pi.target, "Do not implicitly steer"), rejected);
  await assert.rejects(pi.steer({ ...pi.target, interactionId: crypto.randomUUID() }, "Wrong interaction"), rejected);
  assert.equal(await pi.steer({ ...pi.target, interactionId: running.interactionId! }, "Explicit steering"), "queued");
  f.release();
  await eventually(() => pi.snapshot(pi.target), state => !state.busy && state.interactionId === null);
  assert.equal(f.requests(), 2);
  const users = (await pi.history(pi.target)).entries.filter((entry: any) => entry.type === "message" && entry.message.role === "user") as any[];
  assert.equal(users.length, 2);
  assert.ok(JSON.stringify(users[1].message.content).includes("Explicit steering"));
  await assert.rejects(pi.steer({ ...pi.target, interactionId: running.interactionId! }, "Late steering"), rejected);
});

test("cancel clears pending steering, observes settlement and preserves a sibling Pi runtime", { timeout: 25000 }, async t => {
  const f = await fixture(t);
  const first = await f.start(await f.profile()); const sibling = await f.start(await f.profile("sibling"));
  await first.send(first.target, "HOLD until cancellation");
  const active = await eventually(() => first.snapshot(first.target), state => state.busy && state.interactionId !== null && f.requests() === 1);
  const target = { ...first.target, interactionId: active.interactionId! };
  await first.steer(target, "Must not execute after cancel");
  await assert.rejects(first.cancel({ ...target, interactionId: crypto.randomUUID() }), rejected);
  assert.equal(await first.cancel(target), "settled");
  const count = f.requests(); f.release();
  await new Promise(resolve => setTimeout(resolve, 100)); assert.equal(f.requests(), count);
  await assert.rejects(first.cancel(target), rejected);
  await sibling.send(sibling.target, "Sibling still works");
  await eventually(() => sibling.snapshot(sibling.target), state => !state.busy && state.interactionId === null);
  assert.equal(f.requests(), count + 1);
  await first.send(first.target, "Next deliberate normal input");
  await eventually(() => first.snapshot(first.target), state => !state.busy && state.interactionId === null);
  const users = (await first.history(first.target)).entries.filter((entry: any) => entry.type === "message" && entry.message.role === "user");
  assert.equal(users.length, 2); // Original plus deliberate new input, not the cancelled steering.
});

test("actual RPC UI questions block sends/steering and validate offered, scoped, one-attempt answers", { timeout: 25000 }, async t => {
  const f = await fixture(t); const pi = await f.start(await f.profile()); await pi.send(pi.target, "ASK a controlled question");
  const pending = await eventually(() => pi.snapshot(pi.target), state => state.question !== null);
  const target = { ...pi.target, interactionId: pending.interactionId! };
  const question = pending.question!;
  await assert.rejects(pi.send(pi.target, "Question must block normal send"), rejected);
  await assert.rejects(pi.steer(target, "Question must block steering"), rejected);
  await assert.rejects(pi.answer(target, "wrong-question", "Alpha"), rejected);
  await assert.rejects(pi.answer(target, question.id as string, "Not offered"), rejected);
  assert.equal(await pi.answer(target, question.id as string, "Beta"), "dispatched");
  await assert.rejects(pi.answer(target, question.id as string, "Beta"), rejected);
  await eventually(() => pi.snapshot(pi.target), state => !state.busy && state.interactionId === null);
  const history = await pi.history(pi.target);
  assert.ok(history.entries.some((entry: any) => entry.type === "message" && entry.message.role === "toolResult" && JSON.stringify(entry.message.content).includes("selected:Beta")));
});

test("cancelling a real pending Pi dialog never interprets cancellation as approval", { timeout: 25000 }, async t => {
  const f = await fixture(t); const pi = await f.start(await f.profile()); await pi.send(pi.target, "ASK before cancellation");
  const pending = await eventually(() => pi.snapshot(pi.target), state => state.question !== null);
  const target = { ...pi.target, interactionId: pending.interactionId! };
  await pi.cancel(target);
  const history = await pi.history(pi.target);
  assert.ok(!history.entries.some((entry: any) => entry.type === "message" && entry.message.role === "toolResult" && /selected:(Alpha|Beta)/.test(JSON.stringify(entry.message.content))));
  await assert.rejects(pi.answer(target, pending.question!.id as string, "Alpha"), rejected);
});

test("wrong chat/runtime and overlapping sends never retarget or duplicate real Pi execution", { timeout: 25000 }, async t => {
  const f = await fixture(t); const pi = await f.start(await f.profile());
  await assert.rejects(pi.send({ ...pi.target, chatId: crypto.randomUUID() }, "wrong chat"), rejected);
  await assert.rejects(pi.send({ ...pi.target, runtimeGeneration: crypto.randomUUID() }, "wrong runtime"), rejected);
  const replies = await Promise.allSettled([pi.send(pi.target, "HOLD accepted only once"), pi.send(pi.target, "second competing input")]);
  assert.equal(replies.filter(reply => reply.status === "fulfilled").length, 1);
  await eventually(() => pi.snapshot(pi.target), state => state.busy && f.requests() === 1);
  f.release(); await eventually(() => pi.snapshot(pi.target), state => !state.busy && state.interactionId === null);
  assert.equal(f.requests(), 1);
});

test("real Pi handled input is not a run; accepted provider failure is not prompt rejection", { timeout: 25000 }, async t => {
  const f = await fixture(t); const pi = await f.start(await f.profile());
  assert.equal(await pi.send(pi.target, "CONSUME"), "handled");
  assert.equal(f.requests(), 0); assert.equal((await pi.snapshot(pi.target)).interactionId, null);
  assert.equal(await pi.send(pi.target, "FAIL_PROVIDER"), "started");
  await eventually(() => pi.snapshot(pi.target), state => !state.busy && state.interactionId === null);
  assert.ok((await pi.history(pi.target)).entries.some((entry: any) => entry.type === "message" && entry.message.role === "assistant" && entry.message.stopReason === "error"));
  assert.equal(f.requests(), 1);
});

test("unsafe startup arguments and oversized Unicode input reject before any model work", { timeout: 20000 }, async t => {
  const f = await fixture(t); const profile = await f.profile();
  for (const args of [["--continue"], ["--no-session"], ["--session-id", "invented"], ["--mode", "json"], ["--api-key", "fixture-not-a-credential"], ["Implicit initial prompt"]]) {
    await assert.rejects(f.start({ ...profile, args }), rejected);
  }
  const pi = await f.start(profile);
  await assert.rejects(pi.send(pi.target, "😃".repeat(17000)), rejected);
  assert.equal((await pi.snapshot(pi.target)).busy, false); assert.equal(f.requests(), 0);
});

test("invalid executable fails admission and releases only its own lease", { timeout: 20000 }, async t => {
  const f = await fixture(t); const profile = await f.profile();
  const executable = join(profile.cwd, "disappearing-pi");
  await writeFile(executable, "#!/bin/sh\nprintf '1.1.0\\n'\n", { mode: 0o700 });
  const selected = await AmbientPi.find({ executable });
  await rm(executable);
  await assert.rejects(f.start({ ...profile, pi: selected }));
  await assert.rejects(lstat(join(profile.sessionDirectory, ".writer")), { code: "ENOENT" });
  const pi = await f.start(profile); assert.equal((await pi.snapshot(pi.target)).busy, false);
});

test("unclean leases require recovery and old cleanup cannot remove a successor", { timeout: 20000 }, async t => {
  const f = await fixture(t); const profile = await f.profile();
  const lease = join(profile.sessionDirectory, ".writer");
  await mkdir(lease, { mode: 0o700 });
  await assert.rejects(f.start(profile), error => error instanceof PiFailure && error.kind === "recovery");
  const stale = join(profile.sessionDirectory, ".unclean"); await rename(lease, stale);
  const pi = await f.start(profile);
  await rename(lease, join(profile.sessionDirectory, ".old-owned-lease"));
  await mkdir(lease, { mode: 0o700 });
  const successor = await lstat(lease); await pi.stop();
  assert.equal((await lstat(lease)).ino, successor.ino);
});

test("captured interaction targets cannot change during an asynchronous control preflight", { timeout: 25000 }, async t => {
  const f = await fixture(t); const pi = await f.start(await f.profile()); await pi.send(pi.target, "HOLD captured interaction");
  const active = await eventually(() => pi.snapshot(pi.target), state => state.busy && state.interactionId !== null && f.requests() === 1);
  const target = { ...pi.target, interactionId: active.interactionId! };
  const pending = pi.steer(target, "Steer captured original");
  target.chatId = "Changed while waiting"; target.interactionId = "Changed while waiting";
  assert.equal(await pending, "queued");
  f.release(); await eventually(() => pi.snapshot(pi.target), state => !state.busy && state.interactionId === null);
  assert.equal(f.requests(), 2);
});

test("Pi primitives permit idle steering and abort retains queued input: Axo guards are necessary", { timeout: 25000 }, async t => {
  const f = await fixture(t); const profile = await f.profile();
  const child = new PiProcess(profile.pi.executable, [...profile.args, "--mode", "rpc", "--no-session"], profile.cwd, profile.env);
  f.own(child);
  await child.request("get_state");
  assert.deepEqual((await child.request("steer", { message: "Latent idle steer" })).data, { disposition: "queued" });
  assert.equal(((await child.request("get_state")).data as any).pendingMessageCount, 1);
  assert.equal(f.requests(), 0); await child.request("clear_queue");
  await child.request("prompt", { message: "HOLD native primitive" });
  await eventually(async () => (await child.request("get_state")).data as any, state => state.isStreaming && f.requests() === 1);
  await child.request("steer", { message: "Continuation after native abort" });
  await child.request("abort");
  const state = (await child.request("get_state")).data as any;
  assert.equal(state.isStreaming, false);
  assert.equal(state.pendingMessageCount, 1);
  assert.equal(f.requests(), 1); // Abort retained the steering queue; it did not cancel that intent.
});

test("startup captures approved context before awaits; concurrent starts admit exactly one writer", { timeout: 20000 }, async t => {
  const f = await fixture(t); const profile = await f.profile(); const originalDirectory = profile.cwd;
  const first = f.start(profile);
  profile.cwd = "/"; profile.args = ["Never run this implicit prompt"];
  const pi = await first;
  await pi.send(pi.target, "WRITE only in captured context");
  await eventually(() => pi.snapshot(pi.target), state => !state.busy && state.interactionId === null);
  assert.equal(await readFile(join(originalDirectory, "marker.txt"), "utf8"), "Pi-owned-tool");
  const other = await f.profile("concurrent");
  const results = await Promise.allSettled([f.start(other), f.start(other)]);
  assert.equal(results.filter(result => result.status === "fulfilled").length, 1);
  assert.equal(results.filter(result => result.status === "rejected").length, 1);
});

test("explicit stop is observed once, removes the owned lease and cannot restart through reads or controls", { timeout: 20000 }, async t => {
  const f = await fixture(t); const profile = await f.profile(); const pi = await f.start(profile);
  await Promise.all([pi.stop(), pi.stop()]);
  for (const operation of [() => pi.snapshot(pi.target), () => pi.history(pi.target), () => pi.send(pi.target, "Never replay after stop")]) {
    await assert.rejects(operation(), error => error instanceof PiFailure && error.kind === "recovery");
  }
  assert.equal(f.requests(), 0);
  await assert.rejects(lstat(join(profile.sessionDirectory, ".writer")), { code: "ENOENT" });
});
