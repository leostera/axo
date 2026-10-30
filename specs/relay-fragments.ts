import { defineSpec, message } from "@leostera/feynman";

const SEC = 1_000;

// RFD0016, Transport: a relay message larger than one 64 KiB frame travels as fragments under the
// relay's delivery credits, and is reassembled before anything parses it.
//
// One direction is modelled: a sender (axod returning a large bash result, or the Durable Object
// returning a script result; both run the same rules) and a receiver. Sizes are scaled down: a
// message is 1 or 3 fragments, the credit window is 2 frames, and at most 2 fragmented messages
// are in flight. A socket has an epoch; every frame carries it, so a partial message from a closed
// socket is never completed with frames from the next one, even when the close itself goes
// unnoticed. On the real WebSocket a lost frame means the socket died; here a lost frame or ack is
// a fault.
//
// Running out of credit never closes the host socket: everything on it (durable upload, commands,
// connections calls) would go down with one slow message. Messages carry a priority class
// (replies and control first, then durable upload, then ephemeral progress), and the sender
// interleaves fragments by class, so a large reply never waits behind an upload. A message that
// waits too long for credit is discarded on its own and the receiver is told to drop its partial.

const WINDOW = 2;
const MAX_IN_FLIGHT = 2;
const MAX_FRAGMENTS = 3;

type Priority = "reply" | "upload";
type Frame = { epoch: number; message: string; index: number; count: number; priority: Priority };

export default defineSpec(
  "Relay fragments",
  {
    description:
      "How a relay message larger than one frame crosses the host relay: split into fragments that travel under the delivery credits, reassembled by the receiver before parsing, and discarded with the socket that carried them.",
    messages: {
      Fragment: message<Frame>({ name: "axo.transport.fragment", over: "websocket" }),
      Ack: message<{ epoch: number }>({ name: "axo.transport.ack", over: "websocket", tone: "reply" }),
      Close: message<{ epoch: number; reason: string }>({ name: "close the socket", over: "websocket", tone: "refused" }),
      Discard: message<{ epoch: number; message: string }>({ name: "axo.transport.discard", over: "websocket" }),
    },
  },
  (spec) => {
    const { Fragment, Ack, Close, Discard } = spec.messages;

    const mac = spec.defineZone({ name: "Sender", description: "axod, or the Durable Object answering it" });
    const cloud = spec.defineZone({ name: "Receiver", description: "the other end of the relay socket", place: { column: 1 } });

    spec.defineLimit({ name: "Relay frame", value: 65_536, unit: "bytes" });
    spec.defineLimit({ name: "Reassembled message", value: 2 * 1_048_576, unit: "bytes" });
    spec.defineLimit({ name: "Fragmented messages in flight per socket", value: 4, unit: "messages" });
    spec.defineLimit({ name: "Delivery credit", value: 32, unit: "frames" });
    spec.defineLimit({ name: "A message waiting this long for credit is discarded", value: 30 * SEC });
    spec.defineLimit({ name: "A partial message with no new fragment for this long is dropped", value: 60 * SEC });

    const Sender = spec.defineActor({
      name: "Sender",
      description: "One end of a relay socket, sending messages that may need several frames.",
      zone: mac,
      singleton: true,
      initialState: () => ({
        epoch: 1,
        credit: WINDOW,
        discardsInFlight: 0,
        /** Frames waiting for credit, in order within each message. */
        queue: [] as Frame[],
        /** Discard notices waiting for credit; they go before any fragment. */
        discards: [] as string[],
        /** Messages not yet fully acknowledged, with how many of their frames are unacked or queued. */
        outstanding: {} as Record<string, number>,
        failed: [] as string[],
        sent: 0,
      }),
      display: {
        icon: "terminal",
        status: (s) => `socket ${s.epoch}, ${s.credit} credit, ${s.queue.length} queued`,
        mood: (s) => (s.queue.length && !s.credit ? "warn" : "ok"),
      },
      actions: {
        send: {
          label: "Send a message",
          description: "Sends a reply or an upload, of one frame or split into three.",
          inputs: {
            size: spec.defineInput(String, { examples: ["small", "large"] }),
            priority: spec.defineInput(String, { examples: ["reply", "upload"] }),
          },
          when: (s) => Object.keys(s.outstanding).length < MAX_IN_FLIGHT && s.sent < 3,
          sends: [Fragment],
          starts: ["creditTimeout"],
          run(state, { size, priority }, ctx) {
            state.sent += 1;
            const message = `m${state.sent}`;
            const count = size === "large" ? 3 : 1;
            state.outstanding[message] = count;
            for (let index = 0; index < count; index++) state.queue.push({ epoch: state.epoch, message, index, count, priority: priority as Priority });
            pump(state, ctx);
          },
        },
        sendOversized: {
          label: "Send a message that is too large",
          description: "A broken or hostile peer announces more fragments than a message may have.",
          when: (s) => s.sent < 3 && Object.keys(s.outstanding).length < MAX_IN_FLIGHT,
          sends: [Fragment],
          starts: ["creditTimeout"],
          run(state, _i, ctx) {
            state.sent += 1;
            const message = `m${state.sent}`;
            state.outstanding[message] = 1;
            state.queue.push({ epoch: state.epoch, message, index: 0, count: MAX_FRAGMENTS + 1, priority: "reply" });
            pump(state, ctx);
          },
        },
      },
      transitions: {
        [Ack]: {
          description: "Each acknowledged frame returns one credit; queued frames go out.",
          sends: [Fragment, Discard],
          starts: ["creditTimeout"],
          run(state, m, ctx) {
            if (m.epoch !== state.epoch || state.credit >= WINDOW) return;
            state.credit += 1;
            settleOne(state);
            pump(state, ctx);
          },
        },
        [Close]: {
          description: "The receiver closed the socket; every message not fully acknowledged fails, and a new socket starts empty.",
          run(state, m) {
            if (m.epoch === state.epoch) reset(state);
          },
        },
        creditTimeout: {
          description: "No credit came back in time: the messages still waiting fail and are discarded, and the receiver is told to drop their partials. The socket stays open.",
          after: "30 seconds",
          sends: [Fragment, Discard],
          run(state, ctx) {
            const waiting = Object.keys(state.outstanding);
            if (!waiting.length) return;
            for (const message of waiting) {
              delete state.outstanding[message];
              state.failed.push(message);
              // A message none of whose fragments went out leaves nothing to discard.
              const queued = state.queue.filter((f) => f.message === message);
              if (!queued.length || queued.length < queued[0]!.count) state.discards.push(message);
            }
            state.queue = state.queue.filter((f) => !waiting.includes(f.message));
            pump(state, ctx);
          },
        },
      },
    });

    /** Sends discard notices, then queued frames by priority, while there is credit. */
    function pump(state: any, ctx: any): void {
      while (state.credit > 0 && state.discards.length) {
        state.credit -= 1;
        state.discardsInFlight = (state.discardsInFlight ?? 0) + 1;
        ctx.send(ctx.the(Receiver), Discard, { epoch: state.epoch, message: state.discards.shift()! });
      }
      while (state.credit > 0 && state.queue.length) {
        const next = state.queue.findIndex((f: Frame) => f.priority === "reply");
        const [frame] = state.queue.splice(next === -1 ? 0 : next, 1);
        state.credit -= 1;
        ctx.send(ctx.the(Receiver), Fragment, frame);
      }
      if (state.queue.length || Object.keys(state.outstanding).length) ctx.start("creditTimeout");
    }
    /** An ack settles the oldest unacked frame; acks arrive in order on one socket. */
    function settleOne(state: any): void {
      if (state.discardsInFlight) return void (state.discardsInFlight -= 1);
      const oldest = Object.keys(state.outstanding)[0];
      if (!oldest) return;
      const queued = state.queue.filter((f: Frame) => f.message === oldest).length;
      if (state.outstanding[oldest] > queued) state.outstanding[oldest] -= 1;
      if (state.outstanding[oldest] === 0) delete state.outstanding[oldest];
    }
    function reset(state: any): void {
      state.failed.push(...Object.keys(state.outstanding));
      state.outstanding = {};
      state.queue = [];
      state.discards = [];
      state.discardsInFlight = 0;
      state.credit = WINDOW;
      state.epoch += 1;
    }

    const Receiver = spec.defineActor({
      name: "Receiver",
      description: "The other end: it acknowledges every frame and hands complete messages to the relay's parser.",
      zone: cloud,
      singleton: true,
      initialState: () => ({
        epoch: 1,
        /** Partial messages, kept in SQLite on the Durable Object so hibernation loses nothing. */
        partial: {} as Record<string, { count: number; got: number[] }>,
        delivered: [] as { message: string; epoch: number; got: number[]; count: number }[],
        /** Messages discarded on this socket; a late fragment of one is ignored. */
        discarded: [] as string[],
        refused: 0,
      }),
      durable: ["epoch", "partial", "delivered", "discarded", "refused"],
      display: {
        icon: "cloud",
        status: (s) => `${Object.keys(s.partial).length} partial, ${s.delivered.length} delivered`,
        rows: (s) => s.delivered.map((d) => ({ group: "Delivered", label: d.message, detail: `${d.count} fragment(s), socket ${d.epoch}` })),
      },
      transitions: {
        [Fragment]: {
          description: "Acknowledges the frame and keeps it; a message whose fragments are all here goes to the parser. A newer socket discards older partials; a message announcing too many fragments, or too many partials at once, closes the socket.",
          sends: [Ack, Close],
          starts: ["partialExpiry"],
          run(state, f, ctx) {
            if (f.epoch < state.epoch) return;
            if (f.epoch > state.epoch) {
              state.epoch = f.epoch;
              state.partial = {};
              state.discarded = [];
            }
            if (state.discarded.includes(f.message)) return void ctx.reply(Ack, { epoch: f.epoch });
            const known = state.partial[f.message];
            if (f.count > MAX_FRAGMENTS || f.index >= f.count || (known && known.count !== f.count) || (!known && Object.keys(state.partial).length >= MAX_IN_FLIGHT)) {
              state.refused += 1;
              state.partial = {};
              // Nothing more from the closed socket is accepted.
              state.epoch = f.epoch + 1;
              ctx.reply(Close, { epoch: f.epoch, reason: "invalid fragment" });
              return;
            }
            ctx.reply(Ack, { epoch: f.epoch });
            const entry = (state.partial[f.message] ??= { count: f.count, got: [] });
            if (entry.got.includes(f.index)) return;
            entry.got.push(f.index);
            if (entry.got.length < entry.count) return void ctx.start("partialExpiry");
            delete state.partial[f.message];
            state.delivered.push({ message: f.message, epoch: f.epoch, got: [...entry.got].sort(), count: entry.count });
          },
        },
        partialExpiry: {
          description: "A partial message got no new fragment for a minute: its sender gave up, or its discard notice was lost. It is dropped, and late fragments of it are ignored.",
          after: "60 seconds",
          run(state) {
            for (const message of Object.keys(state.partial)) {
              delete state.partial[message];
              if (!state.discarded.includes(message)) state.discarded.push(message);
            }
          },
        },
        [Discard]: {
          description: "The sender gave up on a message; its partial is dropped, freeing its slot.",
          sends: [Ack],
          run(state, m, ctx) {
            if (m.epoch < state.epoch) return;
            ctx.reply(Ack, { epoch: m.epoch });
            delete state.partial[m.message];
            if (!state.discarded.includes(m.message)) state.discarded.push(m.message);
          },
        },
      },
    });

    spec.defineProperties({
      deliveredWhole: {
        description: "The parser only ever sees a message with every one of its fragments, all from one socket.",
        always: (w) => w.the(Receiver).state.delivered.every((d) => d.got.length === d.count && d.got.every((i, n) => i === n)),
      },
      deliveredOnce: {
        description: "A message reaches the parser at most once.",
        always: (w) => {
          const ids = w.the(Receiver).state.delivered.map((d) => d.message);
          return new Set(ids).size === ids.length;
        },
      },
      creditWithinWindow: {
        description: "The sender never has more frames unacknowledged than the credit window, so the receiver never drops it for capacity.",
        always: (w) => w.the(Sender).state.credit >= 0 && w.the(Sender).state.credit <= WINDOW,
      },
      partialsBounded: {
        description: "The receiver never holds more partial messages, or more fragments of one, than the limits allow.",
        always: (w) => {
          const p = w.the(Receiver).state.partial;
          return Object.keys(p).length <= MAX_IN_FLIGHT && Object.values(p).every((e) => e.count <= MAX_FRAGMENTS);
        },
      },
      partialsDrain: {
        description: "A partial message on the receiver is in the end completed or discarded: it never holds a slot forever.",
        leadsTo: {
          whenever: (w) => Object.keys(w.the(Receiver).state.partial).length > 0,
          then: (w) => Object.keys(w.the(Receiver).state.partial).length === 0,
        },
      },
      everyMessageEnds: {
        description: "Every message sent is in the end fully acknowledged or failed: nothing waits on credit forever.",
        leadsTo: {
          whenever: (w) => Object.keys(w.the(Sender).state.outstanding).length > 0,
          then: (w) => Object.keys(w.the(Sender).state.outstanding).length === 0,
        },
      },
    });

    spec.defineScenario({
      name: "A large result crosses in fragments",
      description: "A three-fragment message goes out two frames at a time, the third once an ack returns, and is delivered whole.",
      run(s) {
        s.act(s.the(Sender), "send", { size: "large", priority: "upload" });
        s.settle();
      },
    });
    spec.defineScenario({
      name: "A reply overtakes an upload",
      description: "A large upload is going out when a reply is queued; the reply's frame goes next, and each message is reassembled on its own.",
      run(s) {
        s.act(s.the(Sender), "send", { size: "large", priority: "upload" });
        s.act(s.the(Sender), "send", { size: "small", priority: "reply" });
        s.settle();
      },
    });
    spec.defineScenario({
      name: "A message waits too long for credit",
      description: "The receiver goes quiet after two fragments; the message fails on its own, the receiver drops its partial when the discard notice arrives, and the socket stays open.",
      run(s) {
        s.act(s.the(Sender), "send", { size: "large", priority: "upload" });
        s.settle({ until: (w) => Object.keys(w.the(Receiver).state.partial).length > 0 });
        s.fire(s.the(Sender), "creditTimeout");
        s.settle();
      },
    });
    spec.defineScenario({
      name: "A peer announces too many fragments",
      description: "The receiver closes the socket instead of buffering an oversized message.",
      run(s) {
        s.act(s.the(Sender), "sendOversized");
        s.settle();
      },
    });

    spec.defineFinalState({
      description: "Nothing is in flight and the sender waits on nothing.",
      when: (w) => w.quiet && Object.keys(w.the(Sender).state.outstanding).length === 0,
    });

    return { Sender, Receiver };
  },
);
