#!/usr/bin/env bun
/** Product adapter for the separately installed/pinned portable macOS signing SDK. */
import { existsSync } from "node:fs";
import { readFile, mkdir } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import { spawnSync } from "node:child_process";

type Mode = "local" | "release" | "resume" | "verify";
type Result = { code: number; stdout: string; stderr: string };
type Runner = (args: string[]) => Promise<Result>;
type Policy = { appName: string; bundleIdentifier: string; mainExecutable: string; executables: string[]; bundles: string[]; entitlements: Record<string, string> };
type Workflow = { app: string; dmg: string; verify(source: string): Promise<void>; signLocal(source: string): Promise<void>; release(source: string, resume?: boolean): Promise<void> };
interface SigningSDK {
  MacOSSigning: new (run: string, config: unknown, policy: Policy, runner: Runner, preflight: () => void) => Workflow;
  loadSigningConfig(): Promise<unknown>;
  parseSigningPolicy(value: unknown): Policy;
  runCommand: Runner;
}

function requireValue(condition: unknown, message: string): asserts condition {
  if (!condition) throw Error(message);
}

export function parseOptions(argv: string[]) {
  const { values } = parseArgs({ args: argv, strict: true, options: {
    help: { type: "boolean" }, mode: { type: "string" }, app: { type: "string" },
    "run-dir": { type: "string" }, "tool-root": { type: "string" }, source: { type: "string" },
    repository: { type: "string" }, "approval-file": { type: "string" },
  } });
  if (values.help) return { help: true as const };
  requireValue(values.mode && ["local", "release", "resume", "verify"].includes(values.mode), "Choose local, release, resume or verify");
  requireValue(values.app && values.app.endsWith(".app") && values["run-dir"] && values["tool-root"], "Provide --app, --run-dir and --tool-root");
  requireValue(values.source && /^[a-f0-9]{40}$/.test(values.source), "Provide a full --source SHA");
  if (values.mode === "release" || values.mode === "resume") requireValue(values["approval-file"], "Apple submissions require scoped approval");
  return { help: false as const, mode: values.mode as Mode, app: resolve(values.app), run: resolve(values["run-dir"]),
    toolRoot: resolve(values["tool-root"]), source: values.source, approval: values["approval-file"],
    repository: resolve(values.repository ?? join(dirname(fileURLToPath(import.meta.url)), "../..")) };
}

function outsideGit(path: string): void {
  let parent = path;
  while (!existsSync(parent)) parent = dirname(parent);
  const result = spawnSync("git", ["-C", parent, "rev-parse", "--is-inside-work-tree"], { encoding: "utf8" });
  requireValue(result.status !== 0 || result.stdout.trim() !== "true", "Keep signing runs and receipts outside Git");
}

export async function main(argv = process.argv.slice(2)): Promise<void> {
  const options = parseOptions(argv);
  if (options.help) {
    console.log("bun tools/apple/sign_macos.ts --mode local|release|resume|verify --app APP --run-dir PRIVATE_DIR --tool-root PINNED_SDK_PACKAGE --source SHA [--repository PRIMARY_MAIN] [--approval-file PRIVATE_RECEIPT]");
    return;
  }
  requireValue(process.platform === "darwin", "Native signing requires macOS");
  outsideGit(options.run);
  const sdk = await import(pathToFileURL(join(options.toolRoot, "src/index.ts")).href) as SigningSDK;
  const provenance = await import(pathToFileURL(join(options.toolRoot, "src/provenance.ts")).href) as { releasePreflight(repo: string, source: string): void };
  requireValue(typeof sdk.MacOSSigning === "function" && typeof sdk.runCommand === "function"
    && typeof sdk.loadSigningConfig === "function" && typeof sdk.parseSigningPolicy === "function"
    && typeof provenance.releasePreflight === "function", "Unsupported portable signing SDK");
  const policyFile = join(options.repository, "bazel/apple/macos-signing-policy.json");
  const policy = sdk.parseSigningPolicy(JSON.parse(await readFile(policyFile, "utf8")));
  for (const [target, path] of Object.entries(policy.entitlements)) policy.entitlements[target] = resolve(dirname(policyFile), path);
  const runner: Runner = args => {
    // Preserve launchd's axod identity and the custom identifiers of bare CLI/inference helpers.
    if (args[0] === "codesign" && args.includes("--force")) args = [...args.slice(0, -1), "--preserve-metadata=identifier", args.at(-1)!];
    return sdk.runCommand(args);
  };
  const preflight = () => provenance.releasePreflight(options.repository, options.source);
  const workflow = new sdk.MacOSSigning(options.run, await sdk.loadSigningConfig(), policy, runner, preflight);
  if (options.mode === "release" || options.mode === "resume") {
    const receipt = JSON.parse(await readFile(resolve(options.approval!), "utf8"));
    requireValue(receipt.action === "accept", "Apple upload not approved");
    preflight();
  }
  if (options.mode === "local" || options.mode === "release") {
    await mkdir(options.run, { mode: 0o700 }); // Existing runs require reconciliation, never overwrite.
    requireValue((await sdk.runCommand(["ditto", options.app, workflow.app])).code === 0, "Cannot stage app; inspect retained run before retrying");
    // Bazel tree artifacts are read-only. Make only this fresh owned copy writable.
    requireValue((await sdk.runCommand(["chmod", "-R", "u+w", workflow.app])).code === 0, "Cannot make staged copy writable");
  }
  if (options.mode === "verify") await workflow.verify(options.source);
  else if (options.mode === "local") await workflow.signLocal(options.source);
  else await workflow.release(options.source, options.mode === "resume");

  async function signatureField(file: string, field: string): Promise<string> {
    const result = await sdk.runCommand(["codesign", "-dvvv", file]);
    requireValue(result.code === 0, "Cannot inspect signature metadata");
    const value = (result.stdout + result.stderr).split("\n").find(line => line.startsWith(field + "="));
    requireValue(value, "Missing signature field: " + field);
    return value;
  }
  for (const target of [...policy.executables, ...policy.bundles, "."]) {
    const path = (root: string) => target === "." ? root : join(root, target);
    requireValue(await signatureField(path(options.app), "Identifier") === await signatureField(path(workflow.app), "Identifier"), "Signing identifier changed: " + target);
  }
  requireValue(await signatureField(options.app, "CDHash") === await signatureField(workflow.app, "CDHash"), "Signed code differs from exact Bazel build");
  console.log(options.mode + ": preserved identifiers and matching Bazel code; " + workflow.dmg);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error instanceof Error ? error.message : "Signing failed"); process.exitCode = 1; });
}
