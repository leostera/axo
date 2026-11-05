import { atMost, budget, defineActor, defineLimit, defineMessage, defineProperty, defineScenario, defineSpec, defineZone, input, lose, oneOf } from "@leostera/feynman";

const SEC = 1_000;

// RFD0016 and RFD0018: a relay message larger than one 64 KiB frame travels as fragments, and is
// reassembled before anything parses it.
//
// One direction is modelled: a sender (axod uploading a transcript line or returning a bash
// result) and a receiver (the host's HostDO). There are no delivery credits (RFD0018, Flow
// control): the sender sends one frame at a time, and messages carry a priority class (replies and
// control first, then durable upload, then ephemeral progress). Fragments interleave across
// classes, so a large upload never holds back a reply, and messages go in order within a class,
// so at most one message per class is partly sent and the receiver's partial slots are never
// exceeded by an honest sender.
//
// Sizes are scaled down: a message is 1 or 3 fragments, two classes stand for three, and the
// receiver keeps at most 2 partial messages (4 in the code). A socket has an epoch; every frame
// carries it, so a partial message from a closed socket is never completed with frames from the
// next one. On the real WebSocket a lost frame means the socket died; here a lost frame is a
// fault, and the receiver's partial expiry is what frees its slot.

const MAX_PARTIAL = 2;
const MAX_FRAGMENTS = 3;

type Priority = "reply" | "upload";
type Frame = { epoch: number; message: string; index: number; count: number; priority: Priority };

/** Faults on one path: lost messages and crashes (RFD0012). `--set faults=2` raises it. */
const faults = budget("faults", 1);

const Fragment = defineMessage("Fragment", { epoch: Number, message: String, index: Number, count: Number, priority: oneOf("reply", "upload") }, { name: "axo.transport.fragment", over: "websocket" });
const Close = defineMessage("Close", { epoch: Number, reason: String }, { name: "close the socket", over: "websocket", tone: "refused" });
const Discard = defineMessage("Discard", { epoch: Number, message: String }, { name: "axo.transport.discard", over: "websocket" });

const mac = defineZone({ name: "Host Mac", description: "axod's relay sender" });
const cloud = defineZone({ name: "Cloudflare", description: "the HostDO that owns the socket", place: { column: 1 } });

const limit1 = defineLimit({ name: "Relay frame", value: 65_536, unit: "bytes" });
const limit2 = defineLimit({ name: "Reassembled message", value: 16 * 1_048_576, unit: "bytes" });
const limit3 = defineLimit({ name: "Partial messages per socket", value: 4, unit: "messages" });
const limit4 = defineLimit({ name: "A partial message with no new fragment for this long is dropped", value: 60 * SEC });

const order = (p: Priority) => (p === "reply" ? 0 : 1);

export const Sender = defineActor({
  name: "Sender",
  description: "axod's side of the relay socket: it queues messages by priority and sends one frame at a time.",
  zone: mac,
  singleton: true,
  initialState: () => ({
    epoch: 1,
    /** Frames waiting to go out, in order within each message. */
    queue: [] as Frame[],
    /** Messages whose first fragment went out and whose last has not. */
    started: [] as string[],
    abandoned: [] as string[],
    oversized: false,
    sent: 0,
  }),
  display: {
    icon: "terminal",
    status: (s) => `socket ${s.epoch}, ${s.queue.length} frame(s) queued`,
  },
  actions: {
    send: {
      with: [atMost(2)],
      label: "Send a message",
      description: "Queues a reply or an upload, of one frame or split into three.",
      inputs: {
        size: input(String, { examples: ["small", "large"] }),
        priority: input(String, { examples: ["reply", "upload"] }),
      },
      when: (s) => s.sent < 3,
      run(state, { size, priority }) {
        state.sent += 1;
        const message = `m${state.sent}`;
        const count = size === "large" ? 3 : 1;
        for (let index = 0; index < count; index++) state.queue.push({ epoch: state.epoch, message, index, count, priority: priority as Priority });
      },
    },
    sendOversized: {
      with: [atMost(1)],
      label: "Send a message that is too large",
      description: "A broken or hostile peer announces more fragments than a message may have.",
      when: (s) => s.sent < 3,
      run(state) {
        state.sent += 1;
        state.oversized = true;
        state.queue.push({ epoch: state.epoch, message: `m${state.sent}`, index: 0, count: MAX_FRAGMENTS + 1, priority: "reply" });
      },
    },
    abandon: {
      with: [atMost(1)],
      label: "Give up on a message part-way",
      description: "The sender drops a message it has started sending, and tells the receiver to drop its partial.",
      when: (s) => s.started.length > 0,
      sends: [Discard],
      run(state, _i, ctx) {
        const message = state.started.shift()!;
        state.queue = state.queue.filter((f) => f.message !== message);
        state.abandoned.push(message);
        ctx.send(ctx.the(Receiver), Discard, { epoch: state.epoch, message });
      },
    },
  },
  transitions: {
    transmit: {
      description: "Sends the next frame: from the highest class with anything queued, continuing the message that class started.",
      when: (s) => s.queue.length > 0,
      sends: [Fragment],
      run(state, _, ctx) {
        const best = Math.min(...state.queue.map((f) => order(f.priority)));
        const at = state.queue.findIndex((f) => order(f.priority) === best);
        const [frame] = state.queue.splice(at, 1);
        if (frame!.index === 0 && frame!.count > 1) state.started.push(frame!.message);
        if (frame!.index === frame!.count - 1) state.started = state.started.filter((m) => m !== frame!.message);
        ctx.send(ctx.the(Receiver), Fragment, frame!);
      },
    },
    close: {
      on: Close,
      description: "The receiver closed the socket; what was queued for it is dropped, and a new socket starts empty.",
      run(state, m) {
        if (m.epoch !== state.epoch) return;
        state.queue = [];
        state.started = [];
        state.epoch += 1;
      },
    },
    // Faults: what the network and restarts may do here.
    closeLost: lose(Close, { spend: faults }),
  },
});

export const Receiver = defineActor({
  name: "Receiver",
  description: "The HostDO: it keeps fragments and hands complete messages to the relay's parser.",
  zone: cloud,
  singleton: true,
  initialState: () => ({
    epoch: 1,
    /** Partial messages, kept in SQLite so hibernation loses nothing. */
    partial: {} as Record<string, { count: number; got: number[] }>,
    delivered: [] as { message: string; epoch: number; got: number[]; count: number }[],
    /** Messages dropped on this socket; a late fragment of one is ignored. */
    discarded: [] as string[],
    refused: 0,
  }),
  display: {
    icon: "cloud",
    status: (s) => `${Object.keys(s.partial).length} partial, ${s.delivered.length} delivered`,
    rows: (s) => s.delivered.map((d) => ({ group: "Delivered", label: d.message, detail: `${d.count} fragment(s), socket ${d.epoch}` })),
  },
  transitions: {
    fragment: {
      on: Fragment,
      description: "Keeps the frame; a message whose fragments are all here goes to the parser. A newer socket discards older partials; a message announcing too many fragments, or too many partials at once, closes the socket.",
      sends: [Close],
      starts: ["partialExpiry"],
      run(state, f, ctx) {
        if (f.epoch < state.epoch) return;
        if (f.epoch > state.epoch) {
          state.epoch = f.epoch;
          state.partial = {};
          state.discarded = [];
        }
        if (state.discarded.includes(f.message)) return;
        const known = state.partial[f.message];
        if (f.count > MAX_FRAGMENTS || f.index >= f.count || (known && known.count !== f.count) || (!known && f.count > 1 && Object.keys(state.partial).length >= MAX_PARTIAL)) {
          state.refused += 1;
          state.partial = {};
          // Nothing more from the closed socket is accepted.
          state.epoch = f.epoch + 1;
          ctx.reply(Close, { epoch: f.epoch, reason: "invalid fragment" });
          return;
        }
        const entry = (state.partial[f.message] ??= { count: f.count, got: [] });
        if (entry.got.includes(f.index)) return;
        entry.got.push(f.index);
        if (entry.got.length < entry.count) return void ctx.start("partialExpiry");
        delete state.partial[f.message];
        state.delivered.push({ message: f.message, epoch: f.epoch, got: [...entry.got].sort(), count: entry.count });
      },
    },
    partialExpiry: {
      description: "A partial message got no new fragment for a minute: its sender gave up, or a frame or discard notice was lost. It is dropped, and late fragments of it are ignored.",
      after: "60 seconds",
      run(state) {
        for (const message of Object.keys(state.partial)) {
          delete state.partial[message];
          if (!state.discarded.includes(message)) state.discarded.push(message);
        }
      },
    },
    discard: {
      on: Discard,
      description: "The sender gave up on a message; its partial is dropped, freeing its slot.",
      run(state, m) {
        if (m.epoch < state.epoch) return;
        delete state.partial[m.message];
        if (!state.discarded.includes(m.message)) state.discarded.push(m.message);
      },
    },
    // Faults: what the network and restarts may do here.
    fragmentLost: lose(Fragment, { spend: faults }),
    discardLost: lose(Discard, { spend: faults }),
  },
});

const deliveredWhole = defineProperty("deliveredWhole", {
  description: "The parser only ever sees a message with every one of its fragments, all from one socket.",
  always: (w) => w.the(Receiver).state.delivered.every((d) => d.got.length === d.count && d.got.every((i, n) => i === n)),
});
const deliveredOnce = defineProperty("deliveredOnce", {
  description: "A message reaches the parser at most once.",
  always: (w) => {
    const ids = w.the(Receiver).state.delivered.map((d) => d.message);
    return new Set(ids).size === ids.length;
  },
});
const abandonedNeverDelivered = defineProperty("abandonedNeverDelivered", {
  description: "A message the sender gave up on part-way never reaches the parser.",
  always: (w) => w.the(Sender).state.abandoned.every((m) => !w.the(Receiver).state.delivered.some((d) => d.message === m)),
});
const oneStartedPerClass = defineProperty("oneStartedPerClass", {
  description: "At most one message per priority class is partly sent, so an honest sender never needs more partial slots than there are classes.",
  always: (w) => {
    const s = w.the(Sender).state;
    const classOf = (m: string) => s.queue.find((f) => f.message === m)?.priority;
    return (["reply", "upload"] as const).every((p) => s.started.filter((m) => classOf(m) === p).length <= 1);
  },
});
const honestSendersAreNeverRefused = defineProperty("honestSendersAreNeverRefused", {
  description: "The receiver only closes the socket of a sender that broke the rules.",
  always: (w) => w.the(Receiver).state.refused === 0 || w.the(Sender).state.oversized,
});
const partialsBounded = defineProperty("partialsBounded", {
  description: "The receiver never holds more partial messages, or more fragments of one, than the limits allow.",
  always: (w) => {
    const p = w.the(Receiver).state.partial;
    return Object.keys(p).length <= MAX_PARTIAL && Object.values(p).every((e) => e.count <= MAX_FRAGMENTS);
  },
});
const partialsDrain = defineProperty("partialsDrain", {
  description: "A partial message on the receiver is in the end completed or dropped: it never holds a slot forever.",
  leadsTo: {
    whenever: (w) => Object.keys(w.the(Receiver).state.partial).length > 0,
    then: (w) => Object.keys(w.the(Receiver).state.partial).length === 0,
  },
});
const everythingQueuedGoesOut = defineProperty("everythingQueuedGoesOut", {
  description: "Everything queued is in the end sent, given up on, or dropped with its socket: nothing waits forever.",
  leadsTo: {
    whenever: (w) => w.the(Sender).state.queue.length > 0,
    then: (w) => w.the(Sender).state.queue.length === 0,
  },
});

const aLargeUploadCrossesInFragments = defineScenario("A large upload crosses in fragments", {
  description: "A three-fragment transcript line goes out one frame at a time and is delivered whole.",
  run(s) {
    s.act(s.the(Sender), "send", { size: "large", priority: "upload" });
    s.settle();
  },
});
const aReplyOvertakesAnUpload = defineScenario("A reply overtakes an upload", {
  description: "A large upload has started when a large reply is queued; the reply's frames go next, and each message is reassembled on its own.",
  run(s) {
    s.act(s.the(Sender), "send", { size: "large", priority: "upload" });
    s.step(s.the(Sender), "transmit");
    s.act(s.the(Sender), "send", { size: "large", priority: "reply" });
    s.settle();
  },
});
const theSenderGivesUpPartWay = defineScenario("The sender gives up part-way", {
  description: "The sender drops a message after its first fragment; the discard notice frees the receiver's slot, and the socket stays open.",
  run(s) {
    s.act(s.the(Sender), "send", { size: "large", priority: "upload" });
    s.step(s.the(Sender), "transmit");
    s.act(s.the(Sender), "abandon");
    s.settle();
  },
});
const aPeerAnnouncesTooManyFragments = defineScenario("A peer announces too many fragments", {
  description: "The receiver closes the socket instead of buffering an oversized message.",
  run(s) {
    s.act(s.the(Sender), "sendOversized");
    s.settle();
  },
});

export default defineSpec({
  name: "Relay fragments",
  description:
    "How a relay message larger than one frame crosses the host relay: split into fragments sent by priority, reassembled by the receiver before parsing, and dropped with the socket that carried them or when its sender gives up.",
  actors: [Sender, Receiver],
  limits: [limit1, limit2, limit3, limit4],
  properties: [deliveredWhole, deliveredOnce, abandonedNeverDelivered, oneStartedPerClass, honestSendersAreNeverRefused, partialsBounded, partialsDrain, everythingQueuedGoesOut],
  finalState: {
    description: "Nothing is in flight and nothing is queued.",
    when: (w) => w.quiet && w.the(Sender).state.queue.length === 0,
  },
  scenarios: [aLargeUploadCrossesInFragments, aReplyOvertakesAnUpload, theSenderGivesUpPartWay, aPeerAnnouncesTooManyFragments],
});
