import { test } from "node:test";
import assert from "node:assert/strict";
import {
  spawn,
  execFile,
  execFileSync,
  type ChildProcess,
} from "node:child_process";
import { mkdtemp, mkdir, writeFile, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { once } from "node:events";
import { promisify } from "node:util";
import { harness, Peer, root } from "./harness";
import { results, type Reply } from "@axo/protocol";
import { readLocalEndpoint } from "../testing/local-endpoint";

async function eventually<T>(
  operation: () => Promise<T>,
  accepts: (value: T) => boolean,
  description: string,
): Promise<T> {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    try {
      const value = await operation();
      if (accepts(value)) return value;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Deadline: ${description}`);
}
async function stop(process: ChildProcess) {
  if (process.exitCode !== null || process.signalCode !== null) return;
  const exited = once(process, "exit");
  process.kill("SIGTERM");
  const timer = setTimeout(() => {
    if (process.exitCode === null && process.signalCode === null)
      process.kill("SIGKILL");
  }, 8000);
  try {
    await exited;
  } finally {
    clearTimeout(timer);
  }
}
function value(reply: Reply) {
  assert.ok("result" in reply, JSON.stringify(reply));
  return reply.result;
}

test(
  "dummy client -> protected API -> two real axod owners and PTYs",
  { timeout: 45000 },
  async (t) => {
    execFileSync("cargo", ["build", "--locked", "--offline"], {
      cwd: join(root, "axod"),
      stdio: "pipe",
    });
    const directory = await mkdtemp("/tmp/axo-fleet-");
    const h = await harness();
    let serviceStopped = false;
    const daemons: ChildProcess[] = [];
    const peers: Peer[] = [];
    t.after(async () => {
      for (const peer of peers) peer.close();
      await Promise.all(daemons.map(stop));
      if (!serviceStopped) await h.close();
      await rm(directory, { recursive: true, force: true });
    });
    const daemonToken = await h.token("daemon");
    const clientToken = await h.token("client");
    const clientCredential = join(directory, "client.jwt");
    await writeFile(clientCredential, clientToken, { mode: 0o600 });
    const roots: string[] = [];
    const stateFiles: string[] = [];
    const configurations: string[] = [];
    for (const name of ["A", "B"]) {
      const stateRoot = join(directory, name);
      await mkdir(stateRoot, { mode: 0o700 });
      roots.push(stateRoot);
      const state = join(stateRoot, "fixture-state.json");
      stateFiles.push(state);
      const configuration = join(stateRoot, "relay.json");
      configurations.push(configuration);
      await writeFile(
        configuration,
        JSON.stringify({
          relay_url: h.url.replace(/^http/, "ws"),
          allow_insecure_loopback: true,
          label: name,
          credentials: { kind: "access_assertion", assertion: daemonToken },
          profiles: {
            fixture: {
              directory: stateRoot,
              argv: [
                "/usr/bin/python3",
                join(root, "axod/tests/fixtures/terminal_child.py"),
                state,
              ],
            },
          },
        }),
        { mode: 0o600 },
      );
      daemons.push(
        spawn(
          join(root, "axod/target/debug/axod"),
          ["serve", stateRoot, "--relay-config", configuration],
          { stdio: "pipe" },
        ),
      );
    }
    const discovered = await eventually(
      () => h.list(clientToken),
      (reply) =>
        reply.result.machines.length === 2 &&
        reply.result.machines.every((machine) => machine.online),
      "two real daemons registered",
    );
    const machines = discovered.result.machines.sort((a, b) =>
      a.label.localeCompare(b.label),
    );
    const targets = machines.map((machine) => {
      assert.ok(machine.hostGeneration);
      return {
        machineId: machine.machineId,
        hostGeneration: machine.hostGeneration!,
      };
    });
    const human = await Peer.connect(
      h.url,
      clientToken,
      targets[0].machineId,
      "client",
    );
    peers.push(human);
    await human.negotiate();
    const other = await Peer.connect(
      h.url,
      clientToken,
      targets[1].machineId,
      "client",
    );
    peers.push(other);
    await other.negotiate();
    for (const [index, peer] of peers.entries()) {
      assert.deepEqual(
        results["axo.runtime.list"].parse(
          value(
            await peer.call("axo.runtime.list", { target: targets[index] }),
          ),
        ),
        {
          hostGeneration: targets[index].hostGeneration,
          terminals: [],
          next: null,
        },
      );
    }
    const localEndpoint = await readLocalEndpoint(
      join(roots[0], "local-endpoint.json"),
    );
    assert.equal(localEndpoint.machineId, targets[0].machineId);
    assert.equal(localEndpoint.hostGeneration, targets[0].hostGeneration);
    const mac = await Peer.connectLocal(localEndpoint);
    peers.push(mac);
    await mac.negotiate();
    assert.deepEqual(
      value(await mac.call("axo.runtime.list", { target: targets[0] })),
      value(await human.call("axo.runtime.list", { target: targets[0] })),
    );
    const cli = await promisify(execFile)(
      process.execPath,
      [
        "--import",
        "tsx",
        "scripts/dummy-client.ts",
        h.url,
        clientCredential,
        "--machine",
        targets[0].machineId,
        "--allow-loopback",
      ],
      {
        cwd: join(root, "packages/axo-api-worker"),
        timeout: 15000,
        maxBuffer: 65536,
      },
    );
    assert.match(cli.stdout, /"terminals": \[\]/);
    assert.ok(!cli.stdout.includes(clientToken));
    // Registration and read-only discovery/listing cannot launch a saved runtime.
    for (const state of stateFiles) await assert.rejects(readFile(state));
    const target = {
      ...targets[0],
      sessionId: crypto.randomUUID(),
      paneId: crypto.randomUUID(),
    };
    const commandId = crypto.randomUUID();
    const params = { commandId, target, profileId: "fixture" };
    const launched = results["axo.runtime.startApproved"].parse(
      value(await mac.call("axo.runtime.startApproved", params)),
    );
    const retried = results["axo.runtime.startApproved"].parse(
      value(await human.call("axo.runtime.startApproved", params)),
    );
    assert.equal(
      launched.terminal.runtime.runtime_generation,
      retried.terminal.runtime.runtime_generation,
    );
    const initial = await eventually(
      async () =>
        JSON.parse(await readFile(stateFiles[0], "utf8")) as {
          ticks: number;
          pid: number;
          inherited_fds: number[];
          inherited_axo: string[];
        },
      (value) => value.ticks > 2,
      "real PTY fixture running",
    );
    assert.deepEqual(initial.inherited_fds, []);
    assert.deepEqual(initial.inherited_axo, []);
    const aList = results["axo.runtime.list"].parse(
      value(await human.call("axo.runtime.list", { target: targets[0] })),
    );
    const macList = results["axo.runtime.list"].parse(value(await mac.call("axo.runtime.list", { target: targets[0] })));
    // Sequential live snapshots may have different output-byte counts; routing identities must agree.
    const identities = (page: typeof aList) => ({ hostGeneration: page.hostGeneration, next: page.next, terminals: page.terminals.map(({ runtime, process, attached }) => ({ runtime, process, attached })) });
    assert.deepEqual(identities(macList), identities(aList));
    assert.equal(aList.terminals.length, 1);
    assert.equal(aList.terminals[0].runtime.target.pane_id, target.paneId);
    assert.equal(
      results["axo.runtime.list"].parse(
        value(await other.call("axo.runtime.list", { target: targets[1] })),
      ).terminals.length,
      0,
    );
    const conflict = await human.call("axo.runtime.startApproved", {
      ...params,
      target: { ...target, paneId: crypto.randomUUID() },
    });
    assert.ok("error" in conflict);
    assert.equal(conflict.error.code, -32007);
    const arbitrary = await human.call("axo.runtime.startApproved", {
      ...params,
      argv: ["/bin/sh"],
    });
    assert.ok("error" in arbitrary);
    assert.equal(arbitrary.error.code, -32602);
    // Client/transport loss is not host stop. Reconnect reads the same runtime.
    human.close();
    const replacement = await Peer.connect(
      h.url,
      clientToken,
      targets[0].machineId,
      "client",
    );
    peers.push(replacement);
    await replacement.negotiate();
    const restored = results["axo.runtime.list"].parse(
      value(await replacement.call("axo.runtime.list", { target: targets[0] })),
    );
    assert.equal(
      restored.terminals[0].runtime.runtime_generation,
      launched.terminal.runtime.runtime_generation,
    );
    // Cold daemon restart retains machine/receipts but never promotes historical runtimes.
    await stop(daemons[0]);
    daemons.push(
      spawn(
        join(root, "axod/target/debug/axod"),
        ["serve", roots[0], "--relay-config", configurations[0]],
        { stdio: "pipe" },
      ),
    );
    const afterRestart = await eventually(
      () => h.list(clientToken),
      (reply) =>
        reply.result.machines.some(
          (machine) =>
            machine.machineId === targets[0].machineId &&
            machine.online &&
            machine.hostGeneration !== targets[0].hostGeneration,
        ),
      "same machine re-registers with fresh boot generation",
    );
    const current = afterRestart.result.machines.find(
      (machine) => machine.machineId === targets[0].machineId,
    )!;
    assert.ok(current.hostGeneration);
    const currentTarget = {
      machineId: current.machineId,
      hostGeneration: current.hostGeneration,
    };
    const historical = results["axo.runtime.list"].parse(
      value(
        await replacement.call("axo.runtime.list", { target: currentTarget }),
      ),
    );
    assert.equal(historical.hostGeneration, currentTarget.hostGeneration);
    assert.equal(
      historical.terminals[0].runtime.host_generation,
      targets[0].hostGeneration,
    );
    assert.equal(historical.terminals[0].process.kind, "exited");
    const reconciled = results["axo.runtime.startApproved"].parse(
      value(
        await replacement.call("axo.runtime.startApproved", {
          ...params,
          target: { ...target, hostGeneration: currentTarget.hostGeneration },
        }),
      ),
    );
    assert.equal(
      reconciled.terminal.runtime.runtime_generation,
      launched.terminal.runtime.runtime_generation,
    );
    assert.equal(reconciled.terminal.process.kind, "exited");
    const stale = await replacement.call("axo.runtime.list", {
      target: targets[0],
    });
    assert.ok("error" in stale);
    assert.equal(stale.error.code, -32002);
    // A different machine still owns its independent live fixture.
    const bParams = {
      commandId: crypto.randomUUID(),
      target: {
        ...targets[1],
        sessionId: crypto.randomUUID(),
        paneId: crypto.randomUUID(),
      },
      profileId: "fixture",
    };
    value(await other.call("axo.runtime.startApproved", bParams));
    await eventually(
      async () =>
        JSON.parse(await readFile(stateFiles[1], "utf8")) as { ticks: number },
      (value) => value.ticks > 2,
      "second independent PTY running",
    );
    for (const peer of peers) peer.close();
    await h.close();
    serviceStopped = true;
    const localAfterOutage = await Peer.connectLocal(
      await readLocalEndpoint(join(roots[1], "local-endpoint.json")),
    );
    peers.push(localAfterOutage);
    await localAfterOutage.negotiate();
    assert.equal(
      results["axo.runtime.list"].parse(
        value(
          await localAfterOutage.call("axo.runtime.list", {
            target: targets[1],
          }),
        ),
      ).terminals.length,
      1,
    );
    const afterOutage = JSON.parse(await readFile(stateFiles[1], "utf8")) as {
      ticks: number;
      pid: number;
    };
    const later = await eventually(
      async () =>
        JSON.parse(await readFile(stateFiles[1], "utf8")) as {
          ticks: number;
          pid: number;
        },
      (value) => value.ticks > afterOutage.ticks + 5,
      "PTY advances after API shutdown has completed",
    );
    assert.equal(later.pid, afterOutage.pid);

    const persisted = JSON.parse(
      await readFile(join(roots[0], "machine-id.json"), "utf8"),
    );
    assert.equal(persisted, targets[0].machineId);
  },
);
