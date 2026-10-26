// A whole Axo stack on this machine for end-to-end tests of the clients: a real Worker (the
// harness's miniflare, with a simulated Cloudflare sign-in), a real axod linked to an account, a
// Workspace on it, and a stand-in Pi that records what is typed into it.
//
// Prints one JSON line when ready, `{ url, token, piLog, hostId }`, and runs until stdin closes.
//   AXOD_BINARY=../../target/release/axod npx tsx scripts/e2e-stack.ts
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { harness, signInNative } from "../tests/harness";
import { accountApi, localCall, terminate, waitFor } from "../tests/axod-support";

const binary = process.env.AXOD_BINARY;
assert.ok(binary, "set AXOD_BINARY to the axod binary");
const axodBinary = resolve(process.cwd(), binary);
assert.ok(existsSync(axodBinary), `no axod at ${axodBinary}`);

const api = await harness();
const root = await mkdtemp(join(tmpdir(), "axo-stack-"));
const serverDirectory = join(root, "server");
const socketPath = join(root, "axod.sock");
const piLog = join(root, "pi-typed.log");
// A Pi that, like Pi, only takes a prompt once it has started and bound its bridge.
const pi = join(dirname(fileURLToPath(import.meta.url)), "../tests/fake-pi.mjs");
await mkdir(serverDirectory, { recursive: true, mode: 0o700 });

const daemon = spawn(axodBinary, [
  "--server-dir", serverDirectory, "--socket", socketPath,
  "--relay-url", api.url, "--host-credentials", "files",
], { stdio: "ignore", env: { ...process.env, HOME: root, AXO_PI_EXECUTABLE: pi, AXO_FAKE_PI_LOG: piLog } });

async function shutdown() {
  await terminate(daemon);
  await api.close();
  await rm(root, { recursive: true, force: true });
}

try {
  await waitFor("the axod socket", 15_000, async () => (existsSync(socketPath) ? true : undefined), daemon);
  const phone = await signInNative(api);
  const pairing = await fetch(new URL("api/v1/account/host-pairings", api.url), { method: "POST", headers: phone.headers });
  const { code } = (await pairing.json()) as { code: string };
  await localCall(socketPath, "axo.relay.link", { code });
  const host = await waitFor("the Mac online", 20_000, async () =>
    (await accountApi(api.url, phone).listHosts()).find((candidate) => candidate.status === "online"), daemon);

  const project = join(root, "project");
  await mkdir(project);
  await localCall(socketPath, "axo.workspace.create", { name: "Project", directoryPath: project });

  console.log(JSON.stringify({ url: api.url, token: phone.token, piLog, hostId: host.hostId }));
  process.stdin.resume();
  await new Promise<void>((done) => process.stdin.on("end", () => done()));
} finally {
  await shutdown();
}
