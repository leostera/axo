import { atMost, defineActor, defineMessage, defineProperty, defineRule, defineSpec, defineZone, input, oneOf } from "@leostera/feynman";

// RFD0059. A target means the immutable argv + pinned directory of ONE invocation.
// Device signatures/HPKE/first-answer-wins are specified in ask-the-person.ts.
// Here an accepted value is opaque; only the owned helper can receive it.
const host = defineZone({ name: "Linux host" });
const device = defineZone({ name: "Person’s device" });
const oneShot = defineRule("oneShot", { description: "One accepted password settles this invocation; later answers cannot send another value." });
const boundHelper = defineRule("boundHelper", { description: "Accept only the owned sudo child’s helper and this invocation’s nonce." });
const Target = oneOf("command-a", "command-b");
const Choice = oneOf("accept", "decline", "cancel");
const Stage = oneOf("consent", "password");
type Target = "command-a" | "command-b";
type Stage = "consent" | "password";
const Intent = defineMessage("SudoIntent", { target: Target });
const Card = defineMessage("SudoCard", { stage: Stage, target: Target });
const Answer = defineMessage("SudoAnswer", { stage: Stage, choice: Choice });
const Launch = defineMessage("SudoLaunch", { target: Target });
const Connect = defineMessage("AskpassConnect", { ownedParent: Boolean, nonceMatches: Boolean });
const Secret = defineMessage("AskpassValue", { target: Target });
const Receipt = defineMessage("SudoReceipt", { status: String });
const Cancel = defineMessage("SudoCancel", {});

export const Agent = defineActor({
  name: "Agent", zone: host, singleton: true,
  initialState: () => ({ receipts: [] as string[], leaked: false }),
  actions: {
    request: { with: [atMost(1)], inputs: { target: input(Target, { examples: ["command-a", "command-b"] as const }) }, sends: [Intent],
      run: (_s, m, ctx) => ctx.send(ctx.the(Broker), Intent, m) },
    forgeHelper: { with: [atMost(1)], inputs: { nonceMatches: input(Boolean) }, sends: [Connect],
      run: (_s, m, ctx) => ctx.send(ctx.the(Broker), Connect, { ownedParent: false, nonceMatches: m.nonceMatches }) },
    cancel: { with: [atMost(1)], sends: [Cancel], run: (_s, _m, ctx) => ctx.send(ctx.the(Broker), Cancel, {}) },
  },
  transitions: {
    receipt: { on: Receipt, run: (s, m) => void s.receipts.push(m.status) },
    stolen: { on: Secret, run: (s) => void (s.leaked = true) },
  },
});

export const Person = defineActor({
  name: "Person", zone: device, singleton: true,
  initialState: () => ({ cards: {} as Partial<Record<Stage, Target>>, approved: null as Target | null }),
  actions: {
    answer: { with: [atMost(3)], when: (s) => Object.keys(s.cards).length > 0,
      inputs: { stage: input(Stage, { examples: (w): Stage[] => Object.keys(w.the(Person).state.cards) as Stage[] }), choice: input(Choice, { examples: ["accept", "decline", "cancel"] as const }) },
      sends: [Answer],
      run(s, m, ctx) {
        if (m.stage === "consent" && m.choice === "accept") s.approved = s.cards.consent!;
        // Retain the card so duplicate and late signed answers are explored too.
        ctx.send(ctx.the(Broker), Answer, m);
      } },
  },
  transitions: { card: { on: Card, run: (s, m) => void (s.cards[m.stage] = m.target) } },
});

export const Sudo = defineActor({
  name: "Owned sudo and askpass", zone: host, singleton: true,
  initialState: () => ({ live: false, target: null as Target | null, received: [] as Target[] }),
  actions: { exit: { with: [atMost(1)], when: (s) => s.live, run: (s) => void (s.live = false) } },
  transitions: {
    launch: { on: Launch, sends: [Connect], run(s, m, ctx) {
      s.live = true; s.target = m.target;
      ctx.send(ctx.the(Broker), Connect, { ownedParent: true, nonceMatches: true });
    } },
    value: { on: Secret, run(s, m) { if (s.live && s.target === m.target) s.received.push(m.target); } },
  },
});

export const Broker = defineActor({
  name: "axod sudo broker", zone: host, singleton: true,
  initialState: () => ({ phase: "idle", target: "command-a" as Target, consent: false, helperOwned: false, values: [] as { target: Target; approved: boolean; live: boolean }[] }),
  transitions: {
    intent: { on: Intent, sends: [Card], starts: ["expire"], run(s, m, ctx) {
      if (s.phase !== "idle") return;
      s.target = m.target; s.phase = "consent";
      ctx.start("expire"); ctx.send(ctx.the(Person), Card, { stage: "consent", target: s.target });
    } },
    answer: { on: Answer, sends: [Launch, Secret, Receipt], run(s, m, ctx) {
      if (s.phase !== m.stage) return;
      if (m.choice !== "accept") { s.phase = "done"; return ctx.send(ctx.the(Agent), Receipt, { status: m.choice }); }
      if (m.stage === "consent") {
        s.consent = true; s.phase = "binding";
        return ctx.send(ctx.the(Sudo), Launch, { target: s.target });
      }
      const live = ctx.the(Sudo).state.live;
      s.phase = oneShot.on ? "done" : "password";
      if (!live) return ctx.send(ctx.the(Agent), Receipt, { status: "target_gone" });
      s.values.push({ target: s.target, approved: s.consent, live });
      if (s.helperOwned) ctx.send(ctx.the(Sudo), Secret, { target: s.target });
      else ctx.send(ctx.the(Agent), Secret, { target: s.target });
      ctx.send(ctx.the(Agent), Receipt, { status: "delivered" });
    } },
    helper: { on: Connect, sends: [Card], run(s, m, ctx) {
      if (s.phase !== "binding") return;
      if ((boundHelper.on && (!m.ownedParent || !m.nonceMatches)) || !ctx.the(Sudo).state.live) { s.phase = "done"; return; }
      s.helperOwned = m.ownedParent;
      s.phase = "password";
      ctx.send(ctx.the(Person), Card, { stage: "password", target: s.target });
    } },
    cancelled: { on: Cancel, run(s) { if (s.phase !== "idle") s.phase = "done"; } },
    expire: { after: "5 minutes", run: (s) => void (s.phase = "done") },
  },
});

export default defineSpec({
  name: "Linux sudo: consent, private helper, one value",
  description: "One immutable invocation; stale answers, cancellation, foreign helpers and process exit interleave with person-only password input. No credential is a receipt or a terminal write.",
  actors: [Agent, Broker, Person, Sudo],
  properties: [
    defineProperty("valueNeedsConsentAndLiveTarget", { always: (w) => w.the(Broker).state.values.every(v => v.approved && v.live && v.target === w.the(Person).state.approved) }),
    defineProperty("oneValuePerInvocation", { description: "An accepted value is delivered at most once.", needs: [oneShot], always: (w) => w.the(Broker).state.values.length <= 1 && w.the(Sudo).state.received.length <= 1 }),
    defineProperty("foreignHelperNeverReceivesValue", { description: "A same-UID socket client never receives the person’s value.", needs: [boundHelper], always: (w) => !w.the(Agent).state.leaked }),
    defineProperty("validFlowCanDeliver", { description: "The model admits a live approved delivery, rather than refusing every call.", reachable: (w) => w.the(Sudo).state.received.length === 1 }),
    defineProperty("receiptContainsNoValue", { always: (w) => w.the(Agent).state.receipts.every(s => ["accept", "decline", "cancel", "delivered", "target_gone"].includes(s)) }),
    defineProperty("consentPrecedesPasswordCard", { always: (w) => w.the(Person).state.cards.password === undefined || w.the(Broker).state.consent }),
  ],
});
