import { atMost, budget, defineActor, defineGroup, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone, input, lose, nullable, oneOf } from "@leostera/feynman";

// RFD0029, "Always allow" and "Authenticate": the two parts of asking the person that the
// ask-the-person spec leaves out.
// - Always allow: an answer can create a rule, so the same flagged action (archive in Mail) runs
//   without asking again. Rules never cover money, and the person can revoke one from the phone.
// - Authenticate: paying needs Face ID. The phone's Secure Enclave key signs the answer, and axod
//   checks the signature before it acts.
// The cloud relays answers. It is trusted not to read them, but here it may also replay an old
// answer under a new request's id, as a compromised relay would.
//
// Not built yet: no step has sources.

const faults = budget("faults", 1);

type Action = "archive" | "pay";
const ActionKind = oneOf("archive", "pay");
const Reply = oneOf("once", "always", "deny");

const Ask = defineMessage("Ask", { action: ActionKind }, { name: "flagged action", over: "axod.sock" });
const Done = defineMessage("Done", { ran: Boolean }, { name: "the result", over: "axod.sock", tone: "reply" });
const Requested = defineMessage("Requested", { id: String, action: ActionKind }, { name: "axo.elicitation.requested", over: "relay" });
const Answer = defineMessage("Answer", { id: String, reply: Reply, sig: nullable(String) }, { name: "answer", over: "relay" });
const Revoke = defineMessage("Revoke", { rule: String }, { name: "revoke rule", over: "relay" });
const RuleAdded = defineMessage("RuleAdded", { rule: String, action: ActionKind }, { name: "rule added", over: "relay" });
const Revoked = defineMessage("Revoked", { rule: String }, { name: "rule revoked", over: "relay" });

const mac = defineZone({ name: "Studio", description: "the Mac the agent runs on" });
const cloud = defineZone({ name: "Cloudflare", description: "relays, never decides", place: { column: 1, region: true } });
const phone = defineZone({ name: "Leo's iPhone", place: { column: 2 } });

const neverForMoney = defineRule("neverForMoney", { description: "axod creates no Always-allow rule for an action that moves money, whatever the client sends." });
const signEveryAnswer = defineRule("signEveryAnswer", { description: "The phone's device key signs every answer over the request's id and the reply, so a signature is good for one request and one reply only." });
const faceIdForMoney = defineRule("faceIdForMoney", { description: "Answers to payments must be signed by the device's Face ID-protected key." });
const revokedAfterAck = defineRule("revokedAfterAck", { description: "The phone shows a rule as revoked only once axod has confirmed revoking that rule, by its id; until then it shows \"Revoking…\"." });

/** Stands in for a Secure Enclave signature: only the phone makes one; with Face ID, a different key. */
const sign = (id: string, reply: string, faceId = false) => `${faceId ? "faceid" : "device"}-sig${signEveryAnswer.on ? `(${id}:${reply})` : ""}`;
/** Without signEveryAnswer, any signature from the phone passes; without faceIdForMoney, any key does. */
function accepts(sig: string | null, id: string, reply: string, money: boolean): boolean {
  if (signEveryAnswer.on && (sig === null || !sig.endsWith(`(${id}:${reply})`))) return false;
  if (money && faceIdForMoney.on && !sig?.startsWith("faceid")) return false;
  return true;
}

type Rule = { id: string; action: Action };
type Run = { action: Action; by: "rule" | "person"; id: string | null; reply: string | null; shownRevoked: boolean };

export const Agent = defineActor({
  name: "Studio agent",
  description: "Drives Mail and a checkout through the computer tool; the gate flags archive and pay.",
  zone: mac,
  singleton: true,
  initialState: () => ({ waiting: false }),
  display: { icon: "robot", status: (s) => (s.waiting ? "waiting" : "working"), mood: (s) => (s.waiting ? "busy" : "ok") },
  actions: {
    archive: {
      with: [atMost(3)],
      label: "Archive a message",
      description: "The agent archives a message in Mail.",
      when: (s) => !s.waiting,
      sends: [Ask],
      run(s, _i, ctx) {
        s.waiting = true;
        ctx.send(ctx.the(Axod), Ask, { action: "archive" });
      },
    },
    pay: {
      with: [atMost(2)],
      label: "Click Pay now",
      description: "The agent clicks Pay now at a checkout.",
      when: (s) => !s.waiting,
      sends: [Ask],
      run(s, _i, ctx) {
        s.waiting = true;
        ctx.send(ctx.the(Axod), Ask, { action: "pay" });
      },
    },
  },
  transitions: { done: { on: Done, description: "The click ran, or not.", run: (s) => void (s.waiting = false) } },
});

export const Axod = defineActor({
  name: "Studio axod",
  description: "The gate: runs an action a rule covers, asks the person otherwise, and checks Face ID signatures for money.",
  zone: mac,
  singleton: true,
  initialState: () => ({ rules: [] as Rule[], requests: {} as Record<string, { action: Action; open: boolean }>, runs: [] as Run[] }),
  display: {
    icon: "cpu",
    status: (s) => (s.rules.length ? `always allows: ${s.rules.map((r) => r.action).join(", ")}` : "no rules"),
    rows: (s) => s.runs.map((r) => ({ label: r.action, detail: r.by === "rule" ? "by rule" : `by Leo (${r.reply})`, mood: r.shownRevoked || (r.action === "pay" && r.by === "rule") ? ("bad" as const) : ("ok" as const) })),
  },
  transitions: {
    ask: {
      on: Ask,
      description: "A rule covers it: it runs. Otherwise the person is asked.",
      sends: [Done, Requested],
      run(state, m, ctx) {
        const rule = state.rules.find((r) => r.action === m.action);
        if (rule) {
          // Ghost: what the phone shows at this moment, for the revocation property.
          const shownRevoked = ctx.the(Phone).state.revoked.includes(rule.id);
          state.runs.push({ action: m.action, by: "rule", id: null, reply: null, shownRevoked });
          return ctx.reply(Done, { ran: true });
        }
        const id = ctx.fresh("request");
        state.requests[id] = { action: m.action, open: true };
        ctx.send(ctx.the(HostDO), Requested, { id, action: m.action });
      },
    },
    answer: {
      on: Answer,
      description: "The person's answer: runs it, adds a rule for Always allow, and for money needs a signature for this request.",
      sends: [Done, RuleAdded],
      run(state, m, ctx) {
        const request = state.requests[m.id];
        if (!request?.open) return ctx.note("Not pending.");
        if (!accepts(m.sig, m.id, m.reply, request.action === "pay")) return ctx.note("Refused: not signed by Leo's device for this request and reply.");
        request.open = false;
        if (m.reply === "deny") return ctx.send(ctx.the(Agent), Done, { ran: false });
        if (m.reply === "always" && !(neverForMoney.on && request.action === "pay") && !state.rules.some((r) => r.action === request.action)) {
          const rule = ctx.fresh("rule");
          state.rules.push({ id: rule, action: request.action });
          ctx.send(ctx.the(HostDO), RuleAdded, { rule, action: request.action });
        }
        state.runs.push({ action: request.action, by: "person", id: m.id, reply: m.reply, shownRevoked: false });
        ctx.send(ctx.the(Agent), Done, { ran: true });
      },
    },
    revoke: {
      on: Revoke,
      description: "Removes the rule and confirms it.",
      sends: [Revoked],
      run(state, m, ctx) {
        state.rules = state.rules.filter((r) => r.id !== m.rule);
        ctx.send(ctx.the(HostDO), Revoked, { rule: m.rule });
      },
    },
  },
});

export const HostDO = defineActor({
  name: "HostDO",
  description: "Relays requests, answers and rule changes. Here it may replay an old answer under a new request's id.",
  zone: cloud,
  singleton: true,
  initialState: () => ({ answers: [] as { id: string; reply: "once" | "always" | "deny"; sig: string | null }[], ids: [] as string[] }),
  display: { icon: "cloud", status: (s) => `${s.answers.length} answer(s) relayed` },
  actions: {
    replay: {
      with: [atMost(1)],
      label: "Replay an answer",
      description: "A compromised relay sends an earlier answer again, under another request's id or with its reply changed to Always allow.",
      inputs: {
        pair: input(String, {
          examples: (w): string[] => {
            const { answers, ids } = w.the(HostDO).state;
            return answers.flatMap((a) => [...ids.filter((id) => id !== a.id).map((id) => `${a.id}>${id}`), ...ids.map((id) => `${a.id}>${id}>always`)]);
          },
        }),
      },
      when: (s) => s.answers.length > 0,
      sends: [Answer],
      run(s, { pair }, ctx) {
        const [from, to, reply] = pair.split(">");
        const old = s.answers.find((a) => a.id === from);
        if (old && to) ctx.send(ctx.the(Axod), Answer, { ...old, id: to, reply: reply === "always" ? "always" : old.reply });
      },
    },
  },
  transitions: {
    requested: {
      on: Requested,
      description: "Shows the card on the phone.",
      sends: [Requested],
      run(s, m, ctx) {
        s.ids.push(m.id);
        ctx.send(ctx.the(Phone), Requested, m);
      },
    },
    answer: {
      on: Answer,
      description: "Forwards the phone's answer to the Mac, and keeps it.",
      sends: [Answer],
      run(s, m, ctx) {
        if (ctx.from.id === ctx.the(Phone).id) s.answers.push(m);
        ctx.send(ctx.the(Axod), Answer, m);
      },
    },
    revoke: { on: Revoke, description: "Forwards a revocation to the Mac.", sends: [Revoke], run: (_s, m, ctx) => ctx.send(ctx.the(Axod), Revoke, m) },
    ruleAdded: { on: RuleAdded, description: "Tells the phone.", sends: [RuleAdded], run: (_s, m, ctx) => ctx.send(ctx.the(Phone), RuleAdded, m) },
    revoked: { on: Revoked, description: "Tells the phone.", sends: [Revoked], run: (_s, m, ctx) => ctx.send(ctx.the(Phone), Revoked, m) },
    revokeLost: lose(Revoke, { spend: faults }),
  },
});

const cardsFor = (s: { cards: Record<string, Action> }, action?: Action) => Object.entries(s.cards).filter(([, a]) => !action || a === action).map(([id]) => id);

export const Phone = defineActor({
  name: "Leo's iPhone",
  description: "Cards with Allow once, Always allow and Deny; Face ID for paying; a list of rules with Revoke.",
  zone: phone,
  singleton: true,
  initialState: () => ({ cards: {} as Record<string, Action>, rules: [] as Rule[], revoking: [] as string[], revoked: [] as string[] }),
  display: {
    icon: "phone",
    status: (s) => (cardsFor(s).length ? `${cardsFor(s).length} to answer` : "nothing to answer"),
    rows: (s) => [
      ...s.rules.map((r) => ({ label: "always allows", detail: `${r.action} (${r.id})`, mood: "info" as const })),
      ...s.revoking.map((r) => ({ label: "revoking…", detail: r, mood: "busy" as const })),
      ...s.revoked.map((r) => ({ label: "revoked", detail: r, mood: "off" as const })),
    ],
  },
  actions: {
    allowOnce: {
      label: "Allow once",
      description: "Leo allows it once with a tap; a client with a bug may offer this on a payment, without Face ID.",
      inputs: { id: input(String, { examples: (w): string[] => cardsFor(w.the(Phone).state) }) },
      when: (s) => cardsFor(s).length > 0,
      sends: [Answer],
      run(s, { id }, ctx) {
        delete s.cards[id];
        ctx.send(ctx.the(HostDO), Answer, { id, reply: "once", sig: sign(id, "once") });
      },
    },
    alwaysAllow: {
      label: "Always allow",
      description: "Leo taps Always allow. An older or modified client may offer it on a payment too.",
      inputs: { id: input(String, { examples: (w): string[] => cardsFor(w.the(Phone).state) }) },
      when: (s) => cardsFor(s).length > 0,
      sends: [Answer],
      run(s, { id }, ctx) {
        const action = s.cards[id];
        delete s.cards[id];
        ctx.send(ctx.the(HostDO), Answer, { id, reply: "always", sig: sign(id, "always", action === "pay") });
      },
    },
    payWithFaceId: {
      label: "Pay with Face ID",
      description: "Leo looks at the phone; its Secure Enclave key signs the answer.",
      inputs: { id: input(String, { examples: (w): string[] => cardsFor(w.the(Phone).state, "pay") }) },
      when: (s) => cardsFor(s, "pay").length > 0,
      sends: [Answer],
      run(s, { id }, ctx) {
        delete s.cards[id];
        ctx.send(ctx.the(HostDO), Answer, { id, reply: "once", sig: sign(id, "once", true) });
      },
    },
    deny: {
      label: "Deny",
      description: "Leo denies it.",
      inputs: { id: input(String, { examples: (w): string[] => cardsFor(w.the(Phone).state) }) },
      when: (s) => cardsFor(s).length > 0,
      sends: [Answer],
      run(s, { id }, ctx) {
        delete s.cards[id];
        ctx.send(ctx.the(HostDO), Answer, { id, reply: "deny", sig: sign(id, "deny") });
      },
    },
    revoke: {
      label: "Revoke",
      description: "Leo revokes the archive rule in Settings.",
      inputs: { rule: input(String, { examples: (w): string[] => w.the(Phone).state.rules.map((r) => r.id) }) },
      when: (s) => s.rules.length > 0,
      sends: [Revoke],
      run(s, { rule }, ctx) {
        s.rules = s.rules.filter((x) => x.id !== rule);
        if (revokedAfterAck.on) s.revoking.push(rule);
        else s.revoked.push(rule);
        ctx.send(ctx.the(HostDO), Revoke, { rule });
      },
    },
    retryRevoke: {
      label: "Retry revoking",
      description: "Still \"Revoking…\": Leo taps it again.",
      inputs: { rule: input(String, { examples: (w): string[] => w.the(Phone).state.revoking }) },
      when: (s) => s.revoking.length > 0,
      sends: [Revoke],
      run: (_s, { rule }, ctx) => ctx.send(ctx.the(HostDO), Revoke, { rule }),
    },
  },
  transitions: {
    requested: { on: Requested, description: "A card shows.", run: (s, m) => void (s.cards[m.id] = m.action) },
    ruleAdded: {
      on: RuleAdded,
      description: "The rule shows in Settings.",
      run(s, m) {
        if (!s.rules.some((r) => r.id === m.rule)) s.rules.push({ id: m.rule, action: m.action });
      },
    },
    revoked: {
      on: Revoked,
      description: "axod confirmed revoking this rule: it shows as revoked.",
      run(s, m) {
        s.revoking = s.revoking.filter((r) => r !== m.rule);
        if (!s.revoked.includes(m.rule)) s.revoked.push(m.rule);
      },
    },
  },
});

const studio = defineGroup({ name: "Studio", actors: [Agent, Axod], icon: "laptop", collapsed: false });

const moneyNeverByRule = defineProperty("moneyNeverByRule", {
  description: "A payment never runs by an Always-allow rule: each one is asked.",
  always: (w) => w.the(Axod).state.runs.every((r) => r.action !== "pay" || r.by === "person"),
  needs: [neverForMoney],
});
const everyRunIsLeosAnswer = defineProperty("everyRunIsLeosAnswer", {
  description: "Each action Leo is asked about runs only on the answer he gave to that request: a replayed or rewritten answer runs nothing and adds no rule.",
  always: (w) => {
    const sent = w.the(HostDO).state.answers;
    const runsOk = w.the(Axod).state.runs.every((r) => r.by === "rule" || sent.some((a) => a.id === r.id && a.reply === r.reply));
    const rulesOk = w.the(Axod).state.rules.every((rule) => sent.some((a) => a.reply === "always" && w.the(Axod).state.requests[a.id]?.action === rule.action));
    return runsOk && rulesOk;
  },
  needs: [signEveryAnswer],
});
const faceIdForEveryPayment = defineProperty("faceIdForEveryPayment", {
  description: "Each payment runs on an answer Leo gave with Face ID.",
  always: (w) => w.the(Axod).state.runs.every((r) => r.action !== "pay" || w.the(HostDO).state.answers.some((a) => a.id === r.id && a.sig?.startsWith("faceid"))),
  needs: [faceIdForMoney],
});
const revokedMeansAsked = defineProperty("revokedMeansAsked", {
  description: "Once the phone shows a rule as revoked, nothing runs by it.",
  always: (w) => w.the(Axod).state.runs.every((r) => !r.shownRevoked),
  needs: [revokedAfterAck],
});

const firstCard = (cards: Record<string, Action>) => Object.keys(cards)[0]!;

const alwaysThenRevoke = defineScenario("Always allow archiving, then revoke it", {
  description: "Leo always allows archiving; the next archive runs without asking; he revokes the rule and the one after is asked again.",
  run(s) {
    s.act(s.the(Agent), "archive");
    s.settle();
    s.act(s.the(Phone), "alwaysAllow", { id: firstCard(s.the(Phone).state.cards) });
    s.settle();
    s.act(s.the(Agent), "archive");
    s.settle();
    s.act(s.the(Phone), "revoke", { rule: s.the(Phone).state.rules[0]!.id });
    s.settle();
    s.act(s.the(Agent), "archive");
    s.settle();
  },
});
const payTwice = defineScenario("Two payments, one Face ID", {
  description: "Leo pays once with Face ID; the relay replays that answer for a second payment, and axod refuses it because the signature is for the first request.",
  run(s) {
    s.act(s.the(Agent), "pay");
    s.settle();
    s.act(s.the(Phone), "payWithFaceId", { id: firstCard(s.the(Phone).state.cards) });
    s.settle();
    s.act(s.the(Agent), "pay");
    s.settle();
    const [first, second] = s.the(HostDO).state.ids;
    s.act(s.the(HostDO), "replay", { pair: `${first}>${second}` });
    s.settle();
  },
});

export default defineSpec({
  name: "Ask the person: rules and Face ID",
  description: "How Always-allow rules and Face ID-signed answers behave, including revocation and a relay that replays answers.",
  actors: [Agent, Axod, HostDO, Phone],
  groups: [studio],
  properties: [moneyNeverByRule, everyRunIsLeosAnswer, faceIdForEveryPayment, revokedMeansAsked],
  scenarios: [alwaysThenRevoke, payTwice],
  finalState: { description: "Anything quiet: Leo may leave a card unanswered (expiry is in specs/ask-the-person.ts).", when: () => true },
});
