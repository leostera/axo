import assert from "node:assert/strict";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { cliSetupScript, installScript } from "../src/install.ts";

const quote = value => `'${value.replaceAll("'", `'\\''`)}'`;

test("installer sets up CLI only after app replacement, before launching it", () => {
  const script = installScript("https://axo.test", null);
  assert.equal(spawnSync("sh", ["-n"], { input: script }).status, 0);
  assert.ok(script.indexOf('if ! mv "$new_app" "$app"') < script.indexOf("\ninstall_cli\n"));
  assert.ok(script.indexOf("\ninstall_cli\n") < script.indexOf('say "Starting Axo"'));
  assert.match(script, /cli install --system/);
  assert.match(script, /\/usr\/bin\/defaults write dev\.leostera\.axo cli\.commandSetupOffered\.v1 -bool true/);
});

for (const [name, optOut, result, expectedCalls] of [
  ["success", "1", "0", 1],
  ["cancelled or failed authorization", "1", "2", 1],
  ["explicit opt-out", "0", "0", 0],
]) test(`CLI setup ${name} records choice and never prevents app installation`, () => {
  const root = mkdtempSync(join(tmpdir(), "axo-cli-setup-"));
  try {
    const app = join(root, "Axo's test.app");
    const helpers = join(app, "Contents/Helpers");
    mkdirSync(helpers, { recursive: true });
    const calls = join(root, "cli-calls");
    const preferences = join(root, "preference-calls");
    // All writes stay inside this fixture. In particular, replace the OS preferences tool;
    // never execute the real installer, its privileged path, or defaults against the person's profile.
    writeFileSync(join(helpers, "axo"), '#!/bin/sh\nprintf "%s\\n" "$@" >> "$CLI_CALLS"\nexit "$CLI_RESULT"\n', { mode: 0o755 });
    const fakeDefaults = join(root, "defaults");
    writeFileSync(fakeDefaults, '#!/bin/sh\nprintf "%s\\n" "$@" >> "$PREFERENCE_CALLS"\n', { mode: 0o755 });
    const helper = cliSetupScript().replaceAll("/usr/bin/defaults", quote(fakeDefaults));
    const script = `set -eu\napp=${quote(app)}\nsay() { :; }\nwarn() { printf '%s\\n' "$*" >&2; }\n${helper}\ninstall_cli\nprintf done`;
    const run = spawnSync("sh", ["-c", script], { encoding: "utf8", env: { ...process.env, AXO_INSTALL_CLI: optOut, CLI_RESULT: result, CLI_CALLS: calls, PREFERENCE_CALLS: preferences } });
    assert.equal(run.status, 0, run.stderr);
    assert.equal(run.stdout, "done");
    assert.equal(existsSync(calls) ? 1 : 0, expectedCalls);
    if (expectedCalls) assert.equal(readFileSync(calls, "utf8"), "cli\ninstall\n--system\n");
    assert.equal(readFileSync(preferences, "utf8"), "write\ndev.leostera.axo\ncli.commandSetupOffered.v1\n-bool\ntrue\n");
    if (result !== "0" && expectedCalls) assert.match(run.stderr, /app is still installed; retry in Axo Settings/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
