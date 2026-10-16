import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { once } from "node:events";
import { resolve } from "node:path";
import { test } from "node:test";

const siteRoot = resolve(import.meta.dirname, "..");
const cf = resolve(siteRoot, "node_modules/.bin/cf");

async function freePort() {
  const server = createServer();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  await new Promise((resolveClose, rejectClose) =>
    server.close((error) => error ? rejectClose(error) : resolveClose()),
  );
  return address.port;
}

async function waitForWorker(url, child, output) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`cf dev exited early (${child.exitCode})\n${output()}`);
    try {
      const response = await fetch(`${url}/api/auth/me`);
      if (response.status === 200) return;
    } catch {
      // The Worker runtime is still starting.
    }
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 250));
  }
  throw new Error(`Timed out waiting for cf dev\n${output()}`);
}

async function stop(child) {
  if (child.exitCode !== null) return;
  try {
    process.kill(-child.pid, "SIGTERM");
  } catch {
    child.kill("SIGTERM");
  }
  await Promise.race([
    once(child, "exit"),
    new Promise((resolveDelay) => setTimeout(resolveDelay, 5_000)),
  ]);
}

test("single site serves landing/app assets and keeps account APIs fail-closed", {
  timeout: 45_000,
}, async (t) => {
  const port = await freePort();
  const url = `http://127.0.0.1:${port}`;
  let logs = "";
  const child = spawn(cf, ["dev"], {
    cwd: siteRoot,
    detached: true,
    env: { ...process.env, PORT: String(port) },
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.setEncoding("utf8").on("data", (chunk) => { logs += chunk; });
  child.stderr.setEncoding("utf8").on("data", (chunk) => { logs += chunk; });
  t.after(() => stop(child));

  await waitForWorker(url, child, () => logs);
  for (const path of ["/", "/app"]) {
    const response = await fetch(`${url}${path}`);
    assert.equal(response.status, 200, path);
    assert.match(await response.text(), /Axo — Your terminal, wherever you are/);
  }

  const session = await fetch(`${url}/api/auth/me`);
  assert.deepEqual(await session.json(), { authenticated: false });
  const start = await fetch(`${url}/api/auth/cloudflare/start`, { redirect: "manual" });
  assert.equal(start.status, 503);
  assert.equal(start.headers.get("Cache-Control"), "private, no-store");

  const accountHosts = await fetch(`${url}/api/v1/account/hosts`);
  assert.equal(accountHosts.status, 401);
  assert.deepEqual(await accountHosts.json(), { error: "Sign in required" });
  const legacyProductApi = await fetch(`${url}/api/v1/hosts`);
  assert.equal(legacyProductApi.status, 503);
  assert.match(await legacyProductApi.text(), /not enabled yet/);
});
