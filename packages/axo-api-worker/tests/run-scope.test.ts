import assert from "node:assert/strict";
import { test } from "node:test";
import { DEFAULT_APPS_RUN_LIMITS } from "@axo/protocol";
import { LimitError, outputBytes, RunScope } from "../src/apps/run-scope";

test("one immutable deadline bounds later work and a caught violation cannot reopen it", async () => {
  let now = 100;
  const limits = { ...DEFAULT_APPS_RUN_LIMITS, timeoutMs: 10 };
  const scope = new RunScope(limits, () => now);
  limits.timeoutMs = 999;
  assert.equal(scope.deadline, 110);
  assert.equal(scope.remainingMs(), 10);
  now = 109;
  assert.equal(scope.remainingMs(), 1);
  now = 110;
  assert.throws(() => scope.check(), LimitError);
  now = 100;
  assert.throws(() => scope.check(), /timeoutMs/);
  assert.equal(scope.signal.aborted, true);
  await scope.close();
});

test("closing preserves cleanup ownership and does not touch a completed or different run", async () => {
  const scope = new RunScope();
  const other = new RunScope();
  let release!: () => void;
  let entered = false;
  let completedCallsCancelled = 0;
  const done = scope.onCancel(async () => { completedCallsCancelled++; });
  done();
  scope.onCancel(async () => { entered = true; await new Promise<void>(resolve => { release = resolve; }); });
  let finished = false;
  const closing = scope.close().then(() => { finished = true; });
  await Promise.resolve();
  assert.equal(entered, true);
  assert.equal(finished, false);
  assert.throws(() => scope.onCancel(async () => {}), /ended/);
  assert.equal(other.signal.aborted, false);
  release();
  await closing;
  assert.equal(completedCallsCancelled, 0);
  await scope.close();
  await other.close();
});

test("output includes JSON envelope, console text, UTF-8 and escaping", () => {
  const result = { text: "é🦄\\\n" };
  const logs = ["你好", "console"];
  assert.equal(outputBytes(result, logs), Buffer.byteLength(JSON.stringify({ result, logs }), "utf8"));
  assert.ok(outputBytes(result, logs) > JSON.stringify({ result, logs }).length);
});
