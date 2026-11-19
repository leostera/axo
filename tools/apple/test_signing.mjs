import assert from "node:assert/strict";
import test from "node:test";
import { parseOptions } from "./sign_macos.ts";

test("the signing adapter parses explicit operation/source/tool references without loading credentials", () => {
  assert.deepEqual(parseOptions(["--help"]), { help: true });
  const common = ["--app", "/private/Axo.app", "--run-dir", "/private/run", "--tool-root", "/private/sdk", "--source", "a".repeat(40)];
  const local = parseOptions(["--mode", "local", ...common]);
  assert.equal(local.mode, "local");
  assert.equal(local.source, "a".repeat(40));
  assert.throws(() => parseOptions(["--mode", "release", ...common]), /approval/);
  assert.equal(parseOptions(["--mode", "release", ...common, "--approval-file", "/private/approval.json"]).mode, "release");
  assert.throws(() => parseOptions(["--mode", "local", ...common, "--source", "main"]), /source/);
  assert.throws(() => parseOptions(["--mode", "unknown", ...common]), /Choose/);
});
