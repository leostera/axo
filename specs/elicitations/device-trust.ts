import { atMost, defineActor, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone, input, nullable, oneOf } from "@leostera/feynman";

// RFD0029, Every remote answer is signed. The phone (and the browser) holds a device key and
// signs each answer over the request's id, the action and the sealed values. axod takes an answer
// only with a good signature from a key the person allowed at the Mac, in Axo.app, after seeing
// the same fingerprint there as on the device. The cloud is the adversary: it forges answers with
// a key of its own, replays a signature onto another request, and turns a No into a Yes.
//
// Built: everything here (step 5).

const Action = oneOf("accept", "decline");
type Action = "accept" | "decline";

const Card = defineMessage("Card", { id: String }, { name: "axo.elicitation.requested", over: "relay" });
const Answer = defineMessage("Answer", { id: String, action: Action, key: String, sig: String }, { name: "axo.elicitation.resolve", over: "relay" });
const Refused = defineMessage("Refused", { id: String, fingerprint: nullable(String) }, { name: "its error", over: "relay", tone: "reply" });
const DeviceAsks = defineMessage("DeviceAsks", { key: String }, { name: "device.requested", over: "axod.sock" });
const Trust = defineMessage("Trust", { key: String }, { name: "axo.device.trust", over: "axod.sock" });

const mac = defineZone({ name: "Studio", description: "the Mac that asks" });
const cloud = defineZone({ name: "Cloud", place: { column: 1 } });
const phone = defineZone({ name: "Leo's iPhone", place: { column: 2 } });

const signedForTheAnswer = defineRule("signedForTheAnswer", { description: "A signature covers the request's id, the action and the sealed values: it is good for that answer only." });
const burnRefused = defineRule("burnRefused", { description: "A signature axod refused, because its device was not yet allowed, never counts later: the person answers again once the device is allowed (signatures are randomized, so a new answer has a new one)." });
const trustAtTheMac = defineRule("trustAtTheMac", { description: "axod takes answers only from keys the person allowed in Axo.app at the Mac; a key it has not seen is held for that, never trusted on first use." });

const PHONE_KEY = "phone-key";
const CLOUD_KEY = "cloud-key";
/** `n` stands for the randomness in each ECDSA signature: no two are the same. */
const signature = (key: string, id: string, action: Action, n: number) => (signedForTheAnswer.on ? `${key}/${id}/${action}#${n}` : `${key}#${n}`);
const signs = (sig: string, key: string, id: string, action: Action) => (signedForTheAnswer.on ? sig.startsWith(`${key}/${id}/${action}#`) : sig.startsWith(`${key}#`));
const fingerprint = (key: string) => `fp(${key})`;

export const Axod = defineActor({
  name: "Studio axod",
  description: "Asks two questions, and settles each with the first answer it accepts.",
  zone: mac,
  singleton: true,
  initialState: () => ({ requests: { r1: null, r2: null } as Record<string, Action | null>, trusted: [] as string[], pending: [] as string[], burned: [] as string[], untrustedSigs: [] as string[], settledBy: {} as Record<string, string> }),
  display: {
    icon: "server",
    rows: (s) => [
      ...Object.entries(s.requests).map(([id, outcome]) => ({ label: id, detail: outcome ?? "waiting", mood: "info" as const })),
      ...s.trusted.map((key) => ({ label: "trusted", detail: key, mood: key === PHONE_KEY ? ("ok" as const) : ("bad" as const) })),
    ],
  },
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
      description: "Takes a signed answer from a trusted key; holds an unknown key for the person at the Mac.",
      sources: ["crates/axo-server/src/session/devices.rs#SessionManager.check_answer", "crates/axo-seal/src/lib.rs#verify_answer"],
      sends: [Refused, DeviceAsks],
      run(state, m, ctx) {
        if (!(m.id in state.requests) || state.requests[m.id] !== null) return ctx.note("Already answered.");
        if (state.burned.includes(m.sig)) return ctx.reply(Refused, { id: m.id, fingerprint: null });
        if (!state.trusted.includes(m.key)) {
          if (!state.untrustedSigs.includes(m.sig)) state.untrustedSigs.push(m.sig);
          if (burnRefused.on) state.burned.push(m.sig);
          if (trustAtTheMac.on) {
            if (!state.pending.includes(m.key)) {
              state.pending.push(m.key);
              ctx.send(ctx.the(MacApp), DeviceAsks, { key: m.key });
            }
            return ctx.reply(Refused, { id: m.id, fingerprint: fingerprint(m.key) });
          }
          state.trusted.push(m.key);
        }
        if (!signs(m.sig, m.key, m.id, m.action)) return ctx.reply(Refused, { id: m.id, fingerprint: null });
        state.requests[m.id] = m.action;
        state.settledBy[m.id] = m.sig;
      },
    },
    trust: {
      on: Trust,
      description: "Axo.app, by code signature, allows a key the person compared.",
      sources: ["crates/axo-server/src/session/devices.rs#add_methods"],
      run(state, m) {
        state.pending = state.pending.filter((key) => key !== m.key);
        if (!state.trusted.includes(m.key)) state.trusted.push(m.key);
      },
    },
  },
});

export const Relay = defineActor({
  name: "The cloud",
  description: "Passes cards and answers on, and may forge, replay or change answers.",
  zone: cloud,
  singleton: true,
  initialState: () => ({ seen: [] as { id: string; action: Action; key: string; sig: string }[] }),
  display: { icon: "cloud", status: (s) => `${s.seen.length} answer(s) seen` },
  actions: {
    forge: {
      with: [atMost(1)],
      label: "Forge a Yes",
      description: "Answers a question Yes with a key of its own, signed properly by that key.",
      inputs: { id: input(String, { examples: ["r1", "r2"] }) },
      sends: [Answer],
      run(_s, { id }, ctx) {
        ctx.send(ctx.the(Axod), Answer, { id, action: "accept", key: CLOUD_KEY, sig: signature(CLOUD_KEY, id, "accept", 0) });
      },
    },
    replay: {
      with: [atMost(1)],
      label: "Replay a signature",
      description: "Sends the last answer it saw from the phone again, onto the other request and as a Yes.",
      when: (s) => s.seen.length > 0,
      sends: [Answer],
      run(state, _i, ctx) {
        const seen = state.seen[0]!;
        const other = seen.id === "r1" ? "r2" : "r1";
        ctx.send(ctx.the(Axod), Answer, { id: other, action: "accept", key: seen.key, sig: seen.sig });
        ctx.send(ctx.the(Axod), Answer, { id: seen.id, action: "accept", key: seen.key, sig: seen.sig });
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
    refused: { on: Refused, description: "Passes the refusal back to the phone.", sends: [Refused], run: (_s, m, ctx) => ctx.send(ctx.the(Phone), Refused, m) },
  },
});

export const Phone = defineActor({
  name: "Leo's iPhone",
  description: "Leo answers each card; the Secure Enclave key signs it.",
  zone: phone,
  singleton: true,
  initialState: () => ({ cards: [] as string[], answers: {} as Record<string, Action[]>, showing: null as string | null, signed: 0 }),
  display: { icon: "phone", status: (s) => (s.showing ? `shows ${s.showing}` : `${s.cards.length} card(s)`) },
  actions: {
    answer: {
      label: "Answer a card",
      description: "Yes or No, signed by the phone's key; the phone shows its fingerprint if the Mac does not know it yet.",
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
        ctx.send(ctx.the(Relay), Answer, { id, action, key: PHONE_KEY, sig: signature(PHONE_KEY, id, action, state.signed) });
      },
    },
  },
  transitions: {
    card: { on: Card, description: "A card appears.", run: (s, m) => void (s.cards.includes(m.id) || s.cards.push(m.id)) },
    refused: {
      on: Refused,
      description: "Not yet allowed at the Mac: the phone shows its own key's fingerprint, and Leo can answer again once he has.",
      run(state, m) {
        if (m.fingerprint !== fingerprint(PHONE_KEY)) return;
        state.showing = m.fingerprint;
        if (!state.cards.includes(m.id)) state.cards.push(m.id);
      },
    },
  },
});

export const MacApp = defineActor({
  name: "Axo.app",
  description: "Shows a device that wants to answer, with its fingerprint; Leo allows it only if his phone shows the same.",
  zone: mac,
  singleton: true,
  initialState: () => ({ asking: [] as string[] }),
  display: { icon: "laptop", status: (s) => `${s.asking.length} device(s) asking` },
  actions: {
    allow: {
      label: "Allow a device",
      description: "Leo compares the fingerprint with the one his phone shows, and allows it if they match.",
      inputs: { key: input(String, { examples: (w): string[] => w.the(MacApp).state.asking }) },
      when: (s) => s.asking.length > 0,
      sends: [Trust],
      run(state, { key }, ctx) {
        state.asking = state.asking.filter((k) => k !== key);
        if (ctx.the(Phone).state.showing === fingerprint(key)) ctx.send(ctx.the(Axod), Trust, { key });
      },
    },
  },
  transitions: { deviceAsks: { on: DeviceAsks, description: "A card: a device wants to answer.", run: (s, m) => void s.asking.push(m.key) } },
});

const onlyLeosAnswers = defineProperty("onlyLeosAnswers", {
  description: "Every settled question was settled with an answer Leo gave for it on his phone.",
  always: (w) => Object.entries(w.the(Axod).state.requests).every(([id, outcome]) => outcome === null || (w.the(Phone).state.answers[id] ?? []).includes(outcome)),
  needs: [signedForTheAnswer, trustAtTheMac],
});
const nothingFromBeforeTrust = defineProperty("nothingFromBeforeTrust", {
  description: "No question is settled by an answer axod refused when it came, because its device was not yet allowed.",
  always: (w) => Object.values(w.the(Axod).state.settledBy).every((sig) => !w.the(Axod).state.untrustedSigs.includes(sig)),
  needs: [burnRefused],
});
const onlyHisKey = defineProperty("onlyHisKey", {
  description: "axod trusts no key but the phone's.",
  always: (w) => w.the(Axod).state.trusted.every((key) => key === PHONE_KEY),
  needs: [trustAtTheMac],
});

const firstAnswer = defineScenario("A new phone answers", {
  description: "The phone answers before the Mac knows it: refused, it shows its fingerprint; Leo allows it at the Mac, answers again, and it counts.",
  run(s) {
    s.act(s.the(Axod), "ask");
    s.settle();
    s.act(s.the(Phone), "answer", { id: "r1", action: "decline" });
    s.settle();
    s.act(s.the(MacApp), "allow", { key: PHONE_KEY });
    s.settle();
    s.act(s.the(Phone), "answer", { id: "r1", action: "decline" });
    s.settle();
  },
});
const cloudReplays = defineScenario("The cloud replays a No as a Yes", {
  description: "Leo's No to r1 is replayed as a Yes onto r1 and r2; axod refuses both, the signature being for r1's No.",
  run(s) {
    s.act(s.the(Axod), "ask");
    s.settle();
    s.act(s.the(Phone), "answer", { id: "r1", action: "decline" });
    s.settle();
    s.act(s.the(MacApp), "allow", { key: PHONE_KEY });
    s.act(s.the(Phone), "answer", { id: "r1", action: "decline" });
    s.settle();
    s.act(s.the(Relay), "replay");
    s.settle();
  },
});

export default defineSpec({
  name: "Device-signed answers",
  description: "Only answers signed by a device the person allowed at the Mac settle a question, each signature for one answer.",
  actors: [Axod, Relay, Phone, MacApp],
  properties: [onlyLeosAnswers, onlyHisKey, nothingFromBeforeTrust],
  scenarios: [firstAnswer, cloudReplays],
});
