import { atMost, defineActor, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone } from "@leostera/feynman";

// RFD0034, Cancellation. An agent asks the person a question and waits for the answer. If the
// agent goes away first (its `axod mcp` exits, its connection to axod closes, or its MCP client
// sends `notifications/cancelled`), axod withdraws the question: the cards go away on every
// device, and the slot (at most 16 wait on a Mac) is free again.
//
// Built: everything here. The transport cancels a connection's unanswered requests when it
// closes (axo-ipc). The MCP server runs in axod on the connection `axod mcp` opens; it fires the
// cancellation of a call's in-process requests when its client cancels the call or leaves
// (axo-mcp, `axo_ipc::Local`), and a question wakes on its request's cancellation. The
// conformance tests `an_asker_that_goes_away_withdraws_its_question`,
// `an_agent_that_leaves_withdraws_its_questions` and `cancelling_a_call_withdraws_its_question`
// check it against the real binaries.

const Ask = defineMessage("Ask", { asker: String }, { name: "axo.elicitation.request", over: "unix socket" });
const Outcome = defineMessage("Outcome", { action: String }, { name: "its result", over: "unix socket", tone: "reply" });
const HungUp = defineMessage("HungUp", { asker: String }, { name: "the connection closes", over: "unix socket" });
const Cancelled = defineMessage("Cancelled", { asker: String }, { name: "notifications/cancelled", over: "unix socket" });
const Card = defineMessage("Card", { id: String }, { name: "elicitation.requested", over: "events" });
const Dismiss = defineMessage("Dismiss", { id: String }, { name: "elicitation.resolved", over: "events" });
const Answer = defineMessage("Answer", { id: String }, { name: "axo.elicitation.resolve", over: "unix socket or relay" });

const mac = defineZone({ name: "Studio", description: "axod and its agents" });
const devices = defineZone({ name: "Leo's devices", place: { column: 1 } });

const withdrawOnHangUp = defineRule("withdrawOnHangUp", { description: "When the connection that asked closes, axod withdraws its questions as cancel." });
const withdrawOnCancel = defineRule("withdrawOnCancel", { description: "When the asker cancels its request, axod withdraws the question as cancel." });

type Question = { asker: string; settled: null | "accept" | "cancel" };

export const Axod = defineActor({
  name: "Studio axod",
  description: "Opens a question per request, settles it with the first of: an answer, the asker going away, expiry.",
  zone: mac,
  singleton: true,
  initialState: () => ({ questions: {} as Record<string, Question>, gone: [] as string[], cancelled: [] as string[] }),
  display: {
    icon: "server",
    rows: (s) => Object.entries(s.questions).map(([id, q]) => ({ label: `${id} (${q.asker})`, detail: q.settled ?? "waiting", mood: q.settled ? ("off" as const) : ("info" as const) })),
  },
  actions: {
    expire: {
      // Five minutes is long next to everything else here, so it is an action that may never
      // come (an action is not fair), not a timer: a quiet world before it is reachable.
      label: "Five minutes pass",
      description: "Every question still waiting ends as cancel.",
      when: (s) => Object.values(s.questions).some((q) => q.settled === null),
      sources: ["crates/axo-questions/src/lib.rs#Questions.ask_with"],
      sends: [Dismiss, Outcome],
      run(state, _m, ctx) {
        for (const [id, question] of Object.entries(state.questions)) {
          if (question.settled) continue;
          question.settled = "cancel";
          ctx.send(ctx.the(Person), Dismiss, { id });
          if (!state.gone.includes(question.asker)) ctx.send({ id: question.asker }, Outcome, { action: "cancel" });
        }
      },
    },
  },
  transitions: {
    ask: {
      on: Ask,
      description: "Opens the question and shows it to every client, unless the request was cancelled before it started.",
      sources: ["crates/axo-questions/src/lib.rs#Questions.ask_with"],
      sends: [Card, Outcome],
      run(state, m, ctx) {
        const id = `q${Object.keys(state.questions).length + 1}`;
        // The handler may start after its connection closed: its cancellation has fired
        // already, and the wait ends at once (a select on a cancelled token).
        const early = (withdrawOnHangUp.on && state.gone.includes(m.asker)) || (withdrawOnCancel.on && state.cancelled.includes(m.asker));
        if (early) {
          state.questions[id] = { asker: m.asker, settled: "cancel" };
          if (!state.gone.includes(m.asker)) ctx.send({ id: m.asker }, Outcome, { action: "cancel" });
          return ctx.note("Cancelled before it started: withdrawn before anyone saw it.");
        }
        state.questions[id] = { asker: m.asker, settled: null };
        ctx.send(ctx.the(Person), Card, { id });
      },
    },
    answer: {
      on: Answer,
      description: "The person's answer settles a question still waiting, and goes to its asker.",
      sources: ["crates/axo-questions/src/lib.rs#Questions.resolve"],
      sends: [Dismiss, Outcome],
      run(state, m, ctx) {
        const question = state.questions[m.id];
        if (!question || question.settled) return ctx.note("No longer waiting.");
        question.settled = "accept";
        ctx.send(ctx.the(Person), Dismiss, { id: m.id });
        if (!state.gone.includes(question.asker)) ctx.send({ id: question.asker }, Outcome, { action: "accept" });
      },
    },
    hungUp: {
      on: HungUp,
      description: "The asker's connection closed: its questions are withdrawn.",
      sources: ["crates/axo-ipc/src/server.rs#serve_connection", "crates/axo-ipc/src/cancel.rs#Cancellation.cancel", "crates/axo-questions/src/lib.rs#Questions.ask_with"],
      sends: [Dismiss],
      run(state, m, ctx) {
        state.gone.push(m.asker);
        if (!withdrawOnHangUp.on) return;
        for (const [id, question] of Object.entries(state.questions)) {
          if (question.asker !== m.asker || question.settled) continue;
          question.settled = "cancel";
          ctx.send(ctx.the(Person), Dismiss, { id });
        }
      },
    },
    cancelled: {
      on: Cancelled,
      description: "The asker cancelled its request: the question is withdrawn, and the asker told.",
      sources: ["crates/axo-mcp/src/calls.rs#Calls.give_up", "crates/axo-ipc/src/local.rs#Local.call", "crates/axo-questions/src/lib.rs#Questions.ask_with"],
      sends: [Dismiss, Outcome],
      run(state, m, ctx) {
        if (!withdrawOnCancel.on) return;
        // The request's token exists before its handler runs, so a cancel that arrives first
        // is not lost.
        state.cancelled.push(m.asker);
        for (const [id, question] of Object.entries(state.questions)) {
          if (question.asker !== m.asker || question.settled) continue;
          question.settled = "cancel";
          ctx.send(ctx.the(Person), Dismiss, { id });
          ctx.send({ id: m.asker }, Outcome, { action: "cancel" });
        }
      },
    },
  },
});

export const Agent = defineActor({
  name: "Agent",
  description: "A Session's agent, through its axod mcp: asks once, and may give up waiting.",
  zone: mac,
  initialState: () => ({ asked: false, waiting: false, cancelled: false, outcome: null as string | null, gone: false }),
  display: { icon: "robot", names: ["a1", "a2"], status: (s) => (s.gone ? "gone" : s.waiting ? "waiting" : (s.outcome ?? "idle")) },
  actions: {
    ask: {
      with: [atMost(1)],
      label: "Ask the person",
      description: "elicitation_request: one question, then wait.",
      when: (s) => !s.asked && !s.gone,
      sends: [Ask],
      run(state, _i, ctx) {
        state.asked = true;
        state.waiting = true;
        ctx.send(ctx.the(Axod), Ask, { asker: ctx.id });
      },
    },
    cancel: {
      with: [atMost(1)],
      label: "Cancel the wait",
      description: "The MCP client gives up on the call and sends notifications/cancelled.",
      when: (s) => s.waiting && !s.gone,
      sends: [Cancelled],
      run(state, _i, ctx) {
        state.cancelled = true;
        ctx.send(ctx.the(Axod), Cancelled, { asker: ctx.id });
      },
    },
    hangUp: {
      with: [atMost(1)],
      label: "Exit",
      description: "Pi exits or is restarted; its axod mcp, and the connection, go with it.",
      when: (s) => !s.gone,
      sends: [HungUp],
      run(state, _i, ctx) {
        state.gone = true;
        state.waiting = false;
        ctx.send(ctx.the(Axod), HungUp, { asker: ctx.id });
      },
    },
  },
  transitions: {
    outcome: {
      on: Outcome,
      description: "The answer, or cancel, ends the wait.",
      run(state, m) {
        state.waiting = false;
        state.outcome = m.action;
      },
    },
  },
});

export const Person = defineActor({
  name: "Leo",
  description: "Sees a card per waiting question on every device, and may answer one.",
  zone: devices,
  singleton: true,
  // `resolved`: axod's events reach a client in order, so a card never comes back after its
  // question is resolved. The model delivers in any order; remembering stands in for that.
  initialState: () => ({ cards: [] as string[], resolved: [] as string[] }),
  display: { icon: "phone", status: (s) => `${s.cards.length} card(s)` },
  actions: {
    answer: {
      label: "Answer a card",
      description: "Yes, from the phone or Axo.app.",
      when: (s) => s.cards.length > 0,
      sends: [Answer],
      run(state, _i, ctx) {
        ctx.send(ctx.the(Axod), Answer, { id: state.cards[0]! });
      },
    },
  },
  transitions: {
    card: { on: Card, description: "A card appears.", run: (s, m) => void (s.cards.includes(m.id) || s.resolved.includes(m.id) || s.cards.push(m.id)) },
    dismiss: {
      on: Dismiss,
      description: "The card goes away.",
      run(s, m) {
        s.cards = s.cards.filter((card) => card !== m.id);
        s.resolved.push(m.id);
      },
    },
  },
});

const waiting = (w: { the: (a: typeof Axod) => { state: { questions: Record<string, Question> } } }) =>
  Object.entries(w.the(Axod).state.questions).filter(([, q]) => q.settled === null);

const noQuestionOutlivesItsAsker = defineProperty("noQuestionOutlivesItsAsker", {
  description: "Once things are quiet, no question waits for an agent that has gone.",
  always: (w) => !w.quiet || waiting(w).every(([, q]) => !w.the(Axod).state.gone.includes(q.asker)),
  needs: [withdrawOnHangUp],
});

const cardsAreTheWaitingQuestions = defineProperty("cardsAreTheWaitingQuestions", {
  description: "Once things are quiet, Leo sees a card for each waiting question and no other.",
  always: (w) => !w.quiet || JSON.stringify([...w.the(Person).state.cards].sort()) === JSON.stringify(waiting(w).map(([id]) => id).sort()),
});

const aCancelledWaitEnds = defineProperty("aCancelledWaitEnds", {
  description: "Once things are quiet, an agent that cancelled its wait is no longer waiting: it heard cancel, or the answer.",
  always: (w) => !w.quiet || w.all(Agent).every((a) => !a.state.cancelled || !a.state.waiting),
  needs: [withdrawOnCancel],
});

const theAskerLeaves = defineScenario("The asker leaves", {
  description: "a1 asks, then its Pi exits; axod withdraws the question and the card goes away.",
  run(s) {
    const a1 = s.spawn(Agent, "a1");
    s.act(a1, "ask");
    s.settle({ until: (w) => w.the(Person).state.cards.length > 0 });
    s.act(a1, "hangUp");
    s.settle({ until: (w) => w.quiet });
  },
});

const twoAgentsOneLeaves = defineScenario("Two agents wait; one leaves", {
  description: "a1 and a2 ask; a1 cancels its wait, Leo answers a2.",
  run(s) {
    const a1 = s.spawn(Agent, "a1");
    const a2 = s.spawn(Agent, "a2");
    s.act(a1, "ask");
    s.act(a2, "ask");
    s.settle({ until: (w) => w.the(Person).state.cards.length === 2 });
    s.act(a1, "cancel");
    s.settle({ until: (w) => w.the(Person).state.cards.length === 1 });
    s.act(s.the(Person), "answer");
    s.settle({ until: (w) => w.quiet });
  },
});

export default defineSpec({
  name: "Cancelling a question",
  description: "A question lasts only as long as the agent that asked it is waiting.",
  actors: [Axod, Agent, Person],
  properties: [noQuestionOutlivesItsAsker, cardsAreTheWaitingQuestions, aCancelledWaitEnds],
  scenarios: [theAskerLeaves, twoAgentsOneLeaves],
  finalState: { description: "Everyone has done what they will; nothing is in flight.", when: (w) => w.quiet },
});
