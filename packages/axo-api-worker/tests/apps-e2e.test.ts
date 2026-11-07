import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { harness, signIn } from "./harness";
import type { Elicitation } from "@axo/protocol";
import { accountApi, listHosts, localCall, terminate, waitFor, trustedDevice } from "./axod-support";

/**
 * RFD0016 end to end, with nothing faked but the sign-in provider: a Session's script, sent to a
 * real axod's local socket, runs in the account's Dynamic Worker and runs `bash` back on that
 * same Mac; then drives that Mac's computer use (RFD0028), whose gate asks the person in the
 * calling Session and runs nothing on a No.
 *
 *   Session ──axod.sock──▶ axod ──WSS──▶ HostDO ──RPC──▶ AxoAccountManager ──▶ script Worker
 *                           ▲                                   │
 *                           └──── axo.apps.bash ◀── HostDO.callHost
 */
test("a Session's script runs bash and computer use on a Mac through the account, and the calls are logged", async () => {
  const binary = process.env.AXOD_BINARY;
  assert.ok(binary, "set AXOD_BINARY to the Bazel-built axod binary");
  const axodBinary = resolve(process.cwd(), binary);
  assert.ok(existsSync(axodBinary), `axod binary must exist at ${axodBinary}`);

  const api = await harness();
  const root = await mkdtemp(join(tmpdir(), "axo-apps-"));
  const serverDirectory = join(root, "server");
  const socketPath = join(root, "axod.sock");
  await mkdir(serverDirectory, { recursive: true, mode: 0o700 });
  const device = await trustedDevice(serverDirectory);
  const sessionId = crypto.randomUUID();

  let daemon: ChildProcess | undefined;
  try {
    daemon = spawn(axodBinary, [
      "--server-dir", serverDirectory,
      "--socket", socketPath,
      "--relay-url", api.url,
      "--host-credentials", "files",
    ], { stdio: "ignore", env: { ...process.env, HOME: root, SHELL: "/bin/sh" } });
    await waitFor("the axod socket", 15_000, async () => (existsSync(socketPath) ? true : undefined), daemon);

    // Before it is linked, a Mac has no account to reach.
    await assert.rejects(localCall(socketPath, "axo.apps.list", { sessionId }), /not connected to its Axo account/);

    const account = await signIn(api);
    const pairing = await fetch(new URL("api/v1/account/host-pairings", api.url), { method: "POST", headers: account.headers });
    const { code } = (await pairing.json()) as { code: string };
    await localCall(socketPath, "axo.relay.link", { code });
    const host = await waitFor("the Mac coming online", 20_000, async () =>
      (await listHosts(api.url, account)).find((candidate) => candidate.status === "online"), daemon);

    const listed = (await localCall(socketPath, "axo.apps.list", { sessionId })) as {
      apps: Array<{ kind: string; name: string; hostId: string; state: string }>;
    };
    // The Mac, beside the apps every account lists.
    const apps = listed.apps.filter((c) => c.kind === "host");
    assert.equal(apps.length, 1);
    assert.deepEqual({ ...apps[0], name: typeof apps[0]!.name }, { kind: "host", name: "string", hostId: host.hostId, state: "online" });
    const service = apps[0]!.name;

    // A command's output larger than one relay frame comes back whole, as fragments.
    const executed = (await localCall(socketPath, "axo.apps.run", {
      sessionId,
      code: `async () => {
        const small = await codemode.bash.run({ host: ${JSON.stringify(service)}, command: "echo hello-$((40 + 2)); pwd", cwd: ${JSON.stringify(root)} });
        const large = await codemode.bash.run({ host: "self", command: "head -c 300000 /dev/zero | tr '\\\\0' a" });
        console.log("ran", small.exitCode, large.exitCode);
        return { small: small.stdout, large: large.stdout.length, truncated: large.stdoutTruncated };
      }`,
    })) as { result: { small: string; large: number; truncated: boolean }; logs: string[] };
    assert.equal(executed.result.small.split("\n")[0], "hello-42");
    assert.match(executed.result.small, /axo-apps-/);
    assert.deepEqual([executed.result.large, executed.result.truncated], [300_000, false]);
    assert.deepEqual(executed.logs, ["ran 0 0"]);

    const { records } = (await localCall(socketPath, "axo.apps.log", { sessionId })) as {
      records: Array<{ sessionId: string; hostId: string; targetHostId: string; tool: string; outcome: string; input: { command: string } }>;
    };
    assert.deepEqual(records.map((r) => [r.sessionId, r.hostId, r.targetHostId, r.tool, r.outcome]), [
      [sessionId, host.hostId, host.hostId, "run", "ok"],
      [sessionId, host.hostId, host.hostId, "run", "ok"],
    ]);
    assert.deepEqual(records.map((r) => r.input.command).sort(), ["echo hello-$((40 + 2)); pwd", "head -c 300000 /dev/zero | tr '\\0' a"]);

    // The Mac lists itself, and says whether it can do computer use now.
    const hosts = (await localCall(socketPath, "axo.apps.run", { sessionId, code: `async () => codemode.hosts.list()` })) as {
      result: Array<{ name: string; online: boolean; self: boolean; computerUse: { available: boolean } | null }>;
    };
    assert.deepEqual(hosts.result.map((h) => [h.name, h.online, h.self, typeof h.computerUse?.available]), [[service, true, true, "boolean"]]);

    // computer.run with confirm asks the person in the calling Session, as Axo; a No runs nothing.
    const asked: Elicitation[] = [];
    const phone = await accountApi(api.url, account).connect(`phone-${crypto.randomUUID().slice(0, 8)}`, {
      elicitationRequested: (_hostId, elicitation) => asked.push(elicitation),
    });
    try {
      const pay = localCall(socketPath, "axo.apps.run", {
        sessionId,
        code: `async () => codemode.computer.run({ host: "self", tool: "click", args: { role: "AXButton", name: "Pay now" }, confirm: true })`,
      });
      const question = await waitFor("the gate's question", 15_000, async () => asked[0], daemon);
      assert.equal(question.askedBy, "computerUse");
      assert.equal(question.sessionId, sessionId);
      assert.match(question.message, /click AXButton "Pay now"/u);
      assert.match(question.message, /Asked from .+'s Session\./u);
      await device.answer(phone, host.hostId, question.id, "decline");
      await assert.rejects(pay, /computer\.run on .+: Not done: the person declined\./u);
    } finally {
      phone.close();
    }
    const after = (await localCall(socketPath, "axo.apps.log", { sessionId })) as { records: Array<{ service: string; tool: string; outcome: string }> };
    assert.deepEqual(after.records.map((r) => [r.service, r.tool, r.outcome])[0], ["computer", "click", "error"]);
  } finally {
    if (daemon) await terminate(daemon);
    await api.close();
    await rm(root, { recursive: true, force: true });
  }
});
