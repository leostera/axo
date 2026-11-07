import { atMost, defineActor, defineGroup, defineLimit, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone, input, oneOf } from "@leostera/feynman";

// RFD0029, Tools ask; agents cannot approve. The computer tool decides whether an action needs
// the person: with `confirm: true` it always asks; without it, the gate checks (the text check,
// then Clef) and asks only if it flags the action. The action runs only on the person's answer to
// the request the tool made for that action, once. The agent is the adversary: it passes
// `confirm`, asks questions of its own and tries to present their answers to the tool, and
// calls the same action again hoping an earlier Allow still counts.
//
// The cloud and the person's clients are in ask-the-person.ts; here the person answers on one
// client, and what the request says is what the tool will do.
//
// Built: the gate asks, confirm only asks, and extra arguments are refused, for the local
// `computer` tool and for `codemode.computer.run` from another Mac (RFD0028). Not built: binding an
// Allow to the window it named (onceAndBound) beyond element tokens dying with a newer read.

const Action = oneOf("pay", "scroll");
const Confirm = oneOf("true", "false", "omitted");
const Choice = oneOf("accept", "decline");
const Outcome = oneOf("accept", "decline", "cancel");
type Action = "pay" | "scroll";
const Asker = oneOf("tool", "agent");

const Call = defineMessage("Call", { action: Action, confirm: Confirm, approval: String }, { name: "computer", over: "MCP" });
const Returned = defineMessage("Returned", { action: Action, result: String }, { name: "the tool's result", over: "MCP", tone: "reply" });
const OwnQuestion = defineMessage("OwnQuestion", {}, { name: "elicitation_request", over: "MCP" });
const OwnAnswer = defineMessage("OwnAnswer", { id: String, outcome: Outcome }, { name: "its outcome", over: "MCP", tone: "reply" });
const Ask = defineMessage("Ask", { action: Action, asker: Asker, target: Number }, { name: "axo.elicitation.request", over: "axod.sock" });
const Answered = defineMessage("Answered", { id: String, outcome: Outcome }, { name: "the outcome", over: "axod.sock", tone: "reply" });
const Card = defineMessage("Card", { id: String, action: Action, asker: Asker }, { name: "axo.elicitation.requested", over: "relay" });
const Answer = defineMessage("Answer", { id: String, outcome: Choice }, { name: "axo.elicitation.resolve", over: "relay" });
const Act = defineMessage("Act", { action: Action, request: String, target: Number }, { name: "click", over: "Accessibility" });

const expiry = defineLimit({ name: "A request expires after", value: 5, unit: "minutes" });

const mac = defineZone({ name: "Studio", description: "the Mac the agent runs on" });
const phone = defineZone({ name: "Leo's iPhone", place: { column: 1 } });

const noApprovalArguments = defineRule("noApprovalArguments", { description: "The tool takes no approval as an argument: a call that names an answer or a request is refused." });
const confirmAsks = defineRule("confirmAsks", { description: "confirm: true makes the tool ask without running the gate's check; it never approves." });
const answerToTheAsker = defineRule("answerToTheAsker", { description: "axod returns an outcome only on the connection that asked, and keeps nothing a tool could look up." });
const onceAndBound = defineRule("onceAndBound", { description: "An Allow runs the action it was asked for, once, and only while the window is the one the person was shown." });

/** What the gate makes of an action: Clef flags a payment. */
const flagged = (action: Action) => action === "pay";

export const Agent = defineActor({
  name: "Agent",
  description: "The agent, and anything that writes its words: it wants Pay now clicked, with or without the person.",
  zone: mac,
  singleton: true,
  initialState: () => ({ approvals: [] as string[], heard: "" as string, calls: 0 }),
  display: { icon: "robot", status: (s) => `${s.calls} call(s); last heard: ${s.heard || "nothing"}` },
  actions: {
    call: {
      with: [atMost(3)],
      label: "Call computer",
      description: "Calls the computer tool, passing confirm as it likes, and an answer it holds if it has one.",
      inputs: {
        action: input(Action, { examples: ["pay", "scroll"] as const }),
        confirm: input(Confirm, { examples: ["true", "false", "omitted"] as const }),
        approval: input(String, { examples: (w): string[] => ["", ...w.the(Agent).state.approvals] }),
      },
      sends: [Call],
      run(state, { action, confirm, approval }, ctx) {
        state.calls += 1;
        ctx.send(ctx.the(Tool), Call, { action, confirm, approval });
      },
    },
    askOwn: {
      with: [atMost(1)],
      label: "Ask a question of its own",
      description: "\"Can I pay?\" through elicitation_request: the person may well say yes.",
      sends: [OwnQuestion],
      run: (_s, _i, ctx) => ctx.send(ctx.the(Tool), OwnQuestion, {}),
    },
  },
  transitions: {
    returned: { on: Returned, description: "Hears what the tool did.", run: (s, m) => void (s.heard = `${m.action}: ${m.result}`) },
    ownAnswer: {
      on: OwnAnswer,
      description: "Hears the answer to its own question, and keeps it to show the tool.",
      run(s, m) {
        s.heard = `own question: ${m.outcome}`;
        if (m.outcome === "accept") s.approvals.push(m.id);
      },
    },
  },
});

type Waiting = { action: Action; request: string | null; target: number };

export const Tool = defineActor({
  name: "axod mcp",
  description: "The agent's MCP server: the computer tool and its gate, and elicitation_request.",
  zone: mac,
  singleton: true,
  initialState: () => ({ waiting: null as null | Waiting, own: false, allowed: [] as { action: Action; request: string }[] }),
  display: { icon: "cpu", status: (s) => (s.waiting ? `asking before ${s.waiting.action}` : "idle"), mood: (s) => (s.waiting ? "busy" : "ok") },
  transitions: {
    call: {
      on: Call,
      description: "Refuses approvals as arguments; asks when confirm is true or the gate flags the action; otherwise acts.",
      sources: ["crates/axo-mcp/src/lib.rs#McpServer.call_computer", "crates/axo-server/src/session/computer.rs#SessionManager.remote_computer", "crates/axo-computer/src/gate.rs#Gate.check"],
      sends: [Returned, Ask, Act],
      run(state, m, ctx) {
        if (state.waiting) return ctx.reply(Returned, { action: m.action, result: "busy" });
        if (m.approval && noApprovalArguments.on) return ctx.reply(Returned, { action: m.action, result: "refused: consent is not an argument" });
        const target = ctx.the(App).state.window;
        if (m.approval) {
          // Without the rule: the tool looks the answer up and takes it as consent.
          const known = ctx.the(Axod).state.requests[m.approval];
          if (known?.outcome === "accept") return ctx.send(ctx.the(App), Act, { action: m.action, request: m.approval, target });
        }
        if (!onceAndBound.on) {
          // Without the rule: an earlier Allow for this action still counts.
          const earlier = state.allowed.find((a) => a.action === m.action);
          if (earlier) return ctx.send(ctx.the(App), Act, { action: m.action, request: earlier.request, target });
        }
        const ask = m.confirm === "true" ? confirmAsks.on : false;
        const approves = m.confirm === "true" && !confirmAsks.on;
        if (!ask && (approves || !flagged(m.action))) return ctx.send(ctx.the(App), Act, { action: m.action, request: approves ? "confirm: true" : "", target });
        state.waiting = { action: m.action, request: null, target };
        ctx.send(ctx.the(Axod), Ask, { action: m.action, asker: "tool", target });
      },
    },
    ownQuestion: {
      on: OwnQuestion,
      description: "elicitation_request: asks on its own connection for the agent, and hands the answer back.",
      sends: [Ask],
      run(state, _m, ctx) {
        state.own = true;
        ctx.send(ctx.the(Axod), Ask, { action: "pay", asker: "agent", target: ctx.the(App).state.window });
      },
    },
    answered: {
      on: Answered,
      description: "An outcome for a request it made: runs the action it asked for, if the window is still the one shown.",
      sources: ["crates/axo-mcp/src/lib.rs#McpServer.ask_the_person"],
      sends: [OwnAnswer, Act, Returned],
      run(state, m, ctx) {
        const asker = ctx.the(Axod).state.requests[m.id]?.asker;
        if (asker === "agent" && state.own) {
          state.own = false;
          ctx.send(ctx.the(Agent), OwnAnswer, m);
          // Without answerToTheAsker the same outcome also reaches a waiting call below.
          if (answerToTheAsker.on) return;
        }
        const waiting = state.waiting;
        if (!waiting) return;
        if (answerToTheAsker.on && asker !== "tool") return;
        state.waiting = null;
        if (m.outcome !== "accept") return ctx.send(ctx.the(Agent), Returned, { action: waiting.action, result: m.outcome === "cancel" ? "nobody answered" : "the person declined" });
        state.allowed.push({ action: waiting.action, request: m.id });
        const window = ctx.the(App).state.window;
        if (onceAndBound.on && window !== waiting.target) return ctx.send(ctx.the(Agent), Returned, { action: waiting.action, result: "the window changed; ask again" });
        ctx.send(ctx.the(App), Act, { action: waiting.action, request: m.id, target: window });
      },
    },
  },
});

/** `target`: the window the person was shown. */
type Request = { action: Action; asker: "tool" | "agent"; target: number; outcome: null | "accept" | "decline" | "cancel" };

export const Axod = defineActor({
  name: "axod",
  description: "Owns requests; the first answer settles one, and its outcome goes back to whoever asked.",
  zone: mac,
  singleton: true,
  initialState: () => ({ requests: {} as Record<string, Request> }),
  display: {
    icon: "server",
    rows: (s) => Object.entries(s.requests).map(([id, r]) => ({ label: `${id} (${r.asker})`, detail: `${r.action}: ${r.outcome ?? "pending"}`, mood: "info" as const })),
  },
  transitions: {
    ask: {
      on: Ask,
      description: "Stores the request and shows it to the person.",
      sends: [Card],
      starts: ["expire"],
      run(state, m, ctx) {
        const id = ctx.fresh("request");
        state.requests[id] = { action: m.action, asker: m.asker, target: m.target, outcome: null };
        ctx.send(ctx.the(Person), Card, { id, action: m.action, asker: m.asker });
        ctx.start("expire");
      },
    },
    answer: {
      on: Answer,
      description: "The person's answer settles the request, once; the outcome goes to the tool that asked.",
      sends: [Answered],
      run(state, m, ctx) {
        const request = state.requests[m.id];
        if (!request || request.outcome !== null) return ctx.note("Already answered.");
        request.outcome = m.outcome;
        if (!Object.values(state.requests).some((r) => r.outcome === null)) ctx.cancel("expire");
        ctx.send(ctx.the(Tool), Answered, { id: m.id, outcome: m.outcome });
      },
    },
    expire: {
      description: "Nobody answered in time: the request ends as cancel.",
      after: "5 minutes",
      sends: [Answered],
      starts: ["expire"],
      run(state, _m, ctx) {
        // One deadline per request in axod; here one timer, set again while another waits.
        const pending = Object.entries(state.requests).filter(([, r]) => r.outcome === null);
        const open = pending[0];
        if (open) {
          open[1].outcome = "cancel";
          ctx.send(ctx.the(Tool), Answered, { id: open[0], outcome: "cancel" });
        }
        if (pending.length > 1) ctx.start("expire");
      },
    },
  },
});

export const Person = defineActor({
  name: "Leo",
  description: "Answers each card on his phone: Allow for his own reasons, or Deny.",
  zone: phone,
  singleton: true,
  initialState: () => ({ cards: {} as Record<string, { action: Action; asker: string }> }),
  display: { icon: "phone", status: (s) => `${Object.keys(s.cards).length} card(s)`, mood: (s) => (Object.keys(s.cards).length ? "warn" : "ok") },
  actions: {
    answer: {
      label: "Answer a card",
      description: "Allows or denies one of the cards showing.",
      inputs: {
        id: input(String, { examples: (w): string[] => Object.keys(w.the(Person).state.cards) }),
        outcome: input(Choice, { examples: ["accept", "decline"] as const }),
      },
      when: (s) => Object.keys(s.cards).length > 0,
      sends: [Answer],
      run(state, { id, outcome }, ctx) {
        delete state.cards[id];
        ctx.send(ctx.the(Axod), Answer, { id, outcome });
      },
    },
  },
  transitions: { card: { on: Card, description: "A card appears.", run: (s, m) => void (s.cards[m.id] = { action: m.action, asker: m.asker }) } },
});

export const App = defineActor({
  name: "Safari",
  description: "The window the tool acts on; its page may change while the person decides.",
  zone: mac,
  singleton: true,
  initialState: () => ({ window: 1, ran: [] as { action: Action; request: string; target: number }[] }),
  display: { icon: "browser", rows: (s) => s.ran.map((r) => ({ label: r.action, detail: r.request || "not gated", mood: "info" as const })) },
  actions: {
    navigate: {
      with: [atMost(1)],
      label: "The page changes",
      description: "A script on the page loads another one while the person decides.",
      run: (s) => void (s.window += 1),
    },
  },
  transitions: {
    act: {
      on: Act,
      description: "The click happens.",
      run: (s, m) => void s.ran.push({ action: m.action, request: m.request, target: m.target }),
    },
  },
});

const studio = defineGroup({ name: "Studio", actors: [Agent, Tool, Axod, App], icon: "laptop", collapsed: false });

const everyGatedRunIsLeosAnswer = defineProperty("everyGatedRunIsLeosAnswer", {
  description: "A payment runs only on Leo's Allow of the request the tool made for that payment, each Allow once, in the window he was shown.",
  always(w) {
    const requests = w.the(Axod).state.requests;
    const pays = w.the(App).state.ran.filter((r) => flagged(r.action));
    const used = pays.map((r) => r.request);
    return new Set(used).size === used.length && pays.every((r) => {
      const request = requests[r.request];
      return request?.asker === "tool" && request.action === r.action && request.outcome === "accept" && request.target === r.target;
    });
  },
  needs: [noApprovalArguments, confirmAsks, answerToTheAsker, onceAndBound],
});
const confirmOnlyAsks = defineProperty("confirmOnlyAsks", {
  description: "Nothing runs on confirm: true alone: a call that passed it ran only after Leo allowed it.",
  always: (w) => w.the(App).state.ran.every((r) => r.request !== "confirm: true"),
  needs: [confirmAsks],
});
const callsReturn = defineProperty("callsReturn", {
  description: "A call waiting on Leo always ends: he answers, and the tool acts or says why not.",
  leadsTo: { whenever: (w) => w.the(Tool).state.waiting !== null, then: (w) => w.the(Tool).state.waiting === null },
});

const ownQuestionThenPay = defineScenario("The agent asks its own question, then pays", {
  description: "Leo answers the agent's own \"Can I pay?\" with yes; the agent shows that answer to the tool, which refuses it; asked properly, Leo allows, and the click runs once.",
  run(s) {
    s.act(s.the(Agent), "askOwn");
    s.settle({ until: (w) => Object.keys(w.the(Person).state.cards).length > 0 });
    s.act(s.the(Person), "answer", { id: Object.keys(s.the(Person).state.cards)[0], outcome: "accept" });
    s.settle();
    s.act(s.the(Agent), "call", { action: "pay", confirm: "omitted", approval: s.the(Agent).state.approvals[0] });
    s.settle();
    s.act(s.the(Agent), "call", { action: "pay", confirm: "omitted", approval: "" });
    s.settle({ until: (w) => Object.keys(w.the(Person).state.cards).length > 0 });
    s.act(s.the(Person), "answer", { id: Object.keys(s.the(Person).state.cards)[0], outcome: "accept" });
    s.settle();
  },
});
const scrollFreely = defineScenario("Scrolling needs no one", {
  description: "The gate lets a scroll through without asking.",
  run(s) {
    s.act(s.the(Agent), "call", { action: "scroll", confirm: "omitted", approval: "" });
    s.settle();
  },
});
const thePageChanges = defineScenario("The page changes while Leo decides", {
  description: "Leo allows Pay now, but the page changed meanwhile: the tool clicks nothing and tells the agent to ask again.",
  run(s) {
    s.act(s.the(Agent), "call", { action: "pay", confirm: "omitted", approval: "" });
    s.settle({ until: (w) => Object.keys(w.the(Person).state.cards).length > 0 });
    s.act(s.the(App), "navigate");
    s.act(s.the(Person), "answer", { id: Object.keys(s.the(Person).state.cards)[0], outcome: "accept" });
    s.settle();
  },
});
const confirmAsksInstead = defineScenario("confirm: true asks", {
  description: "The agent passes confirm: true to scroll, an action the gate would let through: the tool asks Leo instead, and he declines.",
  run(s) {
    s.act(s.the(Agent), "call", { action: "scroll", confirm: "true", approval: "" });
    s.settle({ until: (w) => Object.keys(w.the(Person).state.cards).length > 0 });
    s.act(s.the(Person), "answer", { id: Object.keys(s.the(Person).state.cards)[0], outcome: "decline" });
    s.settle();
  },
});

export default defineSpec({
  name: "Tools ask; agents cannot approve",
  description: "How the computer tool gets consent for itself: confirm only asks, approvals are not arguments, and an Allow is for one action, once.",
  actors: [Agent, Tool, Axod, Person, App],
  groups: [studio],
  limits: [expiry],
  properties: [everyGatedRunIsLeosAnswer, confirmOnlyAsks, callsReturn],
  scenarios: [ownQuestionThenPay, confirmAsksInstead, scrollFreely, thePageChanges],
});
