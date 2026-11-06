import assert from "node:assert/strict";
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { sealInput } from "@axo/app";
import type { Elicitation } from "@axo/protocol";
import { harness, signIn } from "./harness";
import { accountApi, listHosts, localCall, terminate, waitFor, trustedDevice } from "./axod-support";

/**
 * RFD0029's side channel for input, live on this Mac: a script asks a real axod to sign in to a
 * page in Safari; the person's phone (a test client) gets axod's own reading of the form, seals a
 * password to the Mac's key, and axod fills and submits it. The agent's script gets a receipt,
 * and a read of the window shows the filled email hidden.
 *
 * It drives Safari on the screen, so it runs only with AXO_LIVE_COMPUTER=1, from a terminal whose
 * app has Accessibility (Axo's own panes do).
 */
test("a password typed on the phone reaches a Safari form on the Mac sealed, and the agent sees only a receipt", { skip: !process.env.AXO_LIVE_COMPUTER }, async () => {
  const binary = process.env.AXOD_BINARY;
  assert.ok(binary, "set AXOD_BINARY to the Bazel-built axod binary");
  const axodBinary = resolve(process.cwd(), binary);
  const api = await harness();
  const root = await mkdtemp(join(tmpdir(), "axo-input-"));
  const serverDirectory = join(root, "server");
  const socketPath = join(root, "axod.sock");
  await mkdir(serverDirectory, { recursive: true, mode: 0o700 });
  const device = await trustedDevice(serverDirectory);
  const sessionId = crypto.randomUUID();

  const submitted: URLSearchParams[] = [];
  const page = createServer((request, response) => {
    const url = new URL(request.url ?? "/", "http://localhost");
    if (url.pathname === "/done") submitted.push(url.searchParams);
    response.setHeader("content-type", "text/html");
    response.end(url.pathname === "/done"
      ? "<title>Signed in</title><h1>Signed in</h1>"
      : `<title>Axo test sign-in</title><form action="/done"><label>Email <input name="email" type="email" autocomplete="username"></label>
         <label>Password <input name="pw" type="password" autocomplete="current-password"></label><button type="submit">Sign in</button></form>`);
  });
  await new Promise<void>((done) => page.listen(0, "127.0.0.1", done));
  const port = (page.address() as { port: number }).port;
  const origin = `http://localhost:${port}`;

  let daemon: ChildProcess | undefined;
  try {
    daemon = spawn(axodBinary, ["--server-dir", serverDirectory, "--socket", socketPath, "--relay-url", api.url, "--host-credentials", "files"],
      { stdio: "ignore", env: {
        ...process.env, HOME: root, SHELL: "/bin/sh",
        AXO_PI_EXECUTABLE: join(dirname(fileURLToPath(import.meta.url)), "fake-pi.mjs"), AXO_FAKE_PI_STARTUP_MS: "200",
        AXO_PI_EXTENSION_PATH: fileURLToPath(new URL("../../../crates/axo-server/testdata/pi-extension.js", import.meta.url)),
      } });
    await waitFor("the axod socket", 15_000, async () => (existsSync(socketPath) ? true : undefined), daemon);
    const account = await signIn(api);
    const pairing = await fetch(new URL("api/v1/account/host-pairings", api.url), { method: "POST", headers: account.headers });
    await localCall(socketPath, "axo.relay.link", { code: ((await pairing.json()) as { code: string }).code });
    const host = await waitFor("the Mac coming online", 20_000, async () =>
      (await listHosts(api.url, account)).find((candidate) => candidate.status === "online"), daemon);

    execFileSync("open", ["-g", "-a", "Safari", `${origin}/`]);
    const run = async (code: string) =>
      ((await localCall(socketPath, "axo.connections.execute", { sessionId, code })) as { result: any }).result;
    const window = await waitFor("the page in Safari", 15_000, async () => {
      const listed = await run(`async () => codemode.computer.run({ host: "self", tool: "list_windows", args: {} })`);
      return listed.structuredContent?.windows?.find((w: { app_name: string; title: string }) => w.app_name === "Safari" && w.title === "Axo test sign-in");
    });

    const asked: Elicitation[] = [];
    const phone = await accountApi(api.url, account).connect(`phone-${crypto.randomUUID().slice(0, 8)}`, {
      elicitationRequested: (_hostId, elicitation) => asked.push(elicitation),
    });
    try {
      // A filled value is hidden from every later read of the window.
      const filling = run(`async () => codemode.computer.run({ host: "self", tool: "request_input", args: { pid: ${window.pid}, window_id: ${window.window_id}, fields: [{ kind: "email", label: "Email" }] } })`);
      const first = await waitFor("the first form", 20_000, async () => asked[0], daemon);
      await device.answer(phone, host.hostId, first.id, "accept", await sealInput(first.input!.key, first.id, first.input!.origin, { f0: "leo@example.com" }));
      assert.match((await filling).content[0].text, /^Filled Email in Safari/u);
      const read = await run(`async () => codemode.computer.run({ host: "self", tool: "get_window_state", args: { pid: ${window.pid}, window_id: ${window.window_id} } })`);
      const text = JSON.stringify(read);
      assert.ok(!text.includes("leo@example.com"), "the read shows no filled value");
      assert.match(text, /•••• \(filled by you\)/u);
      asked.length = 0;

      // The local `computer` tool asks the same way: axod mcp hands the request to axod, and the
      // agent's own Session gets the question.
      const { sessions } = (await localCall(socketPath, "axo.session.list")) as { sessions: Array<{ id: string }> };
      const ownSession = sessions[0]!.id;
      const mcp = spawn(axodBinary, ["mcp"], { env: { ...process.env, AXO_SOCKET: socketPath, AXO_SESSION_ID: ownSession } });
      const lines: string[] = [];
      let buffered = "";
      mcp.stdout!.on("data", (chunk: Buffer) => {
        buffered += chunk.toString();
        const parts = buffered.split("\n");
        buffered = parts.pop()!;
        lines.push(...parts.filter(Boolean));
      });
      const send = (message: unknown) => mcp.stdin!.write(`${JSON.stringify(message)}\n`);
      send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } } });
      send({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "computer", arguments: { tool: "request_input", args: { pid: window.pid, window_id: window.window_id, fields: [{ kind: "password" }] } } } });
      let errors = "";
      mcp.stderr!.on("data", (chunk: Buffer) => { errors += chunk.toString(); });
      const local = await waitFor("the local form", 20_000, async () => asked[0], daemon).catch((error) => {
        throw new Error(`${error.message}; axod mcp said: ${errors} ${lines.join("\n")}`);
      });
      assert.equal(local.sessionId, ownSession);
      assert.equal(local.input?.fields[0]?.label, "Password");
      await device.answer(phone, host.hostId, local.id, "decline");
      const answered = await waitFor("axod mcp's answer", 10_000, async () => lines.map((line) => JSON.parse(line)).find((message) => message.id === 2));
      assert.equal(answered.result.isError, true);
      assert.match(answered.result.content[0].text, /the person declined/u);
      mcp.kill();
      asked.length = 0;

      const signingIn = run(`async () => {
        await codemode.computer.run({ host: "self", tool: "get_window_state", args: { pid: ${window.pid}, window_id: ${window.window_id} } });
        return codemode.computer.run({ host: "self", tool: "request_input", args: { pid: ${window.pid}, window_id: ${window.window_id},
          fields: [{ kind: "email" }, { kind: "password" }], submit: "Sign in" } });
      }`);
      const question = await waitFor("the form on the phone", 20_000, async () => asked[0], daemon);
      // What the phone shows is axod's reading of the window, and the key to seal to.
      assert.equal(question.kind, "input");
      assert.equal(question.askedBy, "computerUse");
      assert.deepEqual({ ...question.input, key: typeof question.input?.key }, {
        app: "Safari", window: "Axo test sign-in", origin,
        fields: [{ id: "f0", label: "Email", kind: "email" }, { id: "f1", label: "Password", kind: "password" }],
        submit: "Sign in", key: "string",
      });
      const sealed = await sealInput(question.input!.key, question.id, question.input!.origin, { f0: "leo@example.com", f1: "correct horse 7" });
      await device.answer(phone, host.hostId, question.id, "accept", sealed);
      const receipt = await signingIn;
      assert.notEqual(receipt.isError, true, JSON.stringify(receipt));
      assert.match(receipt.content[0].text, /^Filled Email and Password in Safari — http:\/\/localhost:\d+ and pressed “Sign in”\. The values are not shown to you/u);
      assert.ok(!JSON.stringify(receipt).includes("correct horse"));
      await waitFor("the form submitted", 10_000, async () => submitted[0]);
      assert.deepEqual([submitted[0]!.get("email"), submitted[0]!.get("pw")], ["leo@example.com", "correct horse 7"]);
    } finally {
      phone.close();
    }
  } finally {
    if (daemon) await terminate(daemon);
    page.close();
    await api.close();
    await rm(root, { recursive: true, force: true });
  }
});
