import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createServer } from "node:net";
import { once } from "node:events";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { test } from "node:test";

const siteRoot = resolve(import.meta.dirname, "..");
// `cf dev` runs `npx vite`; this runs the site's Vite itself, however node_modules is laid out
// (pnpm's, or Bazel's), so no npx goes looking for one.
const vite = resolve(dirname(createRequire(import.meta.url).resolve("vite/package.json")), "bin/vite.js");

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
    if (child.exitCode !== null) throw new Error(`vite exited early (${child.exitCode})\n${output()}`);
    try {
      // Any Worker answer means it is up; unconfigured sign-in answers 503 with JSON.
      const response = await fetch(`${url}/api/auth/me`);
      if (response.headers.get("Content-Type")?.startsWith("application/json")) return;
    } catch {
      // The Worker runtime is still starting.
    }
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 250));
  }
  throw new Error(`Timed out waiting for vite\n${output()}`);
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
  const child = spawn(process.execPath, [vite], {
    cwd: siteRoot,
    detached: true,
    // A developer's own .env must not decide what this test sees: sign-in starts unconfigured.
    env: { ...process.env, PORT: String(port), OAUTH_CLIENT_ID: "", OAUTH_CLIENT_SECRET: "", SESSION_SECRET: "" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.setEncoding("utf8").on("data", (chunk) => { logs += chunk; });
  child.stderr.setEncoding("utf8").on("data", (chunk) => { logs += chunk; });
  t.after(() => stop(child));

  await waitForWorker(url, child, () => logs);
  for (const path of ["/", "/app"]) {
    const response = await fetch(`${url}${path}`);
    assert.equal(response.status, 200, path);
    assert.match(await response.text(), /axo — your agentic experience olotl/);
  }

  // Without an OAuth client and a session secret, sign-in fails closed.
  const session = await fetch(`${url}/api/auth/me`);
  assert.equal(session.status, 503);
  assert.equal(session.headers.get("Cache-Control"), "private, no-store");
  assert.deepEqual(await session.json(), { error: "Sign-in is unavailable" });

  const accountHosts = await fetch(`${url}/api/v1/account/hosts`);
  assert.equal(accountHosts.status, 503);
  assert.deepEqual(await accountHosts.json(), { error: "Sign-in is unavailable" });
  // A connection's sign-in reaches the Worker, which refuses a browser that is not signed in.
  const connectionSignIn = await fetch(`${url}/api/v1/connections/oauth/start?flow=00000000-0000-4000-8000-000000000000`);
  assert.equal(connectionSignIn.status, 401);
  assert.doesNotMatch(await connectionSignIn.text(), /not enabled yet/);
  const legacyProductApi = await fetch(`${url}/api/v1/hosts`);
  assert.equal(legacyProductApi.status, 503);
  assert.match(await legacyProductApi.text(), /not enabled yet/);

  const sharePage = await fetch(`${url}/s/AAAAAAAAAAAAAAAAAAAAAA/shared-chat`);
  assert.equal(sharePage.status, 200);
  assert.match(await sharePage.text(), /axo — your agentic experience olotl/);

  const missingShare = await fetch(`${url}/api/public-sessions/AAAAAAAAAAAAAAAAAAAAAA`);
  assert.equal(missingShare.status, 404);
  const invalidShare = await fetch(`${url}/api/public-sessions/not-a-share-id`);
  assert.equal(invalidShare.status, 404);

  // `curl … /install | sh` gets a script that downloads this origin's Mac app.
  const install = await fetch(`${url}/install`);
  assert.equal(install.status, 200);
  assert.match(install.headers.get("Content-Type"), /^text\/x-shellscript/);
  const script = await install.text();
  assert.match(script, /^#!\/bin\/sh\n/);
  assert.ok(script.includes(`AXO_ORIGIN='${url}'`));
  assert.ok(script.includes("AXO_PAIRING_CODE=''"));
  assert.equal(spawnSync("sh", ["-n"], { input: script }).status, 0, "the install script parses");

  const pairing = await fetch(`${url}/install?code=abcd-2345`);
  assert.equal(pairing.status, 200);
  assert.ok((await pairing.text()).includes("AXO_PAIRING_CODE='ABCD-2345'"));
  // Anything else is refused, still as a script, so `| sh` prints why.
  for (const code of ["ABCD-EFGI", "ABCD-EFG", "'; rm -rf ~; '"]) {
    const refused = await fetch(`${url}/install?code=${encodeURIComponent(code)}`);
    assert.equal(refused.status, 400, code);
    assert.match(await refused.text(), /should look like ABCD-EFGH/);
  }

  // The local bucket has no build uploaded.
  for (const path of ["/cdn/Axo.app", "/cdn/Axo.app.zip"]) {
    const app = await fetch(`${url}${path}`);
    assert.equal(app.status, 404, path);
    await app.body?.cancel();
  }
});
