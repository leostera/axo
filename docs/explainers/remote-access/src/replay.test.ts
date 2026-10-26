import assert from "node:assert/strict";
import { test } from "node:test";
import { replay, perform } from "./replay";
import { encodeRun, loadHash } from "./share";
import { advance, clientById, presets, type Sim } from "./sim";

const preset = (id: string) => presets.find((p) => p.id === id)!.build();

/** Plays like the animation loop: 16 ms frames, at most 50 events per frame. */
function live(start: Sim, script: ((s: Sim) => Sim)[], framesBetween: number): Sim {
  let sim = start;
  const frames = (n: number) => {
    for (let i = 0; i < n; i++) sim = advance(sim, sim.now + 16.7, 50).sim;
  };
  for (const step of script) {
    frames(framesBetween);
    sim = step(sim);
  }
  frames(framesBetween);
  return sim;
}

const aliceSession = (s: Sim) => perform(s, { t: "signIn", client: s.clients[0]!.id, person: s.people[0]!.id });
const pairCode = (s: Sim) => perform(s, { t: "createCode", client: s.clients[0]!.id });
const linkMac = (s: Sim) =>
  perform(s, { t: "link", mac: s.macs[0]!.id, code: clientById(s, s.clients[0]!.id).codes.at(-1)!.code });
const wifiOff = (s: Sim) => perform(s, { t: "setNetwork", mac: s.macs[0]!.id, online: false });
const twice = (s: Sim) => perform(perform(s, { t: "addPerson", name: "Carol" }), { t: "addMac", name: "MacBook" });
const tenMinutes = (s: Sim) => perform(s, { t: "skip", by: 600_000 });

test("replaying the recorded inputs reproduces a live run exactly", () => {
  const script = [aliceSession, pairCode, linkMac, twice, wifiOff, tenMinutes];
  const run = live(preset("fresh"), script, 240);
  assert.equal(run.inputs.length, script.length + 1); // `twice` is two inputs
  const again = replay(preset("fresh"), run.inputs, run.now);
  assert.equal(JSON.stringify(again.sim), JSON.stringify(run));
});

test("two inputs at the same instant keep their order", () => {
  const run = twice(preset("fresh"));
  assert.equal(run.inputs[0]!.at, run.inputs[1]!.at);
  const again = replay(preset("fresh"), run.inputs, run.now);
  assert.deepEqual(again.sim.people.map((p) => p.name), ["Alice", "Bob", "Carol"]);
  assert.deepEqual(again.sim.macs.map((m) => m.name), ["Studio", "MacBook"]);
});

test("a replayed run can be rewound: every event has a snapshot before it", () => {
  const run = live(preset("fresh"), [aliceSession, pairCode, linkMac], 240);
  const again = replay(preset("fresh"), run.inputs, run.now);
  // The timeline shows an event by the first snapshot at or after its time.
  const lastSnapshot = again.history.at(-1)!.now;
  const events = again.sim.log.filter((e) => e.tone !== "action" && e.at <= lastSnapshot);
  assert.ok(events.length > 5);
  for (const entry of events) {
    assert.ok(again.history.some((h) => h.now >= entry.at), `snapshot for ${entry.title}`);
  }
  // Rolling back to a snapshot leaves a consistent input log: replaying it reaches that snapshot.
  const past = again.history[Math.floor(again.history.length / 2)]!;
  assert.equal(JSON.stringify(replay(preset("fresh"), past.inputs, past.now).sim), JSON.stringify(past));
});

test("a URL round-trips, and garbage falls back to the preset", () => {
  const run = live(preset("fresh"), [aliceSession, pairCode], 240);
  const hash = `#play/fresh/r=${encodeRun(run)}`;
  const loaded = loadHash(hash).shared!;
  assert.equal(JSON.stringify(loaded.sim), JSON.stringify(run));
  assert.ok(loaded.history.length > 0);
  assert.equal(hash.length < 600, true, `url is ${hash.length} chars`);
  for (const bad of ["#play/fresh/r=%%%", "#play/fresh/r=N4Ig", "#play/nope/r=" + encodeRun(run), "#play/fresh", ""]) {
    assert.equal(loadHash(bad).shared, null, bad);
  }
});

test("an input that no longer applies is rejected, not half-applied", () => {
  const forged: Sim = { ...preset("fresh"), now: 5, inputs: [{ at: 1, command: { t: "signIn", client: "ghost", person: "p1" } }] };
  const hash = `#play/fresh/r=${encodeRun(forged)}`;
  assert.equal(loadHash(hash).shared, null);
});

test("you can rewind to just before any of your inputs", () => {
  const run = live(preset("fresh"), [aliceSession, pairCode, linkMac], 240);
  const again = replay(preset("fresh"), run.inputs, run.now);
  run.inputs.forEach((input, i) => {
    assert.ok(again.history.some((h) => h.inputs.length === i && h.now === input.at), `before input ${i}`);
  });
});
