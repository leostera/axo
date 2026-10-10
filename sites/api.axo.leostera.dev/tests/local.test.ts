import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import {
  mkdtemp,
  mkdir,
  writeFile,
  readFile,
  rm,
  stat,
  chmod,
  symlink,
  link,
  unlink,
} from "node:fs/promises";
import { join } from "node:path";
import { once } from "node:events";
import { connect as tcpConnect } from "node:net";
import WebSocket from "ws";
import {
  results,
  localEndpointSchema,
  type LocalEndpoint,
  type Reply,
} from "@axo/protocol";
import { Peer } from "../testing/client";
import { readLocalEndpoint } from "../testing/local-endpoint";
import { root } from "./harness";

async function eventually<T>(
  operation: () => Promise<T>,
  accepts: (value: T) => boolean,
) {
  for (let i = 0; i < 100; i++) {
    try {
      const value = await operation();
      if (accepts(value)) return value;
    } catch {}
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error("Local fixture deadline");
}
async function stop(child: ChildProcess) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exit = once(child, "exit");
  child.kill("SIGTERM");
  const timer = setTimeout(() => child.kill("SIGKILL"), 5000);
  try {
    await exit;
  } finally {
    clearTimeout(timer);
  }
}
async function fixture(t: any) {
  execFileSync("cargo", ["build", "--locked", "--offline"], {
    cwd: join(root, "axod"),
    stdio: "pipe",
  });
  const directory = await mkdtemp("/tmp/axo-local-");
  const state = join(directory, "child.json");
  const gone = join(directory, "gone");
  await mkdir(gone, { mode: 0o700 });
  const configuration = join(directory, "profiles.json");
  await writeFile(
    configuration,
    JSON.stringify({
      profiles: {
        fixture: {
          directory,
          argv: [
            "/usr/bin/python3",
            join(root, "axod/tests/fixtures/terminal_child.py"),
            state,
          ],
        },
        missing: { directory: gone, argv: ["/bin/sh"] },
        instant: { directory, argv: ["/bin/sh", "-c", "exit 0"] },
      },
    }),
    { mode: 0o600 },
  );
  const children: ChildProcess[] = [];
  const peers: Peer[] = [];
  const start = async () => {
    const child = spawn(
      join(root, "axod/target/debug/axod"),
      ["serve", directory, "--profiles-config", configuration],
      {
        stdio: "pipe",
        env: { ...process.env, AXO_TEST_SECRET: "fixture-only" },
      },
    );
    children.push(child);
    const discovery = await eventually(
      () => readLocalEndpoint(join(directory, "local-endpoint.json")),
      (value) => Boolean(value),
    );
    const peer = await Peer.connectLocal(discovery);
    peers.push(peer);
    await peer.negotiate();
    return { child, discovery, peer };
  };
  t.after(async () => {
    for (const peer of peers) peer.close();
    await Promise.all(children.map(stop));
    await rm(directory, { recursive: true, force: true });
  });
  return {
    directory,
    state,
    gone,
    configuration,
    peers,
    start,
    ...(await start()),
  };
}
function target(endpoint: LocalEndpoint) {
  return {
    machineId: endpoint.machineId,
    hostGeneration: endpoint.hostGeneration,
  };
}
function intent(endpoint: LocalEndpoint, profileId = "fixture") {
  return {
    commandId: crypto.randomUUID(),
    target: {
      ...target(endpoint),
      sessionId: crypto.randomUUID(),
      paneId: crypto.randomUUID(),
    },
    profileId,
  };
}
function result(reply: Reply): any {
  assert.ok("result" in reply);
  return reply.result;
}
function code(reply: Reply) {
  assert.ok("error" in reply);
  return reply.error.code;
}
async function rejected(
  endpoint: LocalEndpoint,
  headers: Record<string, string>,
  suffix = "",
) {
  const socket = new WebSocket(endpoint.endpoint + suffix, {
    headers,
    followRedirects: false,
  });
  try {
    await once(socket, "open");
    assert.fail("Disallowed native upgrade opened");
  } catch (error) {
    assert.match(String(error), /403/);
  } finally {
    socket.terminate();
  }
}

test(
  "credential-free local admission rejects browser, rebinding and unsafe discovery",
  { timeout: 20000 },
  async (t) => {
    const f = await fixture(t);
    await assert.rejects(stat(join(f.directory, "control.sock")), {
      code: "ENOENT",
    });
    assert.equal(
      (await stat(join(f.directory, "local-endpoint.json"))).mode & 0o777,
      0o600,
    );
    assert.ok(!("credential" in f.discovery));
    await rejected(f.discovery, { Origin: "https://example.com" });
    await rejected(f.discovery, { Origin: "null" });
    await rejected(f.discovery, { Host: "localhost" });
    await rejected(f.discovery, {}, "?not-accepted");
    const file = join(f.directory, "local-endpoint.json");
    const alias = join(f.directory, "alias");
    await symlink(file, alias);
    await assert.rejects(readLocalEndpoint(alias));
    await unlink(alias);
    await link(file, alias);
    await assert.rejects(readLocalEndpoint(file));
    await unlink(alias);
    await chmod(file, 0o644);
    await assert.rejects(readLocalEndpoint(file));
    await chmod(file, 0o600);
    for (const endpoint of [
      "ws://localhost:123/v1/rpc",
      "ws://0.0.0.0:123/v1/rpc",
      "ws://127.0.0.1:65536/v1/rpc",
    ])
      assert.equal(
        localEndpointSchema.safeParse({ ...f.discovery, endpoint }).success,
        false,
      );
    assert.equal(
      result(
        await f.peer.call("axo.runtime.list", { target: target(f.discovery) }),
      ).terminals.length,
      0,
    );
  },
);

test(
  "local JSON-RPC negotiation, codec, mutation notifications and target fences",
  { timeout: 20000 },
  async (t) => {
    const f = await fixture(t);
    const raw = await Peer.connectLocal(f.discovery);
    f.peers.push(raw);
    const required = await raw.call("axo.runtime.list", {
      target: target(f.discovery),
    });
    assert.equal(code(required), -32001);
    assert.equal(
      code(await raw.call("axo.protocol.negotiate", { protocolVersion: 99 })),
      -32602,
    );
    await raw.negotiate();
    raw.send("{");
    assert.equal(((await raw.next()) as any).error.code, -32700);
    raw.send([
      {
        jsonrpc: "2.0",
        id: null,
        method: "axo.runtime.list",
        params: { target: target(f.discovery) },
      },
    ]);
    const singleton: any = await raw.next();
    assert.ok(Array.isArray(singleton));
    assert.equal(singleton[0].id, null);
    raw.send({
      jsonrpc: "2.0",
      method: "axo.runtime.startApproved",
      params: intent(f.discovery),
    });
    assert.equal(
      result(
        await raw.call("axo.runtime.list", { target: target(f.discovery) }),
      ).terminals.length,
      0,
    );
    assert.equal(
      code(
        await raw.call("axo.runtime.list", {
          target: {
            ...target(f.discovery),
            hostGeneration: crypto.randomUUID(),
          },
        }),
      ),
      -32002,
    );
    assert.equal(
      code(
        await raw.call("axo.runtime.list", {
          target: { ...target(f.discovery), machineId: crypto.randomUUID() },
        }),
      ),
      -32002,
    );
    assert.equal(code(await raw.call("axo.machine.register", {})), -32601);
    assert.equal(
      code(
        await raw.call("axo.runtime.startApproved", {
          ...intent(f.discovery),
          argv: ["/bin/sh"],
        }),
      ),
      -32602,
    );
  },
);

test(
  "local launch receipts survive disconnect and boot without replay, generation rotates",
  { timeout: 25000 },
  async (t) => {
    const f = await fixture(t);
    const params = intent(f.discovery);
    const launched = results["axo.runtime.startApproved"].parse(
      result(await f.peer.call("axo.runtime.startApproved", params)),
    );
    const state: any = await eventually(
      async () => JSON.parse(await readFile(f.state, "utf8")),
      (value) => value.ticks > 2,
    );
    assert.deepEqual(state.inherited_fds, []);
    assert.deepEqual(state.inherited_axo, []);
    const retry = result(
      await f.peer.call("axo.runtime.startApproved", params),
    );
    assert.deepEqual(retry.terminal.runtime, launched.terminal.runtime);
    assert.equal(
      code(
        await f.peer.call("axo.runtime.startApproved", {
          ...params,
          target: { ...params.target, paneId: crypto.randomUUID() },
        }),
      ),
      -32007,
    );
    const saved = await readFile(
      join(f.directory, "runtime-state.json"),
      "utf8",
    );
    assert.ok(!saved.includes("argv"));
    f.peer.close();
    await eventually(
      async () => JSON.parse(await readFile(f.state, "utf8")),
      (value) => value.ticks > state.ticks + 3,
    );
    const reconnected = await Peer.connectLocal(f.discovery);
    f.peers.push(reconnected);
    await reconnected.negotiate();
    assert.deepEqual(
      result(
        await reconnected.call("axo.runtime.list", {
          target: target(f.discovery),
        }),
      ).terminals[0].runtime,
      launched.terminal.runtime,
    );
    await stop(f.child);
    await assert.rejects(stat(join(f.directory, "local-endpoint.json")));
    const current = await f.start();
    assert.equal(current.discovery.machineId, f.discovery.machineId);
    assert.notEqual(
      current.discovery.hostGeneration,
      f.discovery.hostGeneration,
    );
    assert.equal(
      code(
        await current.peer.call("axo.runtime.list", {
          target: target(f.discovery),
        }),
      ),
      -32002,
    );
    const reconciled = result(
      await current.peer.call("axo.runtime.startApproved", {
        ...params,
        target: {
          ...params.target,
          hostGeneration: current.discovery.hostGeneration,
        },
      }),
    );
    assert.deepEqual(reconciled.terminal.runtime, launched.terminal.runtime);
    assert.equal(reconciled.terminal.process.kind, "exited");
  },
);

test(
  "duplicate owners, failed launch receipts and recovery records fail closed",
  { timeout: 25000 },
  async (t) => {
    const f = await fixture(t);
    assert.throws(() =>
      execFileSync(
        join(root, "axod/target/debug/axod"),
        ["serve", f.directory],
        { stdio: "pipe" },
      ),
    );
    await rm(f.gone, { recursive: true });
    const params = intent(f.discovery, "missing");
    assert.equal(
      code(await f.peer.call("axo.runtime.startApproved", params)),
      -32010,
    );
    assert.equal(
      code(await f.peer.call("axo.runtime.startApproved", params)),
      -32010,
    );
    const savedFile = join(f.directory, "runtime-state.json");
    await stop(f.child);
    const saved = JSON.parse(await readFile(savedFile, "utf8"));
    Object.values(saved.terminals).forEach(
      (record: any) => (record.process = { kind: "starting" }),
    );
    await writeFile(savedFile, JSON.stringify(saved), { mode: 0o600 });
    // Recreate the configured directory so startup validates; uncertain state still cannot relaunch.
    await mkdir(f.gone, { mode: 0o700 });
    const next = await f.start();
    const list = result(
      await next.peer.call("axo.runtime.list", {
        target: target(next.discovery),
        limit: 1,
      }),
    );
    assert.equal(list.terminals[0].process.kind, "recovery_required");
    assert.equal(
      code(
        await next.peer.call("axo.runtime.startApproved", {
          ...params,
          target: {
            ...params.target,
            hostGeneration: next.discovery.hostGeneration,
          },
        }),
      ),
      -32009,
    );
    await stop(next.child);
    await unlink(savedFile);
    await symlink(join(f.directory, "unowned"), savedFile);
    assert.throws(() =>
      execFileSync(
        join(root, "axod/target/debug/axod"),
        ["serve", f.directory],
        { stdio: "pipe" },
      ),
    );
  },
);

test(
  "stopped-record paging is bounded and never relaunches work",
  { timeout: 20000 },
  async (t) => {
    const f = await fixture(t);
    for (let i = 0; i < 3; i++)
      result(
        await f.peer.call(
          "axo.runtime.startApproved",
          intent(f.discovery, "instant"),
        ),
      );
    await eventually(
      async () =>
        result(
          await f.peer.call("axo.runtime.list", {
            target: target(f.discovery),
          }),
        ),
      (value) =>
        value.terminals.length === 3 &&
        value.terminals.every((v: any) => v.process.kind === "exited"),
    );
    const first = result(
      await f.peer.call("axo.runtime.list", {
        target: target(f.discovery),
        limit: 2,
      }),
    );
    assert.equal(first.terminals.length, 2);
    assert.ok(first.next);
    const second = result(
      await f.peer.call("axo.runtime.list", {
        target: target(f.discovery),
        after: first.next,
        limit: 2,
      }),
    );
    assert.equal(second.terminals.length, 1);
    assert.equal(second.next, null);
    assert.equal(
      code(
        await f.peer.call("axo.runtime.list", {
          target: target(f.discovery),
          limit: 51,
        }),
      ),
      -32602,
    );
    assert.ok(
      [...first.terminals, ...second.terminals].every(
        (v) => v.process.kind === "exited",
      ),
    );
  },
);

test(
  "upgrade deadline, header/frame limits, invalid credits and slow consumers release connections",
  { timeout: 20000 },
  async (t) => {
    const f = await fixture(t);
    const address = new URL(f.discovery.endpoint);
    const stalled = tcpConnect(Number(address.port), address.hostname);
    await once(stalled, "connect");
    stalled.write("GET /v1/rpc HTTP/1.1\r\n");
    await once(stalled, "close");
    const large = tcpConnect(Number(address.port), address.hostname);
    await once(large, "connect");
    large.on("error", () => {});
    large.write("x".repeat(8193));
    await new Promise<void>((resolve) => large.once("close", () => resolve()));
    const invalid = await Peer.connectLocal(f.discovery);
    f.peers.push(invalid);
    const closed = once(invalid.socket, "close");
    invalid.send({
      jsonrpc: "2.0",
      method: "axo.transport.ack",
      params: { frames: 1 },
    });
    await closed;
    const binary = await Peer.connectLocal(f.discovery);
    f.peers.push(binary);
    const binaryClosed = once(binary.socket, "close");
    binary.socket.send(Buffer.from("no terminal bytes"));
    await binaryClosed;
    const oversized = await Peer.connectLocal(f.discovery);
    f.peers.push(oversized);
    const sizeClosed = once(oversized.socket, "close");
    oversized.send("x".repeat(65537));
    await sizeClosed;
    const slow = await Peer.connectLocal(f.discovery, false);
    f.peers.push(slow);
    await slow.negotiate();
    for (let i = 0; i < 31; i++) {
      await new Promise((r) => setTimeout(r, 75));
      assert.ok(
        "result" in
          (await slow.call("axo.runtime.list", {
            target: target(f.discovery),
          })),
      );
    }
    const denied = await slow.call(
      "axo.runtime.startApproved",
      intent(f.discovery),
    );
    assert.equal(code(denied), -32004);
    assert.equal(
      result(
        await f.peer.call("axo.runtime.list", { target: target(f.discovery) }),
      ).terminals.length,
      0,
    );
  },
);
