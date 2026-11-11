import assert from "node:assert/strict";
import { createServer, type Server } from "node:net";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { BRIEF_SECTION, fetchBriefFromAxod, installAxoBrief, parseBrief, type FetchBrief } from "../src/brief.js";

type Handler = (event?: any) => unknown;

function fakePi() {
  const listeners = new Map<string, Handler[]>();
  const pi = {
    on(event: string, handler: Handler) {
      listeners.set(event, [...(listeners.get(event) ?? []), handler]);
      return () => {};
    },
  } as unknown as ExtensionAPI;
  const emit = async (event: string, payload?: unknown) => {
    for (const handler of listeners.get(event) ?? []) await handler(payload);
  };
  /** Starts a run as Pi does, and answers the prompt sections it ends with. */
  const startRun = async () => {
    const event = { messageType: "user", prompt: "hi", systemPromptOptions: { sections: {} as Record<string, string> } };
    await emit("before_agent_start", event);
    return event.systemPromptOptions.sections;
  };
  return { pi, emit, startRun };
}

/** Answers each fetch with the next of `answers`; an `Error` is thrown. */
function answering(...answers: unknown[]): FetchBrief & { calls: number } {
  const fetch = (async () => {
    fetch.calls += 1;
    const answer = answers[Math.min(fetch.calls - 1, answers.length - 1)];
    if (answer instanceof Error) throw answer;
    return answer;
  }) as FetchBrief & { calls: number };
  fetch.calls = 0;
  return fetch;
}

test("a brief is axod's text, and nothing else is", () => {
  assert.equal(parseBrief({ brief: "  You run inside Axo.\n- Sessions  " }), "You run inside Axo.\n- Sessions");
  assert.equal(parseBrief({ brief: "" }), null);
  assert.equal(parseBrief({ brief: 3 }), null);
  assert.equal(parseBrief("You run inside Axo."), null);
  assert.equal(parseBrief(null), null);
  assert.equal(parseBrief({ brief: "x".repeat(8_001) }), null);
});

test("the first turn waits for the brief and has it in the system prompt", async () => {
  const { pi, emit, startRun } = fakePi();
  let release!: (answer: unknown) => void;
  installAxoBrief(pi, () => new Promise(resolve => { release = resolve; }));
  await emit("session_start");
  const run = startRun();
  release({ brief: "You run inside Axo." });
  assert.deepEqual(await run, { [BRIEF_SECTION]: "You run inside Axo." });
});

test("the brief is asked for again after each turn, and the next turn has the new one", async () => {
  const { pi, emit, startRun } = fakePi();
  const fetch = answering({ brief: "before" }, { brief: "after: apps.gmail (a@x.test)" });
  installAxoBrief(pi, fetch);
  await emit("session_start");
  assert.equal((await startRun())[BRIEF_SECTION], "before");
  await emit("agent_settled");
  await new Promise(resolve => setImmediate(resolve));
  assert.equal((await startRun())[BRIEF_SECTION], "after: apps.gmail (a@x.test)");
  assert.equal(fetch.calls, 2);
});

test("a failed refresh keeps the last brief, and every run has it", async () => {
  const { pi, emit, startRun } = fakePi();
  installAxoBrief(pi, answering({ brief: "kept" }, new Error("Axo did not answer within 5 seconds"), { brief: 7 }));
  const errors: string[] = [];
  const original = console.error;
  console.error = (message: string) => errors.push(message);
  try {
    await emit("session_start");
    assert.equal((await startRun())[BRIEF_SECTION], "kept");
    for (let turn = 0; turn < 2; turn += 1) {
      await emit("agent_settled");
      await new Promise(resolve => setImmediate(resolve));
      assert.equal((await startRun())[BRIEF_SECTION], "kept");
    }
  } finally {
    console.error = original;
  }
  // Two failures in a row are reported once.
  assert.equal(errors.length, 1);
  assert.match(errors[0]!, /Axo brief unavailable: Axo did not answer/u);
});

test("without any brief the prompt has no axo section, and the turn is not held up", async () => {
  const { pi, emit, startRun } = fakePi();
  const original = console.error;
  console.error = () => {};
  try {
    installAxoBrief(pi, answering(new Error("Method not found")));
    await emit("session_start");
    assert.deepEqual(await startRun(), {});
  } finally {
    console.error = original;
  }
});

test("a fetch already under way is shared, not repeated", async () => {
  const { pi, emit, startRun } = fakePi();
  const fetch = answering({ brief: "once" });
  installAxoBrief(pi, fetch);
  await emit("session_start");
  await emit("agent_settled");
  await startRun();
  assert.equal(fetch.calls, 1);
});

test("asks axod over its socket for this Session's brief", async () => {
  const directory = mkdtempSync(join(tmpdir(), "axo-brief-"));
  const socket = join(directory, "s");
  const requests: unknown[] = [];
  const server: Server = createServer(connection => {
    connection.on("data", chunk => {
      const request = JSON.parse(chunk.toString("utf8").trim()) as { id: number };
      requests.push(request);
      connection.write(`${JSON.stringify({ jsonrpc: "2.0", id: request.id, result: { brief: "You run inside Axo." } })}\n`);
    });
  });
  await new Promise<void>(resolve => server.listen(socket, resolve));
  try {
    const sessionId = "82cfd1e8-1cc6-4473-a16d-6f0e77476311";
    const answer = await fetchBriefFromAxod({ axod: "/bin/axod", socket, sessionId })();
    assert.deepEqual(answer, { brief: "You run inside Axo." });
    assert.deepEqual(requests, [{ jsonrpc: "2.0", id: 1, method: "axo.session.brief", params: { sessionId } }]);
  } finally {
    await new Promise(resolve => server.close(resolve));
    rmSync(directory, { recursive: true, force: true });
  }
});
