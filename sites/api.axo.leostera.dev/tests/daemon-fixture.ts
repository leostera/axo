import assert from "node:assert/strict";
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { once } from "node:events";
import type { TestContext } from "node:test";
import { results, type Reply } from "@axo/protocol";
import { harness, Peer, root } from "./harness";
import { readLocalEndpoint } from "../testing/local-endpoint";

let built = false;
async function eventually<T>(read: () => Promise<T>, accepts: (value: T) => boolean) {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    try {
      const value = await read();
      if (accepts(value)) return value;
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 75));
  }
  throw new Error("Daemon fixture startup deadline");
}
async function stop(child: ChildProcess) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, "exit");
  child.kill("SIGTERM");
  const timer = setTimeout(() => child.kill("SIGKILL"), 5000);
  try { await exited; } finally { clearTimeout(timer); }
}
export function value(reply: Reply): unknown {
  assert.ok("result" in reply, "Expected successful RPC result");
  return reply.result;
}
export function error(reply: Reply): number {
  assert.ok("error" in reply, "Expected RPC error");
  return reply.error.code;
}
/** Pace logical calls plus automatic credit ACKs, not retries or an execution queue. */
export async function call(peer: Peer, method: string, params: unknown, id?: string) {
  await new Promise(resolve => setTimeout(resolve, 75));
  return peer.call(method, params, id);
}
export async function daemonFixture(t: TestContext) {
  if (!built) {
    execFileSync("cargo", ["build", "--locked", "--offline"], {
      cwd: join(root, "axod"), stdio: "pipe",
    });
    built = true;
  }
  const directory = await mkdtemp("/tmp/axo-rpc-tools-");
  const children: ChildProcess[] = [];
  const peers: Peer[] = [];
  let service: Awaited<ReturnType<typeof harness>> | undefined;
  t.after(async () => {
    for (const peer of peers) peer.close();
    await Promise.all(children.map(stop));
    if (service) await service.close();
    await rm(directory, { recursive: true, force: true });
  });
  service = await harness();
  const daemonToken = await service.token("daemon");
  const clientToken = await service.token("client");
  const config = join(directory, "relay.json");
  await writeFile(config, JSON.stringify({
    relay_url: service.url.replace(/^http/, "ws"),
    allow_insecure_loopback: true,
    label: "RPC method fixture",
    credentials: { kind: "access_assertion", assertion: daemonToken },
    profiles: { approved: { directory, argv: ["/bin/sh", "-c", "exit 0"] } },
  }), { mode: 0o600 });
  const child = spawn(join(root, "axod/target/debug/axod"), [
    "serve", directory, "--relay-config", config,
  ], { stdio: "ignore" });
  children.push(child);
  const discovery = await eventually(
    () => readLocalEndpoint(join(directory, "local-endpoint.json")),
    () => true,
  );
  await eventually(
    () => service!.list(clientToken),
    reply => reply.result.machines.some(machine =>
      machine.online && machine.hostGeneration === discovery.hostGeneration),
  );
  const local = await Peer.connectLocal(discovery);
  const cloud = await Peer.connect(service.url, clientToken, discovery.machineId, "client");
  peers.push(local, cloud);
  await local.negotiate();
  await cloud.negotiate();
  const target = { machineId: discovery.machineId, hostGeneration: discovery.hostGeneration };
  const workspaceCommandId = crypto.randomUUID();
  const workspace = results["axo.workspace.create"].parse(value(await call(local, "axo.workspace.create", {
    target, commandId: workspaceCommandId, expectedRevision: 0,
    directoryId: "approved", name: "Seed workspace",
  })));
  const workspaceTarget = { ...target, workspaceId: workspace.workspace.workspaceId };
  const session = results["axo.session.create"].parse(value(await call(local, "axo.session.create", {
    target: workspaceTarget, commandId: crypto.randomUUID(), expectedRevision: 1, name: "Seed session",
  })));
  const sessionTarget = { ...workspaceTarget, sessionId: session.session.sessionId };
  return {
    directory, local, cloud, target, workspaceTarget, sessionTarget,
    session: session.session, workspaceCommandId,
    routes: [{ name: "local", peer: local }, { name: "cloud", peer: cloud }],
  };
}
