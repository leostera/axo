import assert from "node:assert/strict";
import test from "node:test";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import { MAX_HELD_PROMPTS, RECEIPT_ENTRY, RemoteCommands, RUN_START_GRACE_MS, type CommandReceipt } from "../src/remote-commands.js";

const first = "6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b";
const second = "0a1b2c3d-4e5f-4a6b-8c7d-8e9f0a1b2c3d";

/** A Pi whose log, idleness and clock the test drives; what pi-axo did is in `log` and `aborts`. */
function fakePi(entries: SessionEntry[] = []) {
  const pi = {
    idle: true,
    clock: 0,
    aborts: 0,
    log: entries,
    /** Prompts handed to Pi whose run has not written them yet. */
    asked: [] as string[],
    isIdle: () => pi.idle,
    entries: () => pi.log,
    appendReceipt: (receipt: CommandReceipt) => {
      pi.log.push({ type: "custom", customType: RECEIPT_ENTRY, data: receipt, id: `r${pi.log.length}`, parentId: null, timestamp: "" } as SessionEntry);
    },
    prompt: (text: string): "run" | "command" => {
      if (text.startsWith("/axo-")) return "command";
      pi.asked.push(text);
      return "run";
    },
    abort: () => {
      pi.aborts += 1;
    },
    now: () => pi.clock,
  };
  return pi;
}

/** What the log says, in order: receipts by commandId, user messages by text. */
function written(pi: ReturnType<typeof fakePi>): string[] {
  return pi.log.map(entry => {
    if (entry.type === "custom") return `receipt ${(entry.data as CommandReceipt).commandId}`;
    if (entry.type === "message" && entry.message.role === "user") return `user ${String(entry.message.content)}`;
    return entry.type;
  });
}

/** Pi runs the prompt it was given: the run starts, then Pi writes its user message. */
function runStarts(pi: ReturnType<typeof fakePi>, remote: RemoteCommands) {
  pi.idle = false;
  remote.runStarted();
  const text = pi.asked.shift()!;
  pi.log.push({ type: "message", id: `u${pi.log.length}`, parentId: null, timestamp: "", message: { role: "user", content: text, timestamp: 0 } } as SessionEntry);
}

function runEnds(pi: ReturnType<typeof fakePi>, remote: RemoteCommands) {
  pi.idle = true;
  remote.settled();
}

test("an idle Pi writes the receipt, then the prompt", () => {
  const pi = fakePi();
  const remote = new RemoteCommands(pi);
  assert.equal(remote.prompt(first, "yes"), "taken");
  runStarts(pi, remote);
  assert.deepEqual(written(pi), [`receipt ${first}`, "user yes"]);
});

test("a commandId seen before prompts nothing, in this Pi or from the log", () => {
  const pi = fakePi();
  const remote = new RemoteCommands(pi);
  remote.prompt(first, "yes");
  runStarts(pi, remote);
  runEnds(pi, remote);
  assert.equal(remote.prompt(first, "yes"), "taken");
  assert.deepEqual(written(pi), [`receipt ${first}`, "user yes"]);

  // A Pi that restarts learns the commands from the receipts in its log.
  const restarted = new RemoteCommands(fakePi(pi.log));
  restarted.restore();
  assert.equal(restarted.prompt(first, "yes"), "taken");
  assert.equal(pi.log.length, 2);
});

test("a prompt during a turn is held, survives a stop, and starts the next turn", () => {
  const pi = fakePi();
  const remote = new RemoteCommands(pi);
  remote.prompt(first, "one");
  runStarts(pi, remote);
  assert.equal(remote.prompt(second, "two"), "held");
  assert.deepEqual(written(pi), [`receipt ${first}`, "user one"]);

  const turn = pi.log[1]!.id;
  assert.equal(remote.stop(turn), "stopped");
  assert.equal(pi.aborts, 1);
  runEnds(pi, remote);
  runStarts(pi, remote);
  assert.deepEqual(written(pi), [`receipt ${first}`, "user one", `receipt ${second}`, "user two"]);
  assert.equal(remote.heldCount, 0);
});

test("a stop names its turn: another turn, or none, is left alone", () => {
  const pi = fakePi();
  const remote = new RemoteCommands(pi);
  assert.equal(remote.stop("u0"), "ignored", "nothing runs");

  remote.prompt(first, "one");
  runStarts(pi, remote);
  const oldTurn = pi.log[1]!.id;
  runEnds(pi, remote);

  remote.prompt(second, "two");
  runStarts(pi, remote);
  assert.equal(remote.stop(oldTurn), "ignored", "the turn it named has ended");
  assert.equal(pi.aborts, 0);
  assert.equal(remote.stop(pi.log.at(-1)!.id), "stopped");
  assert.equal(pi.aborts, 1);
});

test("a prompt handed to Pi holds up the next until its run starts", () => {
  const pi = fakePi();
  const remote = new RemoteCommands(pi);
  remote.prompt(first, "one");
  // Pi still reads as idle: its run has not started yet.
  assert.equal(remote.prompt(second, "two"), "held");
  assert.deepEqual(written(pi), [`receipt ${first}`]);
  assert.deepEqual(pi.asked, ["one"]);

  // A delivery whose run never started stops holding up the next one after a while.
  pi.clock = RUN_START_GRACE_MS;
  const third = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d";
  remote.prompt(third, "three");
  assert.deepEqual(written(pi), [`receipt ${first}`, `receipt ${second}`]);
  assert.deepEqual(pi.asked, ["one", "two"]);
  assert.equal(remote.heldCount, 1);
});

test("a full queue refuses as busy and forgets nothing it took", () => {
  const pi = fakePi();
  const remote = new RemoteCommands(pi);
  pi.idle = false;
  for (let i = 0; i < MAX_HELD_PROMPTS; i++) {
    assert.equal(remote.prompt(`00000000-0000-4000-8000-${String(i).padStart(12, "0")}`, `p${i}`), "held");
  }
  assert.equal(remote.prompt(first, "one more"), "busy");
  // Refused, so not seen: the client may send it again later.
  runEnds(pi, remote);
  assert.equal(remote.prompt(first, "one more"), "held");
});

test("an extension command runs without a turn and does not hold up the prompts behind it", () => {
  const pi = fakePi();
  const remote = new RemoteCommands(pi);
  pi.idle = false;
  remote.runStarted();
  assert.equal(remote.prompt(first, "/axo-share"), "held");
  assert.equal(remote.prompt(second, "and then this"), "held");
  runEnds(pi, remote);
  // The command ran; the next prompt went to Pi at once, not after the run-start grace.
  assert.deepEqual(written(pi), [`receipt ${first}`, `receipt ${second}`]);
  assert.deepEqual(pi.asked, ["and then this"]);
  assert.equal(remote.heldCount, 0);
});
