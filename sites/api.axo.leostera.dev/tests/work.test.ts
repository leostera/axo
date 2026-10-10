import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { mkdtemp, writeFile, readFile, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import { once } from "node:events";
import { results, type Reply, type RemoteMethod } from "@axo/protocol";
import { harness, Peer, root } from "./harness";
import { readLocalEndpoint } from "../testing/local-endpoint";

async function eventually<T>(operation: () => Promise<T>, accepts: (value: T) => boolean): Promise<T> {
  const until = Date.now() + 10000;
  while (Date.now() < until) {
    try { const value = await operation(); if (accepts(value)) return value; } catch {}
    await new Promise(resolve => setTimeout(resolve, 75));
  }
  throw new Error("Work-record fixture deadline");
}
async function stop(child: ChildProcess) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, "exit"); child.kill("SIGTERM");
  const timer = setTimeout(() => child.kill("SIGKILL"), 5000);
  try { await exited; } finally { clearTimeout(timer); }
}
function value(reply: Reply): unknown { assert.ok("result" in reply); return reply.result; }
function error(reply: Reply): number { assert.ok("error" in reply); return reply.error.code; }
// Honor ingress limits (including automatic reply-credit ACKs); this is not a transport retry.
class WorkPeer {
  constructor(private peer: Peer) {}
  async call(method: string, params: unknown) {
    await new Promise(resolve => setTimeout(resolve, 75));
    return this.peer.call(method, params);
  }
  send(value: unknown) { this.peer.send(value); }
  close() { this.peer.close(); }
}
async function output(peer: WorkPeer, method: RemoteMethod, params: unknown) { return value(await peer.call(method, params)); }

test("daemon-owned work records have identical local/cloud semantics and durable boot-fenced reconciliation", { timeout: 45000 }, async t => {
  execFileSync("cargo", ["build", "--locked", "--offline"], { cwd: join(root, "axod"), stdio: "pipe" });
  const directory = await mkdtemp("/tmp/axo-work-");
  const h = await harness(); const daemons: ChildProcess[] = []; const peers: Peer[] = [];
  t.after(async () => { peers.forEach(p => p.close()); await Promise.all(daemons.map(stop)); await h.close(); await rm(directory, { recursive: true, force: true }); });
  const daemonToken = await h.token("daemon"); const clientToken = await h.token("client");
  const config = join(directory, "relay.json");
  await writeFile(config, JSON.stringify({
    relay_url: h.url.replace(/^http/, "ws"), allow_insecure_loopback: true, label: "Work fixture",
    credentials: { kind: "access_assertion", assertion: daemonToken },
    profiles: { approved: { directory, argv: ["/bin/sh", "-c", "exit 0"] } },
  }), { mode: 0o600 });
  async function start(previousGeneration?: string) {
    const child = spawn(join(root, "axod/target/debug/axod"), ["serve", directory, "--relay-config", config], { stdio: "pipe" }); daemons.push(child);
    const discovery = await eventually(() => readLocalEndpoint(join(directory, "local-endpoint.json")), d => d.hostGeneration !== previousGeneration);
    await eventually(() => h.list(clientToken), r => r.result.machines.some(m => m.online && m.hostGeneration === discovery.hostGeneration));
    const local = await Peer.connectLocal(discovery); const cloud = await Peer.connect(h.url, clientToken, discovery.machineId, "client"); peers.push(local, cloud);
    await local.negotiate(); await cloud.negotiate();
    return { child, local: new WorkPeer(local), cloud: new WorkPeer(cloud), target: { machineId: discovery.machineId, hostGeneration: discovery.hostGeneration } };
  }
  const f = await start(); let revision = 0;
  const workspaces: string[] = []; const sessions: Array<{ workspaceId: string; sessionId: string; paneId: string }> = [];
  const committedIntents: Array<{ target: typeof f.target; commandId: string; expectedRevision: number; directoryId: string; name: string }> = [];
  for (const [primary, observer] of [[f.local, f.cloud], [f.cloud, f.local]]) {
    const empty = results["axo.workspace.list"].parse(await output(primary, "axo.workspace.list", { target: f.target })); assert.equal(empty.revision, revision);
    const create = { target: f.target, commandId: crypto.randomUUID(), expectedRevision: revision, directoryId: "approved", name: `Workspace ${revision} 😃` };
    committedIntents.push(create);
    const committed = results["axo.workspace.create"].parse(await output(primary, "axo.workspace.create", create)); revision++;
    assert.equal(committed.revision, revision); workspaces.push(committed.workspace.workspaceId);
    assert.deepEqual(await output(observer, "axo.workspace.create", create), committed);
    const workspaceTarget = { ...f.target, workspaceId: committed.workspace.workspaceId };
    const renamed = results["axo.workspace.rename"].parse(await output(primary, "axo.workspace.rename", { target: workspaceTarget, commandId: crypto.randomUUID(), expectedRevision: revision, name: "Manual workspace" })); revision++;
    assert.equal(renamed.workspace.name, "Manual workspace");
    for (let i = 0; i < 3; i++) {
      const sessionIntent = { target: workspaceTarget, commandId: crypto.randomUUID(), expectedRevision: revision, name: `Session ${i}` };
      const session = results["axo.session.create"].parse(await output(primary, "axo.session.create", sessionIntent)); revision++;
      assert.equal(session.session.runtime, null); assert.equal(session.session.pi.chatId, null); assert.equal(session.session.pi.admission, "notAdmitted");
      assert.deepEqual(await output(observer, "axo.session.create", sessionIntent), session);
      const sessionTarget = { ...workspaceTarget, sessionId: session.session.sessionId };
      const read = await output(primary, "axo.session.get", { target: sessionTarget }); assert.deepEqual(await output(observer, "axo.session.get", { target: sessionTarget }), read);
      sessions.push({ workspaceId: workspaceTarget.workspaceId, sessionId: session.session.sessionId, paneId: session.session.pi.paneId });
      const sessionRename = { target: sessionTarget, commandId: crypto.randomUUID(), expectedRevision: revision, name: "Protected manual label" };
      const changed = results["axo.session.rename"].parse(await output(primary, "axo.session.rename", sessionRename)); revision++;
      assert.equal(changed.session.nameSource, "manual"); assert.equal(changed.session.name, "Protected manual label");
      assert.deepEqual(await output(observer, "axo.session.rename", sessionRename), changed);
    }
    const first = results["axo.session.list"].parse(await output(primary, "axo.session.list", { target: f.target, workspaceId: workspaceTarget.workspaceId, limit: 2 }));
    assert.equal(first.sessions.length, 2); assert.ok(first.next);
    const secondParams = { target: f.target, workspaceId: workspaceTarget.workspaceId, cursor: first.next, limit: 2 };
    const second = results["axo.session.list"].parse(await output(primary, "axo.session.list", secondParams)); assert.equal(second.sessions.length, 1); assert.equal(second.next, null);
    assert.deepEqual(await output(observer, "axo.session.list", secondParams), second);
    assert.equal(error(await primary.call("axo.session.list", { ...secondParams, workspaceId: crypto.randomUUID() })), -32010);
    assert.equal(error(await primary.call("axo.session.list", { ...secondParams, workspaceId: undefined })), -32002);
    for (const peer of [primary, observer]) {
      const before = results["axo.workspace.list"].parse(await output(peer, "axo.workspace.list", { target: f.target }));
      peer.send({ jsonrpc: "2.0", method: "axo.workspace.create", params: { ...create, commandId: crypto.randomUUID(), expectedRevision: revision } });
      assert.deepEqual(await output(peer, "axo.workspace.list", { target: f.target }), before);
      for (const params of [
        { ...create, commandId: crypto.randomUUID(), expectedRevision: revision, directoryId: "/unapproved" },
        { ...create, commandId: crypto.randomUUID(), expectedRevision: revision, name: " leading" },
        { ...create, commandId: crypto.randomUUID(), expectedRevision: revision, name: "line\nbreak" },
        { ...create, commandId: crypto.randomUUID(), expectedRevision: revision, cwd: directory },
      ]) assert.equal(error(await peer.call("axo.workspace.create", params)), -32602);
      assert.equal(error(await peer.call("axo.workspace.create", { ...create, name: "Conflict" })), -32007);
      assert.equal(error(await peer.call("axo.workspace.rename", { target: workspaceTarget, commandId: crypto.randomUUID(), expectedRevision: 0, name: "Stale revision" })), -32007);
      assert.equal(error(await peer.call("axo.session.get", { target: { ...f.target, workspaceId: crypto.randomUUID(), sessionId: sessions[0].sessionId } })), -32010);
      assert.equal(error(await peer.call("axo.workspace.list", { target: { ...f.target, machineId: crypto.randomUUID() } })), -32002);
      assert.equal(error(await peer.call("axo.workspace.list", { target: { ...f.target, hostGeneration: crypto.randomUUID() } })), -32002);
      const receipt = results["axo.command.get"].parse(await output(peer, "axo.command.get", { target: f.target, commandId: create.commandId }));
      assert.ok(receipt.receipt?.kind === "work"); assert.equal(receipt.receipt.committed.revision, create.expectedRevision + 1);
      const missing = results["axo.command.get"].parse(await output(peer, "axo.command.get", { target: f.target, commandId: crypto.randomUUID() })); assert.equal(missing.receipt, null);
    }
  }
  // No create/read/rename/subscription-selection surrogate can execute a process.
  assert.equal(results["axo.runtime.list"].parse(await output(f.local, "axo.runtime.list", { target: f.target })).terminals.length, 0);
  await assert.rejects(stat(join(directory, "runtime-state.json")), { code: "ENOENT" });
  const page = results["axo.workspace.list"].parse(await output(f.cloud, "axo.workspace.list", { target: f.target, limit: 1 })); assert.ok(page.next);
  assert.equal(error(await f.local.call("axo.workspace.list", { target: f.target, cursor: { ...page.next, target: { ...f.target, machineId: crypto.randomUUID() } } })), -32002);
  const rename = { target: { ...f.target, workspaceId: workspaces[0] }, commandId: crypto.randomUUID(), expectedRevision: revision, name: "New revision" };
  await output(f.local, "axo.workspace.rename", rename); revision++;
  assert.equal(error(await f.cloud.call("axo.workspace.list", { target: f.target, cursor: page.next })), -32002);
  // Execution and work mutations share a command admission lock and reject cross-journal reuse.
  const session = sessions[0]; const runtimeIntent = { target: { ...f.target, sessionId: session.sessionId, paneId: session.paneId }, commandId: committedIntents[0].commandId, profileId: "approved" };
  assert.equal(error(await f.cloud.call("axo.runtime.startApproved", runtimeIntent)), -32007);
  assert.equal(results["axo.runtime.list"].parse(await output(f.local, "axo.runtime.list", { target: f.target })).terminals.length, 0);
  runtimeIntent.commandId = crypto.randomUUID();
  const launched = results["axo.runtime.startApproved"].parse(await output(f.local, "axo.runtime.startApproved", runtimeIntent));
  assert.equal(error(await f.cloud.call("axo.workspace.create", { ...committedIntents[0], commandId: runtimeIntent.commandId, expectedRevision: revision })), -32007);
  await eventually(async () => results["axo.runtime.list"].parse(await output(f.cloud, "axo.runtime.list", { target: f.target })), r => r.terminals.every(t => t.process.kind === "exited"));
  const sessionTarget = { ...f.target, workspaceId: session.workspaceId, sessionId: session.sessionId };
  const observed = results["axo.session.get"].parse(await output(f.cloud, "axo.session.get", { target: sessionTarget }));
  assert.deepEqual(observed.session.runtime?.runtime, launched.terminal.runtime); assert.equal(observed.session.pi.admission, "notAdmitted");
  assert.equal((await stat(join(directory, "work-records.json"))).mode & 0o777, 0o600);
  const saved = await readFile(join(directory, "work-records.json"), "utf8");
  for (const forbidden of ["argv", "messages", "transcript", clientToken, daemonToken]) assert.ok(!saved.includes(forbidden));
  const oldSource = f.target.hostGeneration; const oldCursor = results["axo.workspace.list"].parse(await output(f.local, "axo.workspace.list", { target: f.target, limit: 1 })).next;
  f.local.close(); f.cloud.close(); await stop(f.child);
  const next = await start(oldSource); assert.equal(next.target.machineId, f.target.machineId); assert.notEqual(next.target.hostGeneration, oldSource);
  for (const peer of [next.local, next.cloud]) {
    assert.equal(error(await peer.call("axo.workspace.list", { target: f.target })), -32002);
    assert.equal(error(await peer.call("axo.workspace.list", { target: next.target, cursor: oldCursor })), -32002);
    const current = results["axo.session.get"].parse(await output(peer, "axo.session.get", { target: { ...sessionTarget, hostGeneration: next.target.hostGeneration } }));
    assert.equal(current.revision, revision); assert.equal(current.session.name, "Protected manual label"); assert.equal(current.session.pi.paneId, session.paneId);
    assert.deepEqual(current.session.runtime?.runtime, launched.terminal.runtime);
    const receipt = results["axo.command.get"].parse(await output(peer, "axo.command.get", { target: next.target, commandId: runtimeIntent.commandId })); assert.equal(receipt.receipt?.kind, "runtime");
    const reconciled = results["axo.workspace.create"].parse(await output(peer, "axo.workspace.create", { ...committedIntents[0], target: next.target }));
    assert.equal(reconciled.workspace.workspaceId, workspaces[0]); assert.equal(reconciled.revision, 1);
    assert.equal(results["axo.runtime.list"].parse(await output(peer, "axo.runtime.list", { target: next.target })).terminals.length, 1);
  }
});
