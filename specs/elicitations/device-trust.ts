import { atMost, defineActor, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone, input, oneOf } from "@leostera/feynman";

// RFD0029, Every remote answer is signed. The phone (and the browser) holds a device key and
// signs each answer over the request's id, the action and the sealed values. The person trusts
// their account, which Cloudflare Access guards, so any device signed in to it may answer; what
// the signature guards against is the relay getting an answer wrong: a bug that replays it onto
// another request, or changes a No into a Yes.
//
// Built: everything here (step 5).

const Action = oneOf("accept", "decline");
type Action = "accept" | "decline";

const Card = defineMessage("Card", { id: String }, { name: "axo.elicitation.requested", over: "relay" });
const Answer = defineMessage("Answer", { id: String, action: Action, sig: String }, { name: "axo.elicitation.resolve", over: "relay" });
const Refused = defineMessage("Refused", { id: String }, { name: "its error", over: "relay", tone: "reply" });

const mac = defineZone({ name: "Studio", description: "the Mac that asks" });
const cloud = defineZone({ name: "Cloud", place: { column: 1 } });
const phone = defineZone({ name: "Leo's iPhone", place: { column: 2 } });

const signedForTheAnswer = defineRule("signedForTheAnswer", { description: "A signature covers the request's id, the action and the sealed values: it is good for that answer only." });

/** `n` stands for the randomness in each ECDSA signature: no two are the same. */
const signature = (id: string, action: Action, n: number) => (signedForTheAnswer.on ? `${id}/${action}#${n}` : `#${n}`);
const signs = (sig: string, id: string, action: Action) => !signedForTheAnswer.on || sig.startsWith(`${id}/${action}#`);

export const Axod = defineActor({
  name: "Studio axod",
  description: "Asks two questions, and settles each with the first answer whose signature is for it.",
  zone: mac,
  singleton: true,
  initialState: () => ({ requests: { r1: null, r2: null } as Record<string, Action | null> }),
  display: { icon: "server", rows: (s) => Object.entries(s.requests).map(([id, outcome]) => ({ label: id, detail: outcome ?? "waiting", mood: "info" as const })) },
  actions: {
    ask: {
      with: [atMost(1)],
      label: "Ask both questions",
      description: "The gate asks Leo about two actions.",
      sends: [Card],
      run(_s, _i, ctx) {
        ctx.send(ctx.the(Relay), Card, { id: "r1" });
        ctx.send(ctx.the(Relay), Card, { id: "r2" });
      },
    },
  },
  transitions: {
    answer: {
      on: Answer,
      description: "Takes an answer only with its device's signature over that request and that action.",
      sources: ["crates/axo-server/src/session/devices.rs#check_answer", "crates/axo-seal/src/lib.rs#verify_answer"],
      sends: [Refused],
      run(state, m, ctx) {
        if (!(m.id in state.requests) || state.requests[m.id] !== null) return ctx.note("Already answered.");
        if (!signs(m.sig, m.id, m.action)) return ctx.reply(Refused, { id: m.id });
        state.requests[m.id] = m.action;
      },
    },
  },
});

export const Relay = defineActor({
  name: "The cloud",
  description: "Passes cards and answers on; a bug in it may replay an answer onto the other request, or as a Yes.",
  zone: cloud,
  singleton: true,
  initialState: () => ({ seen: [] as { id: string; action: Action; sig: string }[] }),
  display: { icon: "cloud", status: (s) => `${s.seen.length} answer(s) seen` },
  actions: {
    replay: {
      with: [atMost(1)],
      label: "Replay an answer (a bug)",
      description: "Sends the last answer it saw again, onto the other request and as a Yes.",
      when: (s) => s.seen.length > 0,
      sends: [Answer],
      run(state, _i, ctx) {
        const seen = state.seen[0]!;
        const other = seen.id === "r1" ? "r2" : "r1";
        ctx.send(ctx.the(Axod), Answer, { id: other, action: seen.action, sig: seen.sig });
        ctx.send(ctx.the(Axod), Answer, { id: seen.id, action: "accept", sig: seen.sig });
      },
    },
  },
  transitions: {
    card: { on: Card, description: "Shows the card on the phone.", sends: [Card], run: (_s, m, ctx) => ctx.send(ctx.the(Phone), Card, m) },
    answer: {
      on: Answer,
      description: "Passes the phone's answer on, and keeps a copy.",
      sends: [Answer],
      run(state, m, ctx) {
        state.seen = [m];
        ctx.send(ctx.the(Axod), Answer, m);
      },
    },
    refused: { on: Refused, description: "Drops the refusal: the relay's own mistake.", run: () => {} },
  },
});

export const Phone = defineActor({
  name: "Leo's iPhone",
  description: "Leo answers each card; the Secure Enclave key signs it.",
  zone: phone,
  singleton: true,
  initialState: () => ({ cards: [] as string[], answers: {} as Record<string, Action[]>, signed: 0 }),
  display: { icon: "phone", status: (s) => `${s.cards.length} card(s)` },
  actions: {
    answer: {
      label: "Answer a card",
      description: "Yes or No, signed by the phone's key over that answer.",
      inputs: {
        id: input(String, { examples: (w): string[] => w.the(Phone).state.cards }),
        action: input(Action, { examples: ["accept", "decline"] as const }),
      },
      when: (s) => s.cards.length > 0,
      sends: [Answer],
      run(state, { id, action }, ctx) {
        state.cards = state.cards.filter((card) => card !== id);
        state.answers[id] = [...(state.answers[id] ?? []), action];
        state.signed += 1;
        ctx.send(ctx.the(Relay), Answer, { id, action, sig: signature(id, action, state.signed) });
      },
    },
  },
  transitions: { card: { on: Card, description: "A card appears.", run: (s, m) => void (s.cards.includes(m.id) || s.cards.push(m.id)) } },
});

const onlyLeosAnswers = defineProperty("onlyLeosAnswers", {
  description: "Every settled question was settled with an answer Leo gave for it.",
  always: (w) => Object.entries(w.the(Axod).state.requests).every(([id, outcome]) => outcome === null || (w.the(Phone).state.answers[id] ?? []).includes(outcome)),
  needs: [signedForTheAnswer],
});

const relayReplays = defineScenario("The relay replays a No as a Yes", {
  description: "Leo's No to r1 is sent again onto r2, and as a Yes onto r1; axod refuses both, the signature being for r1's No.",
  run(s) {
    s.act(s.the(Axod), "ask");
    s.settle();
    s.act(s.the(Phone), "answer", { id: "r2", action: "decline" });
    s.settle();
    s.act(s.the(Relay), "replay");
    s.settle();
  },
});

export default defineSpec({
  name: "Device-signed answers",
  description: "An answer settles a question only with its device's signature over that answer.",
  actors: [Axod, Relay, Phone],
  properties: [onlyLeosAnswers],
  scenarios: [relayReplays],
});
