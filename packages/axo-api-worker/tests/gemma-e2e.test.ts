import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { copyFile, mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { AI_MODEL, aiResults, aiSourceSchema } from "@axo/protocol";
import { harness, signIn } from "./harness";
import { listHosts, localCall, terminate, waitFor } from "./axod-support";

/** Opt-in real model test: actual codemode Worker -> authenticated relay -> axod -> llama.cpp.
 * Uses an already downloaded, checksum-verified model and an isolated daemon/account/home.
 * It does not deploy the Worker, touch the running Axo, or download weights.
 */
test("codemode.ai.run loads real Gemma, generates and unloads through a paired Mac", async () => {
  const binary = process.env.AXOD_BINARY;
  const helper = process.env.AXO_TEST_GEMMA_HELPER;
  const weights = process.env.AXO_TEST_GEMMA_MODEL;
  assert.ok(binary && helper && weights, "set AXOD_BINARY, AXO_TEST_GEMMA_HELPER and AXO_TEST_GEMMA_MODEL");
  const sha = createHash("sha256");
  for await (const chunk of createReadStream(weights)) sha.update(chunk);
  assert.equal(sha.digest("hex"), aiSourceSchema.shape.sha256.value, "the smoke test must use the reviewed weights");

  const root = await mkdtemp(join(tmpdir(), "axo-gemma-codemode-"));
  const api = await harness();
  let daemon: ChildProcess | undefined;
  try {
    const bin = join(root, "bin");
    const models = join(root, "Library/Application Support/Axo/models/gemma-3-270m-it", aiSourceSchema.shape.revision.value);
    await mkdir(bin, { recursive: true });
    await mkdir(models, { recursive: true });
    await copyFile(resolve(binary), join(bin, "axod"));
    await copyFile(helper, join(bin, "axod-infer"));
    await copyFile(weights, join(models, aiSourceSchema.shape.file.value));
    const socket = join(root, "axod.sock");
    daemon = spawn(join(bin, "axod"), ["--server-dir", join(root, "server"), "--socket", socket, "--relay-url", api.url, "--host-credentials", "files"], {
      stdio: "ignore", env: { ...process.env, HOME: root, SHELL: "/bin/sh" },
    });
    await waitFor("the isolated axod socket", 15_000, async () => {
      try { await localCall(socket, "axo.apps.list", { sessionId: crypto.randomUUID() }); }
      catch (error) { if (String(error).includes("not connected")) return true; }
      return undefined;
    }, daemon);
    const account = await signIn(api);
    const pairing = await fetch(new URL("api/v1/account/host-pairings", api.url), { method: "POST", headers: account.headers });
    const { code } = await pairing.json() as { code: string };
    await localCall(socket, "axo.relay.link", { code });
    await waitFor("the isolated Mac to pair", 20_000, async () => (await listHosts(api.url, account)).find(host => host.status === "online"), daemon);
    const sessionId = crypto.randomUUID();
    const run = async (code: string) => await localCall(socket, "axo.apps.run", { sessionId, code }) as { result: unknown; logs: string[] };
    const prompt = "What is 2 + 2? Reply with only the answer.";
    const called = await run(`async () => codemode.ai.run({ model: ${JSON.stringify(AI_MODEL)}, prompt: ${JSON.stringify(prompt)}, maxTokens: 32 })`);
    const result = aiResults.run.parse(called.result);
    assert.ok(result.text.trim(), "Gemma must generate non-empty text");
    console.log(JSON.stringify({ via: "codemode.ai.run", prompt, result }));
    // This verifies the integration, not the accuracy of a 270M-parameter model.
    const log = await localCall(socket, "axo.apps.log", { sessionId });
    assert.doesNotMatch(JSON.stringify(log), /What is 2 \+ 2/);
    aiResults.unload.parse((await run(`async () => codemode.ai.unload({ model: ${JSON.stringify(AI_MODEL)} })`)).result);
    const listed = aiResults.list.parse((await run("async () => codemode.ai.list({})")).result);
    assert.equal(listed.models[0]?.status, "stopped");
    assert.equal(listed.models[0]?.installed, true);
  } finally {
    if (daemon) await terminate(daemon);
    await api.close();
    await rm(root, { recursive: true, force: true });
  }
});
