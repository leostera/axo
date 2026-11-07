import assert from "node:assert/strict";
import test from "node:test";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import {
  MAX_HELD_PROMPTS,
  QUEUED_ENTRY,
  RECEIPT_ENTRY,
  RemoteCommands,
  RUN_START_GRACE_MS,
  type ClientPrompt,
  type CommandReceipt,
  type Delivery,
  type QueuedCommand,
} from "../src/remote-commands.js";

const first = "6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b";
const second = "0a1b2c3d-4e5f-4a6b-8c7d-8e9f0a1b2c3d";
const third = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d";

/** A Pi whose log, idleness and clock the test drives; what pi-axo did is in `log` and `aborts`. */
function fakePi(entries: SessionEntry[] = []) {
  const custom = (customType: string, data: unknown) => {
    pi.log.push({ type: "custom", customType, data, id: `c${pi.log.length}`, parentId: null, timestamp: "" } as SessionEntry);
  };
  const pi = {
    idle: true,
    clock: 0,
    aborts: 0,
    log: entries,
    /** Prompts handed to Pi as turns whose run has not written them yet. */
    asked: [] as string[],
    /** Steers handed to Pi that it has not taken yet. */
    steers: [] as string[],
    isIdle: () => pi.idle,
    entries: () => pi.log,
    appendReceipt: (receipt: CommandReceipt) => custom(RECEIPT_ENTRY, receipt),
    appendQueued: (command: QueuedCommand) => custom(QUEUED_ENTRY, command),
    prompt: (prompt: ClientPrompt, as: "turn" | "steer"): "run" | "command" => {
      if (prompt.text.startsWith("/axo-")) return "command";
      (as === "steer" ? pi.steers : pi.asked).push(prompt.text);
      return "run";
    },
    abort: () => {
      pi.aborts += 1;
    },
    now: () => pi.clock,
  };
  return pi;
}

type FakePi = ReturnType<typeof fakePi>;

function send(remote: RemoteCommands, commandId: string, text: string, delivery?: Delivery) {
  return remote.prompt(commandId, { text, attachments: [] }, delivery);
}

/** What the log says, in order: receipts and queued prompts by commandId, user messages by text. */
function written(pi: FakePi): string[] {
  return pi.log.map(entry => {
    if (entry.type === "custom" && entry.customType === RECEIPT_ENTRY) return `receipt ${(entry.data as CommandReceipt).commandId}`;
    if (entry.type === "custom" && entry.customType === QUEUED_ENTRY) {
      const queued = entry.data as QueuedCommand;
      return `queued ${queued.commandId} ${queued.delivery}`;
    }
    if (entry.type === "message" && entry.message.role === "user") return `user ${String(entry.message.content)}`;
    return entry.type;
  });
}

function writeUserMessage(pi: FakePi, remote: RemoteCommands, text: string) {
  remote.userMessageWritten();
  pi.log.push({ type: "message", id: `u${pi.log.length}`, parentId: null, timestamp: "", message: { role: "user", content: text, timestamp: 0 } } as SessionEntry);
}

/** Pi runs the prompt it was given: the run starts, then Pi writes its user message. */
function runStarts(pi: FakePi, remote: RemoteCommands) {
  pi.idle = false;
  remote.runStarted();
  writeUserMessage(pi, remote, pi.asked.shift()!);
}

/** A turn of the run ends and Pi goes on, taking any steer it was handed, as its loop does. */
function turnEnds(pi: FakePi, remote: RemoteCommands, stopped = false) {
  remote.turnEnded(stopped);
  if (stopped) return;
  for (const steer of pi.steers.splice(0)) writeUserMessage(pi, remote, steer);
}

function runEnds(pi: FakePi, remote: RemoteCommands) {
  pi.idle = true;
  remote.settled();
}

test("an idle Pi writes the receipt, then the prompt", () => {
  const pi = fakePi();
  const remote = new RemoteCommands(pi);
  assert.equal(send(remote, first, "yes"), "taken");
  runStarts(pi, remote);
  assert.deepEqual(written(pi), [`receipt ${first}`, "user yes"]);
});

test("a commandId seen before prompts nothing, in this Pi or from the log", () => {
  const pi = fakePi();
  const remote = new RemoteCommands(pi);
  send(remote, first, "yes");
  runStarts(pi, remote);
  runEnds(pi, remote);
  assert.equal(send(remote, first, "yes"), "taken");
  assert.deepEqual(written(pi), [`receipt ${first}`, "user yes"]);

  // A Pi that restarts learns the commands from the receipts in its log.
  const restarted = new RemoteCommands(fakePi(pi.log));
  restarted.restore();
  assert.equal(send(restarted, first, "yes"), "taken");
  assert.equal(pi.log.length, 2);
});

test("a prompt during a turn is written to the log before it is accepted, survives a stop, and starts the next turn", () => {
  const pi = fakePi();
  const remote = new RemoteCommands(pi);
  send(remote, first, "one");
  runStarts(pi, remote);
  assert.equal(send(remote, second, "two"), "held");
  assert.deepEqual(written(pi), [`receipt ${first}`, "user one", `queued ${second} followUp`], "in the log by the time it is answered");

  const turn = pi.log[1]!.id;
  assert.equal(remote.stop(turn), "stopped");
  assert.equal(pi.aborts, 1);
  runEnds(pi, remote);
  runStarts(pi, remote);
  assert.deepEqual(written(pi), [`receipt ${first}`, "user one", `queued ${second} followUp`, `receipt ${second}`, "user two"]);
  assert.equal(remote.heldCount, 0);
});

test("a Pi that exits with prompts queued delivers them when it starts again, once each", () => {
  const pi = fakePi();
  const remote = new RemoteCommands(pi);
  send(remote, first, "one");
  runStarts(pi, remote);
  send(remote, second, "two");
  send(remote, third, "three", "steer");
  // Pi exits (a crash, a restart) before either went to it.

  const restarted = fakePi(pi.log);
  const again = new RemoteCommands(restarted);
  again.restore();
  assert.equal(again.heldCount, 2);
  // A client that never heard back retries with the same commandId: it is already queued.
  assert.equal(send(again, second, "two"), "taken");
  again.resume();
  runStarts(restarted, again);
  runEnds(restarted, again);
  runStarts(restarted, again);
  runEnds(restarted, again);
  assert.deepEqual(written(restarted).slice(3), [
    `queued ${third} steer`,
    `receipt ${second}`, "user two",
    `receipt ${third}`, "user three",
  ]);

  // A third start finds everything delivered.
  const thirdStart = new RemoteCommands(fakePi(restarted.log));
  thirdStart.restore();
  assert.equal(thirdStart.heldCount, 0);
});

test("a steer joins the running turn at its end, its receipt just before its user message", () => {
  const pi = fakePi();
  const remote = new RemoteCommands(pi);
  send(remote, first, "one");
  runStarts(pi, remote);
  assert.equal(send(remote, second, "after this", "followUp"), "held");
  assert.equal(send(remote, third, "look here", "steer"), "held");
  turnEnds(pi, remote);
  assert.deepEqual(written(pi).slice(4), [`receipt ${third}`, "user look here"], "the steer went first, inside the run");
  runEnds(pi, remote);
  runStarts(pi, remote);
  assert.deepEqual(written(pi).slice(6), [`receipt ${second}`, "user after this"], "the follow-up waited for the run to end");
});

test("steers join one per turn end, so each receipt names its own message", () => {
  const pi = fakePi();
  const remote = new RemoteCommands(pi);
  send(remote, first, "one");
  runStarts(pi, remote);
  send(remote, second, "a", "steer");
  send(remote, third, "b", "steer");
  turnEnds(pi, remote);
  turnEnds(pi, remote);
  assert.deepEqual(written(pi).slice(4), [`receipt ${second}`, "user a", `receipt ${third}`, "user b"]);
});

test("a stopped turn takes no steer, and a steer the run never took starts the next turn", () => {
  const pi = fakePi();
  const remote = new RemoteCommands(pi);
  send(remote, first, "one");
  runStarts(pi, remote);
  send(remote, second, "steer me", "steer");
  turnEnds(pi, remote, true);
  assert.deepEqual(pi.steers, [], "nothing is handed to a stopping run");

  // Handed to Pi at a turn end, but the run stopped before Pi took it.
  send(remote, third, "and me", "steer");
  remote.turnEnded(false);
  assert.deepEqual(pi.steers, ["steer me"]);
  runEnds(pi, remote);
  runStarts(pi, remote);
  runEnds(pi, remote);
  runStarts(pi, remote);
  assert.deepEqual(written(pi).filter(line => line.startsWith("user")), ["user one", "user steer me", "user and me"]);
});

test("a steer to an idle Pi starts a turn at once", () => {
  const pi = fakePi();
  const remote = new RemoteCommands(pi);
  assert.equal(send(remote, first, "go", "steer"), "taken");
  runStarts(pi, remote);
  assert.deepEqual(written(pi), [`receipt ${first}`, "user go"]);
});

test("a stop names its turn: another turn, or none, is left alone", () => {
  const pi = fakePi();
  const remote = new RemoteCommands(pi);
  assert.equal(remote.stop("u0"), "ignored", "nothing runs");

  send(remote, first, "one");
  runStarts(pi, remote);
  const oldTurn = pi.log[1]!.id;
  runEnds(pi, remote);

  send(remote, second, "two");
  runStarts(pi, remote);
  assert.equal(remote.stop(oldTurn), "ignored", "the turn it named has ended");
  assert.equal(pi.aborts, 0);
  assert.equal(remote.stop(pi.log.at(-1)!.id), "stopped");
  assert.equal(pi.aborts, 1);
});

test("a prompt handed to Pi holds up the next until its run starts", () => {
  const pi = fakePi();
  const remote = new RemoteCommands(pi);
  send(remote, first, "one");
  // Pi still reads as idle: its run has not started yet.
  assert.equal(send(remote, second, "two"), "held");
  assert.deepEqual(written(pi), [`receipt ${first}`, `queued ${second} followUp`]);
  assert.deepEqual(pi.asked, ["one"]);

  // A delivery whose run never started stops holding up the next one after a while.
  pi.clock = RUN_START_GRACE_MS;
  send(remote, third, "three");
  assert.deepEqual(written(pi), [`receipt ${first}`, `queued ${second} followUp`, `queued ${third} followUp`, `receipt ${second}`]);
  assert.deepEqual(pi.asked, ["one", "two"]);
  assert.equal(remote.heldCount, 1);
});

test("a full queue refuses as busy and forgets nothing it took", () => {
  const pi = fakePi();
  const remote = new RemoteCommands(pi);
  pi.idle = false;
  for (let i = 0; i < MAX_HELD_PROMPTS; i++) {
    assert.equal(send(remote, `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`, `p${i}`), "held");
  }
  assert.equal(send(remote, first, "one more"), "busy");
  // Refused, so not seen and not written: the client may send it again later.
  assert.equal(pi.log.length, MAX_HELD_PROMPTS);
  runEnds(pi, remote);
  assert.equal(send(remote, first, "one more"), "held");
});

test("an extension command runs without a turn and does not hold up the prompts behind it", () => {
  const pi = fakePi();
  const remote = new RemoteCommands(pi);
  pi.idle = false;
  remote.runStarted();
  assert.equal(send(remote, first, "/axo-share"), "held");
  assert.equal(send(remote, second, "and then this"), "held");
  runEnds(pi, remote);
  // The command ran; the next prompt went to Pi at once, not after the run-start grace.
  assert.deepEqual(written(pi), [`queued ${first} followUp`, `queued ${second} followUp`, `receipt ${first}`, `receipt ${second}`]);
  assert.deepEqual(pi.asked, ["and then this"]);
  assert.equal(remote.heldCount, 0);
});
