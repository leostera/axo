import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
// Exercise the installed Pi loader, not a mock of its native-import cache.
import { loadExtensions } from "../node_modules/@earendil-works/pi-coding-agent/dist/core/extensions/loader.js";

const fixture = (version: string) => `export default function(pi) {
  pi.registerCommand("probe", { description: "${version}", handler: async () => {} });
}`;

async function loadedVersion(path: string) {
  const result = await loadExtensions([path], process.cwd());
  assert.deepEqual(result.errors, []);
  return result.extensions[0]?.commands.get("probe")?.description;
}

test("an existing .mjs CLI path migrates without restart and sees subsequent builds", async () => {
  const directory = await mkdtemp(join(tmpdir(), "axo-reload-"));
  try {
    const legacy = join(directory, "extension.mjs");
    await writeFile(legacy, fixture("original"));
    assert.equal(await loadedVersion(legacy), "original");
    const { installLegacyEntrypoint } = await import(new URL("../scripts/build-bridge.mjs", import.meta.url).href);
    await writeFile(join(directory, "extension.ts"), fixture("updated"));
    await installLegacyEntrypoint(directory);
    assert.equal(await loadedVersion(legacy), "updated");
    await writeFile(join(directory, "extension.ts"), fixture("next-build"));
    await installLegacyEntrypoint(directory);
    assert.equal(await loadedVersion(legacy), "next-build");
    assert.equal(await loadedVersion(join(directory, "extension.ts")), "next-build");
  } finally { await rm(directory, { recursive: true, force: true }); }
});
