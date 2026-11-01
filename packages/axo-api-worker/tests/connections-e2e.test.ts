import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { harness, signIn } from "./harness";
import { listHosts, localCall, terminate, waitFor } from "./axod-support";

/**
 * RFD0016 end to end, with nothing faked but the sign-in provider: a Session's script, sent to a
 * real axod's local socket, runs in the account's Dynamic Worker and runs `bash` back on that
 * same Mac.
 *
 *   Session ──axod.sock──▶ axod ──WSS──▶ HostDO ──RPC──▶ AxoAccountManager ──▶ script Worker
 *                           ▲                                   │
 *                           └──── axo.connections.bash ◀── HostDO.callHost
 */
test("a Session's script runs bash on its own Mac through the account, and the call is logged", async () => {
  const binary = process.env.AXOD_BINARY;
  assert.ok(binary, "set AXOD_BINARY to the Bazel-built axod binary");
  const axodBinary = resolve(process.cwd(), binary);
  assert.ok(existsSync(axodBinary), `axod binary must exist at ${axodBinary}`);

  const api = await harness();
  const root = await mkdtemp(join(tmpdir(), "axo-connections-"));
  const serverDirectory = join(root, "server");
  const socketPath = join(root, "axod.sock");
  await mkdir(serverDirectory, { recursive: true, mode: 0o700 });
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
    await assert.rejects(localCall(socketPath, "axo.connections.list", { sessionId }), /not connected to its Axo account/);

    const account = await signIn(api);
    const pairing = await fetch(new URL("api/v1/account/host-pairings", api.url), { method: "POST", headers: account.headers });
    const { code } = (await pairing.json()) as { code: string };
    await localCall(socketPath, "axo.relay.link", { code });
    const host = await waitFor("the Mac coming online", 20_000, async () =>
      (await listHosts(api.url, account)).find((candidate) => candidate.status === "online"), daemon);

    const listed = (await localCall(socketPath, "axo.connections.list", { sessionId })) as {
      connections: Array<{ kind: string; name: string; hostId: string; state: string }>;
    };
    // The Mac, beside the apps every account lists.
    const connections = listed.connections.filter((c) => c.kind === "host");
    assert.equal(connections.length, 1);
    assert.deepEqual({ ...connections[0], name: typeof connections[0]!.name }, { kind: "host", name: "string", hostId: host.hostId, state: "online" });
    const service = connections[0]!.name;

    // A command's output larger than one relay frame comes back whole, as fragments.
    const executed = (await localCall(socketPath, "axo.connections.execute", {
      sessionId,
      code: `async () => {
        const small = await codemode.${service}.bash({ command: "echo hello-$((40 + 2)); pwd", cwd: ${JSON.stringify(root)} });
        const large = await codemode.${service}.bash({ command: "head -c 300000 /dev/zero | tr '\\\\0' a" });
        console.log("ran", small.exitCode, large.exitCode);
        return { small: small.stdout, large: large.stdout.length, truncated: large.stdoutTruncated };
      }`,
    })) as { result: { small: string; large: number; truncated: boolean }; logs: string[] };
    assert.equal(executed.result.small.split("\n")[0], "hello-42");
    assert.match(executed.result.small, /axo-connections-/);
    assert.deepEqual([executed.result.large, executed.result.truncated], [300_000, false]);
    assert.deepEqual(executed.logs, ["ran 0 0"]);

    const { records } = (await localCall(socketPath, "axo.connections.log", { sessionId })) as {
      records: Array<{ sessionId: string; hostId: string; targetHostId: string; tool: string; outcome: string; input: { command: string } }>;
    };
    assert.deepEqual(records.map((r) => [r.sessionId, r.hostId, r.targetHostId, r.tool, r.outcome]), [
      [sessionId, host.hostId, host.hostId, "bash", "ok"],
      [sessionId, host.hostId, host.hostId, "bash", "ok"],
    ]);
    assert.deepEqual(records.map((r) => r.input.command).sort(), ["echo hello-$((40 + 2)); pwd", "head -c 300000 /dev/zero | tr '\\0' a"]);
  } finally {
    if (daemon) await terminate(daemon);
    await api.close();
    await rm(root, { recursive: true, force: true });
  }
});
