import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { constants, createReadStream } from "node:fs";
import { access, copyFile, mkdir, mkdtemp, rm, stat, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { test } from "node:test";
import { aiResults } from "@axo/protocol";
import { harness, signIn } from "./harness";
import { listHosts, localCall, terminate, waitFor } from "./axod-support";

/** Opt-in: real HF inspection/install and task adapters through codemode -> relay -> axod.
 * Isolated Worker/account/home; persistent checksummed cache; no production deployment.
 */
test("codemode inspects runtime support and executes multiple real HF selections without a model allowlist", { timeout: 600_000 }, async () => {
  const binary = process.env.AXO_TEST_AI_DAEMON ?? process.env.AXOD_BINARY;
  const helper = process.env.AXO_TEST_AI_HELPER;
  assert.ok(binary && helper, "set AXOD_BINARY and AXO_TEST_AI_HELPER");
  const mlxHelper = process.env.AXO_TEST_AI_MLX_HELPER;
  const mlxMetal = process.env.AXO_TEST_AI_MLX_METALLIB;
  assert.equal(Boolean(mlxHelper), Boolean(mlxMetal), "provide both native MLX worker and Metal resource");
  const cache = process.env.AXO_TEST_AI_CACHE ?? "/tmp/axo-general-ai-models";
  const seedFolders = JSON.parse(process.env.AXO_TEST_AI_SEED_DIRS ?? "[]") as string[];
  const cases = JSON.parse(process.env.AXO_TEST_AI_MODELS ?? JSON.stringify([
    { model: "hf:ggml-org/gemma-3-270m-it-GGUF", input: "Write the word hello.", maxTokens: 16 },
    { model: "hf:ggml-org/Qwen3-0.6B-GGUF:Q4_0", input: "Write the word hello. /no_think", maxTokens: 32 },
  ])) as Array<Record<string, unknown> & { model: string }>;
  if (mlxHelper) cases.push(
    { model: "hf:mlx-community/Qwen3-0.6B-4bit@73e3e38d981303bc594367cd910ea6eb48349da8", input: "What is 2 + 2? Answer briefly.", maxTokens: 32 },
    { model: "hf:mlx-community/Qwen2.5-0.5B-Instruct-4bit@a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3", backend: "mlx", input: "Write a short greeting.", maxTokens: 24 },
  );
  if (process.env.AXO_TEST_AI_EMBEDDING) cases.push({ model: process.env.AXO_TEST_AI_EMBEDDING, task: "embed", input: "A small local embedding test." });
  if (process.env.AXO_TEST_AI_CLASSIFIER) cases.push({ model: process.env.AXO_TEST_AI_CLASSIFIER, task: "classify", input: { state: { task: "Inspect this tiny test image" }, questions: {
    image: { type: "noul", instructions: "Is an image present?" },
    category: { type: "choice", instructions: "Is the image mostly dark or light?", criteria: { dark: "Mostly dark pixels", light: "Mostly light pixels" } },
    brightness: { type: "score", instructions: "How bright is the image?", criteria: ["Dark", "Light"] },
  } } });

  const root = await mkdtemp(join(tmpdir(), "axo-ai-codemode-"));
  const api = await harness();
  let daemon: ChildProcess | undefined;
  try {
    const bin = join(root, "bin");
    const models = join(root, "Library/Application Support/Axo/models");
    await mkdir(bin, { recursive: true });
    await mkdir(cache, { recursive: true });
    await mkdir(join(root, "Library/Application Support/Axo"), { recursive: true });
    await symlink(cache, models);
    await copyFile(resolve(binary), join(bin, "axod"));
    await copyFile(helper, join(bin, "axod-infer"));
    if (mlxHelper && mlxMetal) {
      await copyFile(resolve(mlxHelper), join(bin, "axod-infer-mlx"), constants.COPYFILE_FICLONE);
      await copyFile(resolve(mlxMetal), join(bin, "mlx.metallib"), constants.COPYFILE_FICLONE);
    }
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
    const run = async (code: string) => await localCall(socket, "axo.apps.run", { sessionId, code }, 260_000) as { result: unknown; logs: string[] };
    const capabilities = aiResults.capabilities.parse((await run("async () => codemode.ai.capabilities({})")).result);
    assert.ok(capabilities.runtime.recognizedArchitectures.includes("clef"));
    if (mlxHelper) {
      assert.ok(capabilities.backends.includes("mlx"));
      assert.equal(capabilities.runtimes?.find(runtime => runtime.name === "mlx")?.available, true);
    }
    const mlx = aiResults.info.parse((await run('async () => codemode.ai.info({model:"hf:mlx-community/clef-omni-4bit"})')).result);
    assert.equal(mlx.info.compatibility.status, "unsupported");
    assert.match(mlx.info.compatibility.reasons.join(" "), /MLX/);
    await assert.rejects(run(`async () => codemode.ai.run({model:"hf:mlx-community/clef-omni-4bit",task:"classify",input:{state:"test",questions:{q:{type:"noul",instructions:"test?"}}}})`), /MLX/);

    for (const args of cases) {
      const selection = { model: args.model, ...(args.backend ? { backend: args.backend } : {}), ...(args.file ? { file: args.file } : {}), ...(args.projector ? { projector: args.projector } : {}) };
      const inspection = aiResults.info.parse((await run(`async () => codemode.ai.info(${JSON.stringify(selection)})`)).result);
      assert.equal(inspection.info.compatibility.status, "candidate", JSON.stringify(inspection));
      assert.ok(inspection.info.resolved);
      const resolved = inspection.info.resolved;
      // Cache identity preserves Rust selection field order (including the new optional backend).
      const selected = resolved.selection;
      const key = createHash("sha256").update(JSON.stringify({ backend: selected.backend, model: selected.model, file: selected.file, projector: selected.projector })).digest("hex");
      const directory = join(cache, "hf", key, resolved.revision);
      // Optional APFS copy-on-write seeds avoid downloading weights already verified on this Mac.
      // Validate each seed against current HF metadata, not a model-name-specific production pin.
      for (const file of resolved.files) {
        const target = join(directory, file.path);
        try { await access(target); continue; } catch { /* not cached */ }
        for (const folder of seedFolders) {
          const seed = join(folder, basename(file.path));
          try { if ((await stat(seed)).size !== file.bytes) continue; } catch { continue; }
          const sha = createHash(file.sha256 ? "sha256" : "sha1");
          if (!file.sha256) sha.update(`blob ${file.bytes}\0`);
          for await (const chunk of createReadStream(seed)) sha.update(chunk);
          if (sha.digest("hex") !== (file.sha256 ?? file.gitBlob)) continue;
          await mkdir(join(target, ".."), { recursive: true });
          await copyFile(seed, target, constants.COPYFILE_FICLONE);
          break;
        }
      }
      const code = args.task === "classify" ? `async () => {
        const image = await codemode.assets.save({name:"fixture.png",mimeType:"image/png",base64:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="});
        const args = ${JSON.stringify(args)}; args.input.images = [image.attachment];
        return codemode.ai.run(args);
      }` : `async () => codemode.ai.run(${JSON.stringify(args)})`;
      const result = aiResults.run.parse((await run(code)).result);
      assert.equal(result.model, args.model);
      if (result.task === "generate") assert.ok(result.text.trim());
      if (result.task === "embed") assert.ok(result.embedding.length > 0);
      if (result.task === "classify") assert.ok("image" in result.answers);
      console.log(JSON.stringify({ via: "codemode.ai.run", model: result.model, backend: result.source.backend ?? "llama.cpp", task: result.task, revision: result.source.revision,
        ...(result.task === "generate" ? { text: result.text } : result.task === "embed" ? { dimensions: result.embedding.length } : { answers: result.answers }) }));
      // Leave residency intact: the next case must retire a different model/backend safely.
    }
    // Switch back after the native cases too, then explicitly unload the exact selections.
    aiResults.run.parse((await run(`async () => codemode.ai.run(${JSON.stringify(cases[0])})`)).result);
    for (const args of cases) {
      const selection = { model: args.model, ...(args.backend ? { backend: args.backend } : {}) };
      aiResults.unload.parse((await run(`async () => codemode.ai.unload(${JSON.stringify(selection)})`)).result);
    }
    const listed = aiResults.list.parse((await run("async () => codemode.ai.list({})")).result);
    assert.ok(listed.models.length >= cases.length);
    assert.ok(listed.models.every(model => model.installed && model.status === "stopped"));
  } finally {
    if (daemon) await terminate(daemon);
    await api.close();
    await rm(root, { recursive: true, force: true });
  }
});
