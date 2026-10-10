import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile, rename, mkdir, stat } from "node:fs/promises";
import { join } from "node:path";
import {
  METHODS, results, replySchema, workMutationMethods, remoteMethods, paneMethods,
  type RemoteMethod,
} from "@axo/protocol";
import type { z } from "zod";
import { root } from "./harness";
import { daemonFixture, call, value, error } from "./daemon-fixture";

type Fixture = Awaited<ReturnType<typeof daemonFixture>>;
type MethodInputs = { [Method in RemoteMethod]: z.input<(typeof remoteMethods)[Method]> };
function methodInputs(f: Fixture) {
  const mutation = { commandId: crypto.randomUUID(), expectedRevision: 2, name: "Explicit mutation" };
  const piTarget = { ...f.sessionTarget, paneId: f.session.pi.paneId };
  const chat = { ...piTarget, runtimeHostGeneration: f.target.hostGeneration, runtimeGeneration: crypto.randomUUID(), chatId: crypto.randomUUID() };
  const chatCommand = { target: chat, commandId: crypto.randomUUID() };
  // Adding an exposed method requires an input here, rather than silently losing test coverage.
  return {
    "axo.workspace.list": { target: f.target },
    "axo.workspace.create": { target: f.target, ...mutation, directoryId: "approved" },
    "axo.workspace.rename": { target: f.workspaceTarget, ...mutation },
    "axo.session.list": { target: f.target, workspaceId: f.workspaceTarget.workspaceId },
    "axo.session.get": { target: f.sessionTarget },
    "axo.session.create": { target: f.workspaceTarget, ...mutation },
    "axo.session.rename": { target: f.sessionTarget, ...mutation },
    "axo.command.get": { target: f.target, commandId: f.workspaceCommandId },
    "axo.session.start": { target: piTarget, commandId: crypto.randomUUID(), persistence: { kind: "fresh" as const } },
    "axo.chat.get": { target: chat },
    "axo.chat.history": { target: chat },
    "axo.chat.getToolOutput": { target: chat, entryId: "recorded-entry", toolCallId: "recorded-call", offset: 0 },
    "axo.chat.sendMessage": { ...chatCommand, text: "Not executed" },
    "axo.chat.sendSteeringMessage": { ...chatCommand, interactionId: crypto.randomUUID(), text: "Not executed" },
    "axo.chat.cancelTurn": { ...chatCommand, interactionId: crypto.randomUUID() },
    "axo.chat.answerQuestion": { ...chatCommand, interactionId: crypto.randomUUID(), questionId: crypto.randomUUID(), optionId: crypto.randomUUID() },
    "axo.chat.setViewing": { ...chatCommand, leaseId: crypto.randomUUID(), viewing: true, ttlSeconds: 30 },
    "axo.runtime.list": { target: f.target },
    "axo.runtime.startApproved": {
      target: { ...f.target, sessionId: f.session.sessionId, paneId: f.session.pi.paneId },
      commandId: crypto.randomUUID(), profileId: "approved",
    },
  } satisfies MethodInputs;
}
async function metadata(f: Fixture) {
  return readFile(join(f.directory, "work-records.json"), "utf8");
}
async function noExecution(f: Fixture) {
  for (const { peer } of f.routes) {
    const page = results["axo.runtime.list"].parse(value(await call(peer, "axo.runtime.list", { target: f.target })));
    assert.deepEqual(page.terminals, []);
  }
  await assert.rejects(stat(join(f.directory, "runtime-state.json")), { code: "ENOENT" });
}

test("every exposed daemon RPC rejects malformed or stale calls on both real routes", { timeout: 45000 }, async t => {
  const f = await daemonFixture(t);
  const inputs = methodInputs(f);
  assert.deepEqual(Object.keys(inputs).sort(), [...METHODS].sort());
  const before = await metadata(f);
  for (const { name, peer } of f.routes) {
    for (const method of METHODS) {
      await t.test(`${name}: ${method}`, async () => {
        const valid = inputs[method];
        for (const malformed of [[], {}, { ...valid, unexpected: true }, {
          ...valid, target: { ...valid.target, machineId: "not-a-uuid" },
        }]) {
          assert.equal(error(await call(peer, method, malformed)), -32602);
        }
        for (const field of ["machineId", "hostGeneration"] as const) {
          assert.equal(error(await call(peer, method, {
            ...valid, target: { ...valid.target, [field]: crypto.randomUUID() },
          })), -32002);
        }
        // All id-less calls are non-executing, even with otherwise valid mutation input.
        peer.send({ jsonrpc: "2.0", method, params: valid });
        const barrier = results["axo.command.get"].parse(value(await call(peer, "axo.command.get", {
          target: f.target, commandId: f.workspaceCommandId,
        })));
        assert.equal(barrier.receipt?.kind, "work");
      });
    }
    // Cloud infrastructure is not a callable daemon/native capability.
    for (const method of ["axo.machine.register", "axo.machine.heartbeat", "axo.machine.list"]) {
      assert.equal(error(await call(peer, method, {})), -32601);
    }
  }
  assert.equal(await metadata(f), before);
  await noExecution(f);
});

test("new Pi requests have matching bounded scalar, cursor and intent rejection on both routes", { timeout: 20000 }, async t => {
  const f = await daemonFixture(t); const inputs = methodInputs(f);
  const history = inputs["axo.chat.history"];
  const cursor = { target: history.target, readMode: "live", leafId: "leaf", after: "entry" };
  const cases = [
    ["axo.chat.history", { ...history, cursor: null }],
    ["axo.chat.history", { ...history, readMode: null }],
    ["axo.chat.history", { ...history, cursor: { ...cursor, after: "界".repeat(43) } }],
    ["axo.chat.history", { ...history, cursor: { ...cursor, after: "bad\nidentity" } }],
    ["axo.chat.getToolOutput", { ...inputs["axo.chat.getToolOutput"], toolCallId: "" }],
    ["axo.chat.getToolOutput", { ...inputs["axo.chat.getToolOutput"], offset: Number.MAX_SAFE_INTEGER + 1 }],
    ...["\u0085", " /model", "\u0085/cmd", "x".repeat(48*1024+1)].map(text => ["axo.chat.sendMessage", { ...inputs["axo.chat.sendMessage"], text }]),
  ] as const;
  const before = await metadata(f);
  for (const { peer } of f.routes) for (const [method, params] of cases) assert.equal(error(await call(peer, method as string, params)), -32602);
  assert.equal(await metadata(f), before); await noExecution(f);
});

test("local-only shell-pane methods reject malformed targets and cannot be invoked through cloud routing", { timeout: 20000 }, async t => {
  const f = await daemonFixture(t);
  const inputs = {
    "axo.session.pane.add": { target: f.sessionTarget, commandId: crypto.randomUUID(), profileId: "approved" },
    "axo.session.pane.remove": { target: f.sessionTarget, commandId: crypto.randomUUID(), paneId: crypto.randomUUID(), runtime: null },
  } satisfies { [Method in keyof typeof paneMethods]: z.input<(typeof paneMethods)[Method]> };
  const before = await metadata(f);
  for (const { name, peer } of f.routes) {
    for (const [method, params] of Object.entries(inputs)) {
      if (name === "cloud") { assert.equal(error(await call(peer, method, params)), -32601); continue; }
      for (const bad of [[], {}, { ...params, direction: "right" }, { ...params, target: { ...params.target, machineId: "bad" } }]) assert.equal(error(await call(peer, method, bad)), -32602);
      for (const field of ["machineId", "hostGeneration"] as const) assert.equal(error(await call(peer, method, { ...params, target: { ...params.target, [field]: crypto.randomUUID() } })), -32002);
      peer.send({ jsonrpc: "2.0", method, params });
      await call(peer, "axo.command.get", { target: f.target, commandId: f.workspaceCommandId });
    }
  }
  assert.equal(await metadata(f), before); await noExecution(f);
});

test("optional paging inputs have identical absent-versus-null semantics on both routes", { timeout: 20000 }, async t => {
  const f = await daemonFixture(t);
  for (const { name, peer } of f.routes) {
    await t.test(name, async () => {
      for (const [method, field] of [
        ["axo.workspace.list", "cursor"],
        ["axo.session.list", "cursor"],
        ["axo.session.list", "workspaceId"],
        ["axo.runtime.list", "after"],
      ] as const) {
        assert.equal(error(await call(peer, method, { target: f.target, [field]: null })), -32602);
        const absent = value(await call(peer, method, { target: f.target }));
        const explicitDefault = value(await call(peer, method, { target: f.target, limit: 50 }));
        assert.deepEqual(absent, explicitDefault);
      }
    });
  }
  await noExecution(f);
});

test("nullable all-workspace cursor scope remains valid rather than being over-rejected", { timeout: 20000 }, async t => {
  const f = await daemonFixture(t);
  value(await call(f.local, "axo.session.create", {
    target: f.workspaceTarget, commandId: crypto.randomUUID(), expectedRevision: 2, name: "Second session",
  }));
  const first = results["axo.session.list"].parse(value(await call(f.local, "axo.session.list", { target: f.target, limit: 1 })));
  assert.ok(first.next);
  assert.equal(first.next.scope.workspaceId, null);
  const pages = [];
  for (const { peer } of f.routes) {
    const page = results["axo.session.list"].parse(value(await call(peer, "axo.session.list", {
      target: f.target, limit: 1, cursor: first.next,
    })));
    assert.equal(page.sessions.length, 1);
    assert.equal(page.next, null);
    assert.notEqual(page.sessions[0].sessionId, first.sessions[0].sessionId);
    pages.push(page);
  }
  assert.deepEqual(pages[0], pages[1]);
  await noExecution(f);
});

test("the RFD's unimplemented operations fail explicitly rather than pretending Pi/tool parity", { timeout: 20000 }, async t => {
  const f = await daemonFixture(t);
  const document = await readFile(join(root, "docs/rfds/RFD0009-protocol-capability-parity.md"), "utf8");
  const catalogue = document.split("### Proposed canonical naming catalogue")[1].split("Domain choices and light contracts:")[0];
  const names = [...catalogue.matchAll(/^\| `(axo\.[A-Za-z_.]+)` \|/gm)].map(match => match[1]);
  assert.equal(new Set(names).size, names.length);
  const available = new Set<string>([...METHODS, ...Object.keys(paneMethods), "axo.machine.list"]);
  const unsupported = names.filter(method => !available.has(method));
  assert.ok(unsupported.includes("axo.session.archive"));
  assert.ok(!unsupported.includes("axo.session.start"));
  assert.ok(!unsupported.includes("axo.chat.sendMessage"));
  assert.ok(!unsupported.includes("axo.chat.answerQuestion"));
  const before = await metadata(f);
  for (const { name, peer } of f.routes) {
    await t.test(name, async () => {
      for (const method of unsupported) {
        assert.equal(error(await call(peer, method, { target: f.target })), -32601, method);
      }
      for (const legacy of ["prompt", "answer", "cancel", "tool_output", "tool.execute"]) {
        assert.equal(error(await call(peer, legacy, { target: f.target })), -32601, legacy);
      }
    });
  }
  assert.equal(await metadata(f), before);
  await noExecution(f);
});

test("concurrent clients reconcile commands, not colliding hop IDs or stale revisions", { timeout: 20000 }, async t => {
  const f = await daemonFixture(t);
  const create = {
    target: f.target, commandId: crypto.randomUUID(), expectedRevision: 2,
    directoryId: "approved", name: "Exactly one committed workspace",
  };
  const same = await Promise.all(f.routes.map(({ peer }) => call(peer, "axo.workspace.create", create, "shared-hop-id")));
  const commits = same.map(reply => results["axo.workspace.create"].parse(value(reply)));
  assert.deepEqual(commits[0], commits[1]);
  assert.equal(commits[0].revision, 3);
  const race = ["Candidate A", "Candidate B"].map(name => ({
    ...create, commandId: crypto.randomUUID(), expectedRevision: 3, name,
  }));
  const competing = await Promise.all(f.routes.map(({ peer }, i) => call(peer, "axo.workspace.create", race[i], "same-hop-again")));
  const winner = competing.findIndex(reply => "result" in reply);
  assert.ok(winner === 0 || winner === 1);
  assert.equal(error(competing[1 - winner]), -32007);
  const winning = results["axo.workspace.create"].parse(value(competing[winner]));
  assert.equal(winning.revision, 4);
  const conflicting = await Promise.all(f.routes.map(({ peer }, i) => call(peer, "axo.workspace.create", {
    ...create, commandId: race[winner].commandId, name: i === 0 ? race[winner].name : "Changed intent",
    expectedRevision: 3,
  })));
  assert.deepEqual(value(conflicting[0]), winning);
  assert.equal(error(conflicting[1]), -32007);
  for (const { peer } of f.routes) {
    const page = results["axo.workspace.list"].parse(value(await call(peer, "axo.workspace.list", { target: f.target })));
    assert.equal(page.revision, 4);
    assert.equal(page.workspaces.length, 3);
    const missing = results["axo.command.get"].parse(value(await call(peer, "axo.command.get", {
      target: f.target, commandId: race[1 - winner].commandId,
    })));
    assert.equal(missing.receipt, null);
  }
  await noExecution(f);
});

for (const firstRoute of ["local", "cloud"] as const) {
  test(`${firstRoute} uncertain metadata persistence fences every mutation without stopping reads`, { timeout: 20000 }, async t => {
    const f = await daemonFixture(t);
    const original = await metadata(f);
    const path = join(f.directory, "work-records.json");
    await rename(path, join(f.directory, "original-records.json"));
    await mkdir(path); // Owned fixture only: force atomic rename failure after admission.
    const commandId = crypto.randomUUID();
    const attempted = await call(f[firstRoute], "axo.workspace.create", {
      target: f.target, commandId, expectedRevision: 2, directoryId: "approved", name: "Uncertain write",
    });
    assert.equal(error(attempted), -32004);
    assert.ok(Buffer.byteLength(JSON.stringify(attempted)) < 65536);
    const inputs = methodInputs(f);
    for (const { peer } of f.routes) {
      for (const method of [...workMutationMethods, "axo.runtime.startApproved"] as const) {
        assert.equal(error(await call(peer, method, { ...inputs[method], commandId: crypto.randomUUID() })), -32008);
      }
      const page = results["axo.workspace.list"].parse(value(await call(peer, "axo.workspace.list", { target: f.target })));
      assert.equal(page.revision, 2);
      assert.equal(page.workspaces.length, 1);
      const receipt = results["axo.command.get"].parse(value(await call(peer, "axo.command.get", { target: f.target, commandId })));
      assert.equal(receipt.receipt, null); // Unknown knowledge, never permission to replay this mutation.
      const known = results["axo.command.get"].parse(value(await call(peer, "axo.command.get", {
        target: f.target, commandId: f.workspaceCommandId,
      })));
      assert.equal(known.receipt?.kind, "work");
    }
    assert.equal(await readFile(join(f.directory, "original-records.json"), "utf8"), original);
    await noExecution(f);
  });
}

test("maximum Unicode session pages and explicit null-ID mutations work over both routes", { timeout: 20000 }, async t => {
  const f = await daemonFixture(t);
  let revision = 2;
  for (const { peer } of f.routes) {
    const intent = { target: f.target, commandId: crypto.randomUUID(), expectedRevision: revision, directoryId: "approved", name: "Null-ID request" };
    peer.send({ jsonrpc: "2.0", id: null, method: "axo.workspace.create", params: intent });
    const raw = replySchema.parse(await peer.next());
    assert.equal(raw.id, null);
    const created = results["axo.workspace.create"].parse(value(raw));
    assert.equal(created.revision, ++revision);
    const receipt = results["axo.command.get"].parse(value(await call(peer, "axo.command.get", { target: f.target, commandId: intent.commandId })));
    assert.equal(receipt.receipt?.kind, "work");
  }
  for (let i = 0; i < 49; i++) {
    const created = results["axo.session.create"].parse(value(await call(f.local, "axo.session.create", {
      target: f.workspaceTarget, commandId: crypto.randomUUID(), expectedRevision: revision,
      name: "😃".repeat(80),
    })));
    assert.equal(created.revision, ++revision);
  }
  const pages = [];
  for (const { peer } of f.routes) {
    const reply = await call(peer, "axo.session.list", { target: f.target, workspaceId: f.workspaceTarget.workspaceId, limit: 50 });
    assert.ok(Buffer.byteLength(JSON.stringify(reply)) <= 65536);
    const page = results["axo.session.list"].parse(value(reply));
    assert.equal(page.sessions.length, 50);
    assert.equal(page.next, null);
    assert.ok(page.sessions.every(session => session.pi.chatId === null && session.runtime === null));
    pages.push(page);
  }
  assert.deepEqual(pages[0], pages[1]);
  await noExecution(f);
});

test("hardening corpus has identical dispositions on real local and cloud sockets", { timeout: 25000 }, async t => {
  const f = await daemonFixture(t);
  const before = await metadata(f);
  for (const { peer } of f.routes) {
    const uuid = f.workspaceCommandId;
    for (const commandId of [uuid.replaceAll("-", ""), `{${uuid}}`, `urn:uuid:${uuid}`]) {
      assert.equal(error(await call(peer, "axo.command.get", { target: f.target, commandId })), -32602);
    }
    const upper = results["axo.command.get"].parse(value(await call(peer, "axo.command.get", {
      target: { machineId: f.target.machineId.toUpperCase(), hostGeneration: f.target.hostGeneration.toUpperCase() },
      commandId: uuid.toUpperCase(),
    })));
    assert.equal(upper.receipt?.kind, "work");
    for (const method of ["axo.workspace.list", "axo.session.list"] as const) {
      const scope = method === "axo.workspace.list" ? { kind: "sessions", workspaceId: null } : { kind: "workspaces" };
      assert.equal(error(await call(peer, method, { target: f.target, cursor: {
        target: f.target, revision: 2, after: f.workspaceTarget.workspaceId, scope,
      } })), -32602);
    }
    for (const [index, number] of ["1.0", "1e0", "0.1e1"].entries()) {
      await new Promise(resolve => setTimeout(resolve, 75));
      peer.send(`{"jsonrpc":"2.0","id":"numeric-${index}","method":"axo.workspace.list","params":{"target":${JSON.stringify(f.target)},"limit":${number}}}`);
      const reply = replySchema.parse(await peer.next());
      assert.equal(reply.id, `numeric-${index}`);
      assert.equal(results["axo.workspace.list"].parse(value(reply)).workspaces.length, 1);
    }
    for (const raw of [
      JSON.stringify({ jsonrpc: "2.0", id: "😃".repeat(65), method: "axo.workspace.list", params: { target: f.target } }),
      JSON.stringify({ jsonrpc: "2.0", id: 1, method: "😃".repeat(65) }),
    ]) {
      await new Promise(resolve => setTimeout(resolve, 75));
      peer.send(raw);
      assert.equal(error(replySchema.parse(await peer.next())), -32600);
    }
    for (const raw of [
      '{"jsonrpc":"2.0","id":1e309,"method":"axo.workspace.list"}',
      '{"jsonrpc":"2.0","id":1,"method":"\\ud800"}',
      "[".repeat(128) + "0" + "]".repeat(128),
    ]) {
      await new Promise(resolve => setTimeout(resolve, 75));
      peer.send(raw);
      assert.equal(error(replySchema.parse(await peer.next())), -32700);
    }
  }
  assert.equal(await metadata(f), before);
  await noExecution(f);
});
