import assert from "node:assert/strict";
import { test } from "node:test";
import { APPS_LIMITS, APPS_METHODS, appsParams, appsRunLimitsSchema, DEFAULT_APPS_RUN_LIMITS } from "../src/apps.ts";

test("run limits have existing defaults and explicit independent ceilings", () => {
  assert.deepEqual(appsRunLimitsSchema.parse({}), { timeoutMs: APPS_LIMITS.scriptWallMs, maxToolCalls: 100, maxConcurrentCalls: 4, maxOutputBytes: APPS_LIMITS.resultBytes });
  assert.deepEqual(appsRunLimitsSchema.parse({ timeoutMs: 10 }), { ...DEFAULT_APPS_RUN_LIMITS, timeoutMs: 10 });
  assert.equal(appsParams[APPS_METHODS.execute].parse({ sessionId: "00000001-0000-4000-8000-000000000001", code: "async () => 1" }).limits, undefined);
  for (const key of Object.keys(DEFAULT_APPS_RUN_LIMITS) as Array<keyof typeof DEFAULT_APPS_RUN_LIMITS>) {
    const max = DEFAULT_APPS_RUN_LIMITS[key];
    assert.equal(appsRunLimitsSchema.parse({ [key]: max })[key], max);
    assert.equal(appsRunLimitsSchema.parse({ [key]: 1 })[key], 1);
    for (const invalid of [0, -1, 0.5, max + 1, Infinity, NaN, "1", null, true]) {
      assert.equal(appsRunLimitsSchema.safeParse({ [key]: invalid }).success, false, `${key}: ${invalid}`);
    }
  }
  for (const invalid of [{ timeout: 10 }, [], null, { maxToolCalls: 1, unknown: 1 }]) assert.equal(appsRunLimitsSchema.safeParse(invalid).success, false);
});
