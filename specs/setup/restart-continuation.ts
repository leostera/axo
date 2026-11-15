import { atMost, defineActor, defineProperty, defineSpec, defineZone } from "@leostera/feynman";

const zone = defineZone({ name: "axod", place: { column: 0 } });
// Logical admission model only: no claim of exactly-once delivery through crashes.
const Pi = defineActor({
  name: "Pi restart recovery",
  singleton: true,
  zone,
  initialState: () => ({ pending: true, superseded: false, connected: false, sent: 0, invalid: false }),
  actions: {
    userStop: {
      label: "Explicit stop intent",
      description: "Disarm before stop I/O; an uncertain receipt must not resurrect work.",
      with: [atMost(1)],
      run(s) {
        s.pending = false;
        s.superseded = true;
      },
    },
    realPrompt: {
      label: "New real prompt",
      description: "New work supersedes automatic recovery.",
      with: [atMost(1)],
      run(s) {
        s.pending = false;
        s.superseded = true;
      },
    },
    connect: {
      label: "Bridge ready or reconnected",
      description: "Consume intent before sending; reconnection cannot repeat it.",
      with: [atMost(3)],
      run(s) {
        s.connected = true;
        if (s.pending) {
          s.pending = false;
          s.sent++;
          s.invalid ||= s.superseded;
        }
      },
    },
    disconnect: {
      label: "Lost connection",
      description: "A lost receipt does not recreate consumed intent.",
      with: [atMost(2)],
      run(s) {
        s.connected = false;
      },
    },
  },
});
export default defineSpec({
  name: "Restart continuation admission",
  actors: [Pi],
  properties: [
    defineProperty("oneResumePerIntent", {
      description: "At most one automatic resume is sent per captured restart intent.",
      always: (w) => w.the(Pi).state.sent <= 1,
    }),
    defineProperty("newPromptWins", {
      description: "A new prompt or explicit stop prevents an automatic recovery that has not been claimed.",
      always: (w) => !w.the(Pi).state.invalid,
    }),
  ],
});
