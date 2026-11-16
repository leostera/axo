import { atMost, defineActor, defineProperty, defineSpec, defineZone } from "@leostera/feynman";
const zone = defineZone({ name: "Session", place: { column: 0 } });
// Normal Send, not explicit Stop. No external-side-effect or crash proof.
const Turn = defineActor({
  name: "Human interaction has priority", singleton: true, zone,
  initialState: () => ({ pending: false, protected: false, answering: false, accepted: false, badAbort: false, queued: 0 }),
  actions: {
    ask: {
      label: "Publish question", description: "Protect the run before clients see the request.", with: [atMost(1)],
      run(s) { s.pending = true; s.protected = true; },
    },
    yes: {
      label: "Tap Yes", description: "The answer is in flight, not proof that the action finished.", with: [atMost(1)],
      run(s) { if (s.pending) s.answering = true; },
    },
    acknowledged: {
      label: "Acknowledge Yes", description: "The approved action may still be running.", with: [atMost(1)],
      run(s) { if (s.pending && s.answering) { s.accepted = true; s.pending = false; s.answering = false; } },
    },
    send: {
      label: "Send from any device", description: "Queue behind a protected run rather than abort its tool.", with: [atMost(2)],
      run(s) {
        const interrupt = !s.protected && !s.pending;
        if (interrupt) s.badAbort ||= s.pending || s.answering;
        else s.queued++;
      },
    },
    settled: {
      label: "Run settles", description: "Release only after no question is left pending.", with: [atMost(1)],
      run(s) { if (!s.pending) s.protected = false; },
    },
  },
});
export default defineSpec({
  name: "Answer then Send ordering",
  actors: [Turn],
  properties: [
    defineProperty("sendCannotCancelAnswer", { description: "A normal Send never aborts an in-flight human interaction.",
      always: w => !w.the(Turn).state.badAbort }),
  ],
});
