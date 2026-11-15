import assert from "node:assert/strict";
import test from "node:test";
import { ResumeTurnControl } from "../src/resume-turn.js";

test("resumes once with no prompt/message channel and acknowledges duplicate receipts", () => {
  let calls = 0;
  const control = new ResumeTurnControl({
    isIdle: () => true,
    hasQueuedPrompts: () => false,
    resume: () => {
      calls++;
    },
    unsupported: () => assert.fail(),
  });
  assert.deepEqual(control.take(), { accepted: true });
  assert.deepEqual(control.take(), { accepted: true });
  assert.equal(calls, 1);
});
test("busy or restored queued real prompts win over recovery", () => {
  for (const [idle, queued] of [
    [false, false],
    [true, true],
  ]) {
    let calls = 0;
    const control = new ResumeTurnControl({
      isIdle: () => idle!,
      hasQueuedPrompts: () => queued!,
      resume: () => {
        calls++;
      },
      unsupported: () => assert.fail(),
    });
    assert.deepEqual(control.take(), { accepted: false, reason: "busy" });
    assert.equal(calls, 0);
  }
});
test("an unsupported SDK is explicit, never a fabricated-message fallback", () => {
  let notices = 0;
  const control = new ResumeTurnControl({
    isIdle: () => true,
    hasQueuedPrompts: () => false,
    unsupported: () => {
      notices++;
    },
  });
  assert.deepEqual(control.take(), { accepted: false, reason: "unavailable" });
  assert.equal(notices, 1);
});
test("an uncertain host error cannot cause a second resume", () => {
  let calls = 0;
  const control = new ResumeTurnControl({
    isIdle: () => true,
    hasQueuedPrompts: () => false,
    resume: () => {
      calls++;
      throw Error("unknown receipt");
    },
    unsupported: () => assert.fail(),
  });
  assert.throws(() => control.take(), /unknown receipt/);
  assert.deepEqual(control.take(), { accepted: true });
  assert.equal(calls, 1);
});
