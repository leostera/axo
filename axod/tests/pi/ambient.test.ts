// Discovery/version fixtures only, not positive Pi execution evidence.
import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { delimiter, join, resolve } from "node:path";
import { AmbientPi } from "../../pi/ambient.ts";
import { PiFailure } from "../../pi/process.ts";
async function binary(t: TestContext, version: string) {
  const root = await mkdtemp("/tmp/axo-ambient-probe-");
  t.after(() => rm(root, { recursive: true, force: true }));
  const executable = join(root, "pi");
  await writeFile(executable, `#!/bin/sh\nprintf '%s\\n' '${version}'\n`, { mode: 0o700 });
  return { root, executable };
}

test("missing ambient Pi never falls back to the repository dependency", async () => {
  await assert.rejects(AmbientPi.find({ path: "" }), error => error instanceof PiFailure && /Ambient Pi is missing/.test(error.message));
});
test("npm-injected local .bin is skipped and explicit repo runtime paths are refused", async t => {
  const selected = await binary(t, "1.2.3");
  const local = resolve("node_modules/.bin");
  const pi = await AmbientPi.find({ path: [local, selected.root].join(delimiter) });
  assert.equal(pi.executable, selected.executable); assert.equal(pi.version, "1.2.3");
  await assert.rejects(AmbientPi.find({ executable: join(local, "pi") }));
  await assert.rejects(AmbientPi.find({ executable: resolve("node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js") }));
});
test("unsupported first ambient executable fails clearly instead of switching to another installation", async t => {
  const old = await binary(t, "0.62.0"); const other = await binary(t, "1.2.3");
  await assert.rejects(AmbientPi.find({ path: [old.root, other.root].join(delimiter) }), error => error instanceof PiFailure && /Ambient Pi is unsupported/.test(error.message));
});
test("later compatible ambient versions are accepted without an exact package pin", async t => {
  const selected = await binary(t, "1.2.3");
  const pi = await AmbientPi.find({ executable: selected.executable });
  assert.equal(pi.version, "1.2.3"); assert.ok(Object.isFrozen(pi));
});
test("ordinary ambient launcher symlinks remain launch paths, not resolved implementation paths", async t => {
  const selected = await binary(t, "1.1.0");
  const bin = join(selected.root, "bin"); await mkdir(bin, { mode: 0o700 });
  const launcher = join(bin, "pi"); await symlink(selected.executable, launcher);
  const pi = await AmbientPi.find({ path: bin }); assert.equal(pi.executable, launcher);
});
test("probe errors and invalid version output never leak subprocess diagnostics", async t => {
  const selected = await binary(t, "synthetic-sensitive-version-body");
  await assert.rejects(AmbientPi.find({ executable: selected.executable }), error => error instanceof PiFailure && !error.message.includes("synthetic-sensitive-version-body"));
});
