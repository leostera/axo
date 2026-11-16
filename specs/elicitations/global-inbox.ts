import { atMost, defineActor, defineProperty, defineSpec, defineZone } from "@leostera/feynman";
const zone = defineZone({ name: "person clients", place: { column: 0 } });
// Presentation/fanout contract only. No APNs, OS delivery, filesystem or transport fault proof.
const Inbox = defineActor({
  name: "One request on three devices", singleton: true, zone,
  initialState: () => ({ pending: false, terminal: false, devices: [false, false, false], approvals: 0 }),
  actions: {
    request: {
      label: "Broadcast to every connected person", description: "Selected Sessions do not affect the inbox.", with: [atMost(1)],
      run(s) { if (!s.terminal) { s.pending = true; s.devices = [true, true, true]; } },
    },
    notificationClick: {
      label: "Open a device inbox", description: "A click presents requests and never approves.", with: [atMost(2)],
      run(_s) {},
    },
    answer: {
      label: "First explicit answer resolves everywhere", description: "Only this action represents the person's answer.", with: [atMost(2)],
      run(s) { if (s.pending) { s.approvals++; s.pending = false; s.terminal = true; s.devices = [false, false, false]; } },
    },
    expire: {
      label: "Expire without consent", description: "Nobody answering is never approval.", with: [atMost(1)],
      run(s) { s.pending = false; s.terminal = true; s.devices = [false, false, false]; },
    },
  },
});
export default defineSpec({
  name: "Global elicitation inbox",
  actors: [Inbox],
  properties: [
    defineProperty("allDevicesSeePending", { description: "No selected-chat filter hides a pending request.",
      always: w => !w.the(Inbox).state.pending || w.the(Inbox).state.devices.every(Boolean) }),
    defineProperty("settledClearsAll", { description: "A terminal request is absent on every device.",
      always: w => !w.the(Inbox).state.terminal || w.the(Inbox).state.devices.every(value => !value) }),
    defineProperty("firstAnswerWins", { description: "An explicit answer is admitted at most once.",
      always: w => w.the(Inbox).state.approvals <= 1 }),
  ],
});
