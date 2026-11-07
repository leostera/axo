import { atMost, budget, defineActor, defineGroup, defineLimit, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone, input, lose, nullable, oneOf } from "@leostera/feynman";

// RFD0029: when an agent needs the person, axod asks the person directly on their own clients,
// and only the person's answer counts. Two kinds are modelled:
// - a confirm: the computer-use gate flags "click Pay now";
// - an input: the agent asks for a card number that must reach Safari's field without passing
//   through the agent or the cloud.
// Authenticate (Face ID) is an answer with a device signature; it changes no ordering here,
// so it is left out.
//
// Built: the gate asks (step 2), axod takes a local answer only from Axo.app by code signature
// (step 3), and input (step 4): sealed values, binding to the elements axod read, hiding filled
// values from reads. The card number here stands for any value `request_input` asks for.

/** Faults on one path (RFD0012). `--set faults=2` raises it. */
const faults = budget("faults", 1);

/** The person's card number. Only the phone ever has it in the clear, and then Safari's field. */
const CARD = "4242 4242 4242 4242";

const Answer = oneOf("allow", "deny", "fill");
const Kind = oneOf("confirm", "input");
const Outcome = oneOf("allowed", "denied", "filled", "expired", "cancelled");

const Ask = defineMessage("Ask", { kind: Kind, origin: String }, { name: "axo.elicitation.request", over: "axod.sock" });
const Asked = defineMessage("Asked", { outcome: Outcome, redact: nullable(String) }, { name: "the answer", over: "axod.sock", tone: "reply" });
const Requested = defineMessage("Requested", { id: String, kind: Kind, origin: String }, { name: "axo.elicitation.requested", over: "relay" });
const ShowRequest = defineMessage("ShowRequest", { id: String, kind: Kind, origin: String }, { name: "axo.elicitation.requested", over: "axod.sock" });
const RemoteAnswer = defineMessage("RemoteAnswer", { id: String, answer: Answer, value: nullable(String) }, { name: "answer", over: "wss" });
const ForwardedAnswer = defineMessage("ForwardedAnswer", { id: String, answer: Answer, value: nullable(String) }, { name: "answer", over: "relay" });
const LocalAnswer = defineMessage("LocalAnswer", { id: String, answer: Answer }, { name: "axo.elicitation.resolve", over: "axod.sock" });
const Resolved = defineMessage("Resolved", { id: String }, { name: "axo.elicitation.resolved", over: "relay" });
const LocalResolved = defineMessage("LocalResolved", { id: String }, { name: "axo.elicitation.resolved", over: "axod.sock" });
const Fill = defineMessage("Fill", { value: String, page: Number, shown: String }, { name: "set_value", over: "Accessibility" });
const FillDone = defineMessage("FillDone", { filled: Boolean }, { name: "set_value result", over: "Accessibility", tone: "reply" });
const Read = defineMessage("Read", {}, { name: "get_window_state", over: "Accessibility" });
const Window = defineMessage("Window", { origin: String, field: String }, { name: "window state", over: "Accessibility", tone: "reply" });

const mac = defineZone({ name: "Studio", description: "the Mac the agent runs on" });
const cloud = defineZone({ name: "Cloudflare", description: "relays, never decides", place: { column: 1, region: true } });
const phone = defineZone({ name: "Leo's iPhone", place: { column: 2 } });

const expiry = defineLimit({ name: "A request expires after", value: 5, unit: "minutes" });

// The rules the design rests on; each property that depends on one says so.
const peerCheck = defineRule("peerCheck", { description: "axod takes a local answer only from a peer whose code signature is Axo.app's." });
const sealedValues = defineRule("sealedValues", { description: "The phone seals input values to the Mac's request key; the cloud relays only ciphertext." });
const receiptOnly = defineRule("receiptOnly", { description: "The agent gets a receipt for an input, never its values." });
const boundTarget = defineRule("boundTarget", { description: "axod fills the element the request named; if the page changed, that element is gone and nothing is filled." });
const hideBeforeFill = defineRule("hideBeforeFill", { description: "axod remembers a salted hash of each value before it fills it, and every read is redacted after it is taken, with the hashes axod has then (axo.computer.redactions)." });
const redaction = defineRule("redaction", { description: "Computer results show values the person filled as \"•••• (filled by you)\"." });

/** `claimed`: an answer has been taken and is being carried out (a fill); later answers lose. */
type Request = { kind: "confirm" | "input"; origin: string; page: number; claimed: boolean; outcome: null | "allowed" | "denied" | "filled" | "expired" | "cancelled"; answeredBy: string | null };

const sealed = (id: string, value: string) => `sealed(${id}):${value.length}`;
const opens = (id: string, value: string) => (value.startsWith(`sealed(${id}):`) ? CARD : value);

export const Agent = defineActor({
  name: "Studio axod mcp",
  description: "A Session's agent and its MCP server, where the computer-use gate runs.",
  zone: mac,
  singleton: true,
  initialState: () => ({ waiting: false, asking: null as null | "confirm" | "input", reading: false, outcomes: [] as string[], redact: null as string | null, seen: [] as string[] }),
  display: {
    icon: "robot",
    status: (s) => (s.waiting ? "waiting for the person" : s.outcomes.length ? `last: ${s.outcomes.at(-1)}` : "working"),
    mood: (s) => (s.waiting ? "busy" : "ok"),
    rows: (s) => s.seen.map((text) => ({ label: "read", detail: text, mood: text.includes(CARD) ? ("bad" as const) : ("info" as const) })),
  },
  actions: {
    clickPayNow: {
      with: [atMost(1)],
      label: "Click \"Pay now\"",
      description: "The agent clicks Pay now; the gate flags it and asks the person instead of refusing.",
      when: (s) => !s.waiting,
      sources: ["crates/axo-mcp/src/lib.rs#McpServer.call_computer", "crates/axo-computer/src/gate.rs#Gate.check"],
      sends: [Ask],
      say: () => "The gate flags \"click Pay now\" and asks the person",
      run(state, _i, ctx) {
        state.waiting = true;
        state.asking = "confirm";
        ctx.send(ctx.the(Axod), Ask, { kind: "confirm", origin: "checkout.example.com" });
      },
    },
    requestCard: {
      with: [atMost(1)],
      label: "Request the card number",
      description: "The agent asks for the card number for Safari's card field.",
      when: (s) => !s.waiting,
      sources: ["crates/axo-server/src/session/input.rs#SessionManager.request_input", "crates/axo-computer/src/form.rs#Form.read"],
      sends: [Ask],
      run(state, _i, ctx) {
        state.waiting = true;
        state.asking = "input";
        ctx.send(ctx.the(Axod), Ask, { kind: "input", origin: "checkout.example.com" });
      },
    },
    readWindow: {
      with: [atMost(1)],
      label: "Read Safari's window",
      description: "The agent reads the checkout page again.",
      when: (s) => !s.reading,
      sends: [Read],
      run(state, _i, ctx) {
        state.reading = true;
        ctx.send(ctx.the(Safari), Read, {});
      },
    },
  },
  transitions: {
    asked: {
      on: Asked,
      description: "The tool call returns: done, declined, expired, or a receipt for the filled field.",
      run(state, m) {
        state.waiting = false;
        state.asking = null;
        state.outcomes.push(m.outcome);
        if (m.redact) state.redact = m.redact;
      },
    },
    window: {
      on: Window,
      description: "Sees the window, with values the person filled redacted by the hashes axod has now.",
      sources: ["crates/axo-mcp/src/lib.rs#McpServer.redact", "crates/axo-computer/src/lib.rs#redact"],
      run(state, m, ctx) {
        const hidden = ctx.the(Axod).state.hidden;
        const matches = hidden !== null && hidden === ctx.hash(m.field);
        const field = redaction.on && m.field && matches ? "•••• (filled by you)" : m.field;
        state.reading = false;
        state.seen.push(`${m.origin}: ${field || "empty"}`);
      },
    },
  },
});

export const Shell = defineActor({
  name: "Agent's shell",
  description: "A script the agent runs with bash, as the person's own user on the Mac.",
  zone: mac,
  singleton: true,
  initialState: () => ({}),
  display: { icon: "terminal", status: () => "bash" },
  actions: {
    forgeAllow: {
      with: [atMost(1)],
      label: "Answer \"allow\" over axod.sock",
      description: "The agent tries to approve its own request by calling axo.elicitation.resolve itself.",
      inputs: { id: input(String, { examples: (w): string[] => Object.keys(w.the(Axod).state.requests) }) },
      sends: [LocalAnswer],
      run: (_s, { id }, ctx) => ctx.send(ctx.the(Axod), LocalAnswer, { id, answer: "allow" }),
    },
  },
});

export const Axod = defineActor({
  name: "Studio axod",
  description: "The daemon: it owns requests, fans them out, takes the first answer and fills fields.",
  zone: mac,
  singleton: true,
  initialState: (): AxodState => ({ requests: {}, filling: null, hidden: null }),
  display: {
    icon: "cpu",
    status: (s) => {
      const open = Object.values(s.requests).filter((r) => r.outcome === null).length;
      return open ? `${open} request(s) waiting for the person` : "nothing waiting";
    },
    mood: (s) => (Object.values(s.requests).some((r) => r.outcome === null) ? "busy" : "ok"),
    rows: (s) =>
      Object.values(s.requests).map((r) => ({
        label: r.kind === "confirm" ? "click Pay now" : "card number",
        detail: r.outcome ? `${r.outcome}${r.answeredBy ? ` by ${r.answeredBy}` : ""}` : "pending",
        mood: r.outcome === null ? ("busy" as const) : r.outcome === "allowed" || r.outcome === "filled" ? ("ok" as const) : ("off" as const),
      })),
  },
  transitions: {
    ask: {
      on: Ask,
      description: "Stores a pending request and shows it on every client.",
      sends: [Requested, ShowRequest],
      starts: ["expire"],
      say: (_s, m) => `A ${m.kind} request goes to every client, showing the page's own address`,
      run(state, m, ctx) {
        const id = ctx.fresh("request");
        // axod reads where the request is from Accessibility itself; the agent's word is not shown as fact.
        const safari = ctx.the(Safari).state;
        state.requests[id] = { kind: m.kind, origin: safari.origin, page: safari.page, claimed: false, outcome: null, answeredBy: null };
        ctx.send(ctx.the(HostDO), Requested, { id, kind: m.kind, origin: safari.origin });
        ctx.send(ctx.the(MacApp), ShowRequest, { id, kind: m.kind, origin: safari.origin });
        ctx.start("expire");
      },
    },
    localAnswer: {
      on: LocalAnswer,
      description: "An answer on axod.sock counts only if the peer is Axo.app.",
      sources: ["crates/axo-server/src/session/elicitations.rs#add_methods", "crates/axo-ipc/src/peer.rs#Peer.is"],
      sends: [Asked, Resolved, LocalResolved],
      run(state, m, ctx) {
        if (peerCheck.on && ctx.from.id !== ctx.the(MacApp).id) return ctx.note("Refused: the peer is not Axo.app.");
        resolve(state, ctx, m.id, m.answer === "allow" ? "allowed" : "denied", ctx.from.label);
      },
    },
    forwardedAnswer: {
      on: ForwardedAnswer,
      description: "An answer from a signed-in client, through the cloud: opens a sealed value and fills it, or confirms.",
      sources: ["crates/axo-server/src/session/elicitations.rs#SessionManager.resolve_elicitation", "crates/axo-server/src/session/elicitations.rs#SessionManager.input_values", "crates/axo-server/src/session/input.rs#SessionManager.fill", "crates/axo-seal/src/lib.rs#InputKey.open"],
      sends: [Asked, Resolved, LocalResolved, Fill],
      run(state, m, ctx) {
        const request = state.requests[m.id];
        if (!request || request.outcome !== null || request.claimed) return ctx.note("Already answered.");
        if (m.answer === "fill" && request.kind === "input" && m.value) {
          // The first answer claims the request now, before the fill runs; a later Deny loses.
          request.claimed = true;
          request.answeredBy = "Leo's iPhone";
          state.filling = m.id;
          if (hideBeforeFill.on) state.hidden = ctx.hash(CARD);
          // Without boundTarget, it types into whatever page is there now.
          const page = boundTarget.on ? request.page : ctx.the(Safari).state.page;
          return ctx.send(ctx.the(Safari), Fill, { value: opens(m.id, m.value), page, shown: request.origin });
        }
        resolve(state, ctx, m.id, m.answer === "allow" ? "allowed" : "denied", "Leo's iPhone");
      },
    },
    fillDone: {
      on: FillDone,
      description: "The field is filled, or the page changed and nothing was; the agent gets a receipt.",
      sends: [Asked, Resolved, LocalResolved],
      run(state, m, ctx) {
        const id = state.filling;
        state.filling = null;
        if (id) resolve(state, ctx, id, m.filled ? "filled" : "cancelled", "Leo's iPhone", true);
      },
    },
    expire: {
      description: "Nobody answered in time; the request expires.",
      after: "5 minutes",
      sends: [Asked, Resolved, LocalResolved],
      starts: ["expire"],
      run(state, _m, ctx) {
        // One deadline per request in axod; here one timer, set again while another request waits.
        const pending = Object.entries(state.requests).filter(([, r]) => r.outcome === null && !r.claimed);
        const open = pending[0];
        if (open) resolve(state, ctx, open[0], "expired", null);
        if (pending.length > 1) ctx.start("expire");
      },
    },
  },
});

type AxodState = { requests: Record<string, Request>; filling: string | null; hidden: string | null };

/** The first answer wins: resolves once, tells every client, and answers the waiting tool call. */
function resolve(state: AxodState, ctx: any, id: string, outcome: NonNullable<Request["outcome"]>, by: string | null, completingClaim = false) {
  const request = state.requests[id];
  if (!request || request.outcome !== null || (request.claimed && !completingClaim)) return ctx.note("Already answered.");
  request.outcome = outcome;
  request.answeredBy = by;
  if (!Object.values(state.requests).some((r) => r.outcome === null && !r.claimed)) ctx.cancel("expire");
  ctx.send(ctx.the(HostDO), Resolved, { id });
  ctx.send(ctx.the(MacApp), LocalResolved, { id });
  // Without hideBeforeFill, axod would learn to hide the value only once the fill is done.
  if (outcome === "filled" && !hideBeforeFill.on) state.hidden = ctx.hash(CARD);
  // The receipt says what was filled; without receiptOnly it would carry the value itself.
  const redact = outcome === "filled" && !receiptOnly.on ? CARD : null;
  ctx.send(ctx.the(Agent), Asked, { outcome, redact });
}

export const HostDO = defineActor({
  name: "HostDO",
  description: "Studio's Durable Object: it forwards requests to the person's clients and their answers back, and sees only what it relays.",
  zone: cloud,
  singleton: true,
  initialState: () => ({ relayed: [] as string[] }),
  display: {
    icon: "cloud",
    status: (s) => `${s.relayed.length} answer(s) relayed`,
    rows: (s) => s.relayed.map((v) => ({ label: "relayed", detail: v, mood: v.includes(CARD) ? ("bad" as const) : ("info" as const) })),
  },
  transitions: {
    requested: {
      on: Requested,
      description: "Forwards the request to the person's clients, and an APNs alert to their iPhone.",
      sends: [Requested],
      run: (_s, m, ctx) => ctx.send(ctx.the(Phone), Requested, m),
    },
    answer: {
      on: RemoteAnswer,
      description: "Forwards a signed-in client's answer to the Mac, as it came.",
      sends: [ForwardedAnswer],
      run(state, m, ctx) {
        if (m.value) state.relayed.push(m.value);
        ctx.send(ctx.the(Axod), ForwardedAnswer, m);
      },
    },
    resolved: {
      on: Resolved,
      description: "Tells the clients the request is resolved, and withdraws the alert.",
      sends: [Resolved],
      run: (_s, m, ctx) => ctx.send(ctx.the(Phone), Resolved, m),
    },
    requestedLost: lose(Requested, { spend: faults }),
    answerLost: lose(RemoteAnswer, { spend: faults }),
  },
});

const cardsOf = (s: { cards: Record<string, { kind: string; origin: string }> }) => Object.keys(s.cards);

export const Phone = defineActor({
  name: "Leo's iPhone",
  description: "The iOS app: a push, then a card in the Session with Allow and Deny, or a form for the card number.",
  zone: phone,
  singleton: true,
  initialState: () => ({ cards: {} as Record<string, { kind: "confirm" | "input"; origin: string }>, done: new Set<string>() }),
  display: {
    icon: "phone",
    status: (s) => (cardsOf(s).length ? `${cardsOf(s).length} request(s) to answer` : "nothing to answer"),
    mood: (s) => (cardsOf(s).length ? "warn" : "ok"),
    rows: (s) => Object.values(s.cards).map((c) => ({ label: c.kind === "confirm" ? "Allow click Pay now?" : "Card number for", detail: c.origin, mood: "warn" as const })),
  },
  actions: {
    allow: {
      label: "Allow once",
      description: "Leo taps Allow once, after Face ID.",
      inputs: { id: input(String, { examples: (w): string[] => Object.entries(w.the(Phone).state.cards).filter(([, c]) => c.kind === "confirm").map(([id]) => id) }) },
      when: (s) => Object.values(s.cards).some((c) => c.kind === "confirm"),
      sends: [RemoteAnswer],
      run(state, { id }, ctx) {
        delete state.cards[id];
        ctx.send(ctx.the(HostDO), RemoteAnswer, { id, answer: "allow", value: null });
      },
    },
    deny: {
      label: "Deny",
      description: "Leo taps Deny.",
      inputs: { id: input(String, { examples: (w): string[] => Object.keys(w.the(Phone).state.cards) }) },
      when: (s) => cardsOf(s).length > 0,
      sends: [RemoteAnswer],
      run(state, { id }, ctx) {
        delete state.cards[id];
        ctx.send(ctx.the(HostDO), RemoteAnswer, { id, answer: "deny", value: null });
      },
    },
    fillCard: {
      label: "Fill the card number",
      description: "Leo fills the form from the Passwords app; the value is sealed to Studio's request key.",
      inputs: { id: input(String, { examples: (w): string[] => Object.entries(w.the(Phone).state.cards).filter(([, c]) => c.kind === "input").map(([id]) => id) }) },
      when: (s) => Object.values(s.cards).some((c) => c.kind === "input"),
      sends: [RemoteAnswer],
      run(state, { id }, ctx) {
        delete state.cards[id];
        ctx.send(ctx.the(HostDO), RemoteAnswer, { id, answer: "fill", value: sealedValues.on ? sealed(id, CARD) : CARD });
      },
    },
  },
  transitions: {
    requested: { on: Requested, description: "A push arrives; the card shows in the Session, unless it is known to be resolved.", run: (s, m) => void (s.done.has(m.id) || (s.cards[m.id] = { kind: m.kind, origin: m.origin })) },
    resolved: {
      on: Resolved,
      description: "Answered elsewhere or expired; the card and the alert go away.",
      run(s, m) {
        delete s.cards[m.id];
        s.done.add(m.id);
      },
    },
    resolvedLost: lose(Resolved, { spend: faults }),
  },
});

export const MacApp = defineActor({
  name: "Studio app",
  description: "The Mac app: a notification at the top right, and a card in the Session.",
  zone: mac,
  singleton: true,
  initialState: () => ({ cards: {} as Record<string, { kind: "confirm" | "input"; origin: string }>, done: new Set<string>() }),
  display: {
    icon: "laptop",
    status: (s) => (cardsOf(s).length ? "notification showing" : "quiet"),
    mood: (s) => (cardsOf(s).length ? "warn" : "ok"),
  },
  actions: {
    allow: {
      label: "Allow once (Mac)",
      description: "Leo clicks Allow once in the notification.",
      inputs: { id: input(String, { examples: (w): string[] => Object.entries(w.the(MacApp).state.cards).filter(([, c]) => c.kind === "confirm").map(([id]) => id) }) },
      when: (s) => Object.values(s.cards).some((c) => c.kind === "confirm"),
      sends: [LocalAnswer],
      run(state, { id }, ctx) {
        delete state.cards[id];
        ctx.send(ctx.the(Axod), LocalAnswer, { id, answer: "allow" });
      },
    },
    deny: {
      label: "Deny (Mac)",
      description: "Leo clicks Deny in the notification.",
      inputs: { id: input(String, { examples: (w): string[] => Object.keys(w.the(MacApp).state.cards) }) },
      when: (s) => cardsOf(s).length > 0,
      sends: [LocalAnswer],
      run(state, { id }, ctx) {
        delete state.cards[id];
        ctx.send(ctx.the(Axod), LocalAnswer, { id, answer: "deny" });
      },
    },
  },
  transitions: {
    show: { on: ShowRequest, description: "Shows the notification and the card, unless the request is known to be resolved.", run: (s, m) => void (s.done.has(m.id) || (s.cards[m.id] = { kind: m.kind, origin: m.origin })) },
    resolved: {
      on: LocalResolved,
      description: "Withdraws the notification and the card.",
      run(s, m) {
        delete s.cards[m.id];
        s.done.add(m.id);
      },
    },
  },
});

export const Safari = defineActor({
  name: "Safari",
  description: "The checkout page on the Mac, with a card number field.",
  zone: mac,
  singleton: true,
  initialState: () => ({ origin: "checkout.example.com", page: 1, field: "", filled: [] as { into: string; shown: string }[] }),
  display: { icon: "browser", status: (s) => `${s.origin}${s.field ? ": card filled" : ""}`, mood: (s) => (s.origin === "checkout.example.com" ? "ok" : "bad") },
  actions: {
    navigate: {
      with: [atMost(1)],
      label: "Page goes to a look-alike",
      description: "A script on the page sends it to a look-alike site before the answer arrives.",
      run(state) {
        state.origin = "checkout-example.co";
        state.page += 1;
        state.field = "";
      },
    },
  },
  transitions: {
    fill: {
      on: Fill,
      description: "Sets the named element's value; an element of a page that is gone takes nothing.",
      sources: ["crates/axo-computer/src/form.rs#Form.check_unchanged", "crates/axo-computer/src/form.rs#Form.fill"],
      sends: [FillDone],
      run(state, m, ctx) {
        if (m.page !== state.page) return ctx.reply(FillDone, { filled: false }, "The element is gone: the page changed.");
        state.field = m.value;
        state.filled.push({ into: state.origin, shown: m.shown });
        ctx.reply(FillDone, { filled: true });
      },
    },
    read: { on: Read, description: "Answers with the page and the field's value.", sends: [Window], run: (s, _m, ctx) => ctx.reply(Window, { origin: s.origin, field: s.field }) },
  },
});

const studio = defineGroup({ name: "Studio", actors: [Agent, Shell, Axod, MacApp, Safari], icon: "laptop", collapsed: false });

const onlyThePersonAnswers = defineProperty("onlyThePersonAnswers", {
  description: "A request is allowed only by an answer from Leo's iPhone or the Studio app, never by the agent's own script.",
  always: (w) => Object.values(w.the(Axod).state.requests).every((r) => r.outcome !== "allowed" || r.answeredBy === "Leo's iPhone" || r.answeredBy === "Studio app"),
  needs: [peerCheck],
});
const firstAnswerWins = defineProperty("firstAnswerWins", {
  description: "The first answer wins: once an answer is claimed or an outcome set, no other answer changes it.",
  everyStep: (before, after) =>
    Object.entries(before.the(Axod).state.requests).every(([id, r]) => {
      const next = after.the(Axod).state.requests[id];
      if (r.outcome !== null) return next?.outcome === r.outcome;
      return !r.claimed || next?.outcome === null || next?.outcome === "filled" || next?.outcome === "cancelled";
    }),
});
const cardNeverReachesTheAgent = defineProperty("cardNeverReachesTheAgent", {
  description: "The card number never appears in anything the agent receives or reads.",
  always: (w) => !w.the(Agent).state.seen.some((t) => t.includes(CARD)) && w.the(Agent).state.redact !== CARD,
  needs: [receiptOnly, redaction, hideBeforeFill],
});
const cardNeverInTheCloud = defineProperty("cardNeverInTheCloud", {
  description: "The cloud relays the card number only sealed.",
  always: (w) => !w.the(HostDO).state.relayed.some((v) => v.includes(CARD)),
  needs: [sealedValues],
});
const onlyIntoThePageShown = defineProperty("onlyIntoThePageShown", {
  description: "The card number is filled only into the page whose address the person was shown.",
  always: (w) => w.the(Safari).state.filled.every((f) => f.into === f.shown),
  needs: [boundTarget],
});
const theAgentAlwaysHears = defineProperty("theAgentAlwaysHears", {
  description: "A tool call waiting on the person always returns: allowed, denied, filled, cancelled or expired.",
  leadsTo: { whenever: (w) => w.the(Agent).state.waiting, then: (w) => !w.the(Agent).state.waiting },
});
const cardsGoAway = defineProperty("cardsGoAway", {
  description: "Once nothing is in flight, the Mac shows no card for a resolved request; the phone may keep one only if its resolved notice was lost.",
  always: (w) => !w.quiet || Object.keys(w.the(MacApp).state.cards).every((id) => w.the(Axod).state.requests[id]?.outcome === null),
});

const payFromThePhone = defineScenario("Allow a payment from the phone", {
  description: "The gate flags Pay now; Leo allows it on his iPhone; the Mac's notification goes away and the click runs.",
  run(s) {
    s.act(s.the(Agent), "clickPayNow");
    s.settle({ until: (w) => Object.keys(w.the(Phone).state.cards).length > 0 });
    s.act(s.the(Phone), "allow", { id: Object.keys(s.the(Phone).state.cards)[0] });
    s.settle();
  },
});
const cardPastTheAgent = defineScenario("Fill a card past the agent", {
  description: "The agent asks for the card; Leo fills it on his phone; Safari's field gets it, the cloud sees ciphertext, and the agent's next read shows it redacted.",
  run(s) {
    s.act(s.the(Agent), "requestCard");
    s.settle({ until: (w) => Object.keys(w.the(Phone).state.cards).length > 0 });
    s.act(s.the(Phone), "fillCard", { id: Object.keys(s.the(Phone).state.cards)[0] });
    s.settle();
    s.act(s.the(Agent), "readWindow");
    s.settle();
  },
});
const theAgentApprovesItself = defineScenario("The agent tries to approve itself", {
  description: "The agent's script answers allow over axod.sock; axod refuses it because the peer is not Axo.app, and Leo denies on the Mac.",
  run(s) {
    s.act(s.the(Agent), "clickPayNow");
    s.settle({ until: (w) => Object.keys(w.the(MacApp).state.cards).length > 0 });
    const id = Object.keys(s.the(Axod).state.requests)[0]!;
    s.act(s.the(Shell), "forgeAllow", { id });
    s.deliver(s.the(Axod), LocalAnswer);
    s.act(s.the(MacApp), "deny", { id });
    s.settle();
  },
});
const thePageChanges = defineScenario("The page changes before the answer", {
  description: "Safari goes to a look-alike before Leo's answer arrives; the requested element is gone, nothing is filled, and the agent hears cancelled.",
  run(s) {
    s.act(s.the(Agent), "requestCard");
    s.settle({ until: (w) => Object.keys(w.the(Phone).state.cards).length > 0 });
    s.act(s.the(Safari), "navigate");
    s.act(s.the(Phone), "fillCard", { id: Object.keys(s.the(Phone).state.cards)[0] });
    s.settle();
  },
});

export default defineSpec({
  name: "Ask the person",
  description: "How axod asks the person, not the agent, to confirm a flagged action or to fill a value the agent must not see.",
  actors: [Agent, Shell, Axod, HostDO, Phone, MacApp, Safari],
  groups: [studio],
  limits: [expiry],
  properties: [onlyThePersonAnswers, firstAnswerWins, cardNeverReachesTheAgent, cardNeverInTheCloud, onlyIntoThePageShown, theAgentAlwaysHears, cardsGoAway],
  scenarios: [payFromThePhone, cardPastTheAgent, theAgentApprovesItself, thePageChanges],
});
