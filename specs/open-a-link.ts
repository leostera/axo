import { atMost, budget, crash, defineActor, defineGroup, defineLimit, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone, duplicate, input, lose, nullable, oneOf } from "@leostera/feynman";

// RFD0029, "Opening a link for the person": a terminal sign-in (`wrangler login`) wants a
// browser. The person is away, so axod sends the link to their phone or the web app; they sign
// in there, and the provider's loopback redirect (`http://localhost:8976/callback?code=…`),
// which would point at the wrong machine, is sealed and carried back to the Mac, where axod
// makes that GET to the command itself.
//
// What can go wrong, and is modelled:
// - a page in the sheet sends it to another local service (`localhost:3000/reset`);
// - the command gives up and the agent binds its port to catch the code;
// - the cloud loses or duplicates a callback, and axod restarts;
// - the person signs in twice, on the phone and on the web.
//
// Not built yet: no step has sources.

/** Faults on one path (RFD0012). `--set faults=2` raises it. */
const faults = budget("faults", 1);

const LOGIN_PORT = 8976;
const ADMIN_PORT = 3000;
const SITE = "dash.cloudflare.com";

type Holder = "wrangler" | "agent" | "admin";
type Callback = { port: number; path: string; code: string; state: string };

const Outcome = oneOf("opened", "failed", "expired");

// The Mac's loopback interface.
const Bind = defineMessage("Bind", { port: Number }, { name: "listen", over: "loopback" });
const Bound = defineMessage("Bound", { ok: Boolean }, { name: "listening", over: "loopback", tone: "reply" });
const Unbind = defineMessage("Unbind", { port: Number }, { name: "close", over: "loopback" });
const Get = defineMessage("Get", { id: String, port: Number, path: String, code: String, state: String, expect: nullable(String) }, { name: "GET /callback", over: "loopback" });
const Delivered = defineMessage("Delivered", { id: String, to: nullable(String) }, { name: "GET result", over: "loopback", tone: "reply" });
const Printed = defineMessage("Printed", { state: String }, { name: "terminal output: the link", over: "pty" });
const Output = defineMessage("Output", { state: String }, { name: "the link, in the terminal axod runs", over: "pty" });
const Exited = defineMessage("Exited", {}, { name: "terminal output: timed out", over: "pty" });
const Hit = defineMessage("Hit", { path: String, code: String, state: String }, { name: "GET", over: "loopback" });

// Asking the person.
const ShimOpen = defineMessage("ShimOpen", { site: String, port: Number, path: String, state: String }, { name: "axod-open <link>", over: "axod.sock" });
const RequestLink = defineMessage("RequestLink", { site: String, port: Number, path: String, state: String }, { name: "request_link", over: "axod.sock" });
const LinkDone = defineMessage("LinkDone", { outcome: Outcome, callback: nullable(String) }, { name: "request_link result", over: "axod.sock", tone: "reply" });
const Requested = defineMessage("Requested", { id: String, site: String, port: Number, path: String, state: String }, { name: "axo.ask.requested (link)", over: "relay" });
const Resolved = defineMessage("Resolved", { id: String }, { name: "axo.ask.resolved", over: "relay" });
const RemoteCallback = defineMessage("RemoteCallback", { id: String, sealed: String }, { name: "callback", over: "wss" });
const ForwardedCallback = defineMessage("ForwardedCallback", { id: String, sealed: String }, { name: "callback", over: "relay" });

const mac = defineZone({ name: "Studio", description: "the Mac the agent runs on" });
const cloud = defineZone({ name: "Cloudflare", description: "relays, never decides", place: { column: 1, region: true } });
const away = defineZone({ name: "Where Leo is", place: { column: 2 } });

const expiry = defineLimit({ name: "A link request expires after", value: 10, unit: "minutes" });

const sealedCallbacks = defineRule("sealedCallbacks", { description: "Clients seal the callback address to the Mac's request key; the cloud relays only ciphertext." });
const ownerOnConnect = defineRule("ownerOnConnect", { description: "axod checks who holds the port on the connection it sends the callback over, not before: the holder must be the process that opened the link." });
const once = defineRule("once", { description: "axod forwards one callback per request, and records that in axo.db before sending it, so a restart does not forget it." });
const openerFromOutput = defineRule("openerFromOutput", { description: "A link the agent passes on must appear in the output of a Session terminal axod runs; the process that printed it is the one the callback may go to." });
const outcomeOnly = defineRule("outcomeOnly", { description: "request_link returns the outcome, never the callback address, which carries the authorization code." });

/** Stands in for HPKE to the Mac's request key: only axod can read it. */
const seal = (c: Callback) => (sealedCallbacks.on ? `hpke:${btoa(JSON.stringify(c))}` : JSON.stringify(c));
const unseal = (s: string): Callback => JSON.parse(s.startsWith("hpke:") ? atob(s.slice(5)) : s);

type LinkRequest = { site: string; port: number; path: string; state: string; opener: Holder | null; forBy: "agent" | null; forwarded: boolean; code: string | null; outcome: null | "opened" | "failed" | "expired" };

export const Wrangler = defineActor({
  name: "wrangler login",
  description: "A command in the Session's terminal: it listens on localhost:8976, opens the sign-in link, and waits for the provider's redirect.",
  zone: mac,
  singleton: true,
  initialState: () => ({ phase: "idle" as "idle" | "binding" | "listening" | "signedIn" | "gaveUp", state: "", got: 0 }),
  display: {
    icon: "terminal",
    status: (s) => ({ idle: "not started", binding: "starting", listening: "waiting for the browser", signedIn: "signed in", gaveUp: "gave up" })[s.phase],
    mood: (s) => (s.phase === "signedIn" ? "ok" : s.phase === "gaveUp" ? "off" : "busy"),
  },
  actions: {
    login: {
      with: [atMost(1)],
      label: "Run wrangler login",
      description: "The agent runs wrangler login; it listens on localhost:8976 first.",
      when: (s) => s.phase === "idle",
      sends: [Bind],
      run(state, _i, ctx) {
        state.phase = "binding";
        state.state = ctx.fresh("state");
        ctx.send(ctx.the(Loopback), Bind, { port: LOGIN_PORT });
      },
    },
    giveUp: {
      with: [atMost(1)],
      label: "Time out",
      description: "Nobody signed in in time: wrangler exits and frees its port.",
      when: (s) => s.phase === "listening",
      sends: [Unbind, Exited],
      run(state, _i, ctx) {
        state.phase = "gaveUp";
        ctx.send(ctx.the(Loopback), Unbind, { port: LOGIN_PORT });
        ctx.send(ctx.the(Agent), Exited, {});
      },
    },
  },
  transitions: {
    bound: {
      on: Bound,
      description: "Listening: it prints the link and opens it, which reaches axod through the axod-open shim.",
      sends: [ShimOpen, Printed, Output],
      run(state, m, ctx) {
        if (!m.ok) return void (state.phase = "gaveUp");
        state.phase = "listening";
        ctx.send(ctx.the(Agent), Printed, { state: state.state });
        ctx.send(ctx.the(Axod), Output, { state: state.state });
        ctx.send(ctx.the(Axod), ShimOpen, { site: SITE, port: LOGIN_PORT, path: "/oauth/callback", state: state.state });
      },
    },
    hit: {
      on: Hit,
      description: "The redirect arrives: with the state it sent, it exchanges the code (with its PKCE verifier) and is signed in.",
      sends: [Unbind],
      run(state, m, ctx) {
        state.got += 1;
        if (state.phase !== "listening" || m.state !== state.state) return ctx.note("Not the redirect it is waiting for.");
        state.phase = "signedIn";
        ctx.send(ctx.the(Loopback), Unbind, { port: LOGIN_PORT });
      },
    },
  },
});

export const Agent = defineActor({
  name: "Studio agent",
  description: "The Session's agent: it may pass on a link it read in the terminal, and, if prompt-injected, try to catch the code itself.",
  zone: mac,
  singleton: true,
  initialState: () => ({ waiting: false, outcomes: [] as string[], caught: [] as string[], listening: false, link: null as string | null, wranglerExited: false }),
  display: {
    icon: "robot",
    status: (s) => (s.waiting ? "waiting for the person" : s.listening ? "listening on 8976" : "working"),
    mood: (s) => (s.caught.length ? "bad" : s.waiting ? "busy" : "ok"),
    rows: (s) => s.caught.map((c) => ({ label: "caught", detail: c, mood: "bad" as const })),
  },
  actions: {
    passLink: {
      with: [atMost(1)],
      label: "Pass the link on",
      description: "The agent reads the link wrangler printed and calls request_link with it.",
      when: (s) => !s.waiting && s.link !== null,
      sends: [RequestLink],
      run(state, _i, ctx) {
        state.waiting = true;
        ctx.send(ctx.the(Axod), RequestLink, { site: SITE, port: LOGIN_PORT, path: "/oauth/callback", state: state.link! });
      },
    },
    takePort: {
      with: [atMost(1)],
      label: "Listen on 8976",
      description: "Once wrangler has exited, the agent listens on its port, hoping the callback comes to it.",
      when: (s) => !s.listening && s.wranglerExited,
      sends: [Bind],
      run: (_s, _i, ctx) => ctx.send(ctx.the(Loopback), Bind, { port: LOGIN_PORT }),
    },
  },
  transitions: {
    printed: { on: Printed, description: "It reads the link in wrangler's output.", run: (s, m) => void (s.link = m.state) },
    exited: { on: Exited, description: "It sees wrangler time out.", run: (s) => void (s.wranglerExited = true) },
    bound: { on: Bound, description: "Now it holds the port.", run: (s, m) => void (s.listening = m.ok) },
    hit: { on: Hit, description: "A GET reaches the agent's listener.", run: (s, m) => void (m.code && s.caught.push(m.code)) },
    done: {
      on: LinkDone,
      description: "request_link returns.",
      run(s, m) {
        s.waiting = false;
        s.outcomes.push(m.outcome);
        if (m.callback) s.caught.push(m.callback);
      },
    },
  },
});

export const Admin = defineActor({
  name: "Local admin on :3000",
  description: "A dev server on the Mac whose GET /reset wipes its data: a target for a forged callback.",
  zone: mac,
  singleton: true,
  initialState: () => ({ hits: [] as string[] }),
  display: { icon: "server", status: (s) => (s.hits.length ? `hit: ${s.hits.join(", ")}` : "untouched"), mood: (s) => (s.hits.length ? "bad" : "ok") },
  transitions: { hit: { on: Hit, description: "Runs whatever the GET asks.", run: (s, m) => void s.hits.push(m.path) } },
});

export const Loopback = defineActor({
  name: "127.0.0.1",
  description: "The Mac's loopback: one listener per port, and a GET goes to whoever holds the port when it connects.",
  zone: mac,
  singleton: true,
  initialState: () => ({ holders: { [LOGIN_PORT]: null, [ADMIN_PORT]: "admin" } as Record<number, Holder | null>, delivered: [] as string[] }),
  display: {
    icon: "router",
    status: (s) => `8976: ${s.holders[LOGIN_PORT] ?? "free"}`,
    rows: (s) => s.delivered.map((d) => ({ label: "callback", detail: d, mood: "info" as const })),
  },
  transitions: {
    bind: {
      on: Bind,
      description: "Takes the port if it is free.",
      sends: [Bound],
      run(state, m, ctx) {
        const who: Holder = ctx.from.id === ctx.the(Agent).id ? "agent" : "wrangler";
        const ok = state.holders[m.port] === null;
        if (ok) state.holders[m.port] = who;
        ctx.reply(Bound, { ok });
      },
    },
    unbind: { on: Unbind, description: "Frees the port.", run: (s, m) => void (s.holders[m.port] = null) },
    get: {
      on: Get,
      description: "axod connects and sends the GET; with an expected holder, it sends nothing to anyone else.",
      sends: [Hit, Delivered],
      run(state, m, ctx) {
        const holder = state.holders[m.port] ?? null;
        if (!holder || (m.expect !== null && holder !== m.expect)) return ctx.reply(Delivered, { id: m.id, to: null }, holder ? `${holder} holds the port, not ${m.expect}` : "nobody listens");
        state.delivered.push(m.id);
        const to = holder === "wrangler" ? ctx.the(Wrangler) : holder === "agent" ? ctx.the(Agent) : ctx.the(Admin);
        ctx.send(to, Hit, { path: m.path, code: m.code, state: m.state });
        ctx.reply(Delivered, { id: m.id, to: holder });
      },
    },
  },
});

export const Axod = defineActor({
  name: "Studio axod",
  description: "Turns an opened link into a request for the person, and carries the sealed callback back to the command.",
  zone: mac,
  singleton: true,
  initialState: () => ({ requests: {} as Record<string, LinkRequest>, printedBy: {} as Record<string, Holder>, booted: false }),
  display: {
    icon: "cpu",
    status: (s) => {
      const open = Object.values(s.requests).filter((r) => r.outcome === null).length;
      return open ? `${open} link(s) waiting for the person` : "nothing waiting";
    },
    rows: (s) => Object.values(s.requests).map((r) => ({ label: `${r.site} (${r.forBy ?? "axod-open"})`, detail: r.outcome ?? (r.forwarded ? "forwarding" : "pending"), mood: r.outcome === "opened" ? ("ok" as const) : r.outcome ? ("off" as const) : ("busy" as const) })),
  },
  transitions: {
    boot: {
      description: "axod starts, or restarts after a crash: requests nobody answered before it went down expire, since their timers are gone.",
      when: (s) => !s.booted,
      sends: [Resolved, LinkDone],
      run(state, _i, ctx) {
        state.booted = true;
        for (const [id, r] of Object.entries(state.requests)) if (r.outcome === null && !r.forwarded) finish(state, ctx, id, "expired");
      },
    },
    shimOpen: {
      on: ShimOpen,
      description: "A command opened a link and the person is away: a link request, naming the command that opened it.",
      sends: [Requested],
      starts: ["expire"],
      run: (state, m, ctx) => ask(state, ctx, m, "wrangler", null),
    },
    output: { on: Output, description: "Notes which process printed which link.", run: (s, m) => void (s.printedBy[m.state] = "wrangler") },
    requestLink: {
      on: RequestLink,
      description: "The agent passed a link on: a link request naming the process that printed it, or a refusal if none did.",
      sends: [Requested, LinkDone],
      starts: ["expire"],
      run(state, m, ctx) {
        // Without the rule, axod trusts whoever holds the redirect's port when the agent asks.
        const opener = openerFromOutput.on ? (state.printedBy[m.state] ?? null) : (ctx.the(Loopback).state.holders[m.port] ?? null);
        if (!opener) return ctx.reply(LinkDone, { outcome: "failed", callback: null }, "No Session terminal printed that link.");
        ask(state, ctx, m, opener, "agent");
      },
    },
    callback: {
      on: ForwardedCallback,
      description: "Opens the sealed callback, checks it against the request, and makes the GET.",
      sends: [Get],
      run(state, m, ctx) {
        const request = state.requests[m.id];
        if (!request || request.outcome !== null) return ctx.note("Not pending.");
        if (once.on && request.forwarded) return ctx.note("Already forwarded one callback.");
        const c = unseal(m.sealed);
        // A check made here, before connecting, catches a page that sent the sheet to another
        // local service; but it can be stale by the time the GET lands.
        if (ctx.the(Loopback).state.holders[c.port] !== request.opener) return ctx.note("Refused: the port is not held by the process that opened the link.");
        request.forwarded = true;
        request.code = c.code;
        ctx.send(ctx.the(Loopback), Get, { id: m.id, port: c.port, path: c.path, code: c.code, state: c.state, expect: ownerOnConnect.on ? request.opener : null });
      },
    },
    delivered: {
      on: Delivered,
      description: "The command got its redirect, or nobody right was listening.",
      sends: [Resolved, LinkDone],
      run: (state, m, ctx) => finish(state, ctx, m.id, m.to ? "opened" : "failed", state.requests[m.id]?.code ?? null),
    },
    expire: {
      description: "Nobody signed in in time.",
      after: "10 minutes",
      sends: [Resolved, LinkDone],
      starts: ["expire"],
      run(state, _m, ctx) {
        // One deadline per request in axod; here one timer, set again while another request waits.
        const pending = Object.entries(state.requests).filter(([, r]) => r.outcome === null && !r.forwarded);
        const open = pending[0];
        if (open) finish(state, ctx, open[0], "expired");
        if (pending.length > 1) ctx.start("expire");
      },
    },
    callbackLost: lose(ForwardedCallback, { spend: faults }),
    callbackTwice: duplicate(ForwardedCallback, { spend: faults }),
    crash: crash({ keeps: ["requests", "printedBy"], spend: faults }),
  },
});

type AxodState = { requests: Record<string, LinkRequest>; printedBy: Record<string, Holder>; booted: boolean };

function ask(state: AxodState, ctx: any, m: { site: string; port: number; path: string; state: string }, opener: Holder | null, forBy: "agent" | null) {
  const id = ctx.fresh("link");
  state.requests[id] = { ...m, opener, forBy, forwarded: false, code: null, outcome: null };
  ctx.send(ctx.the(HostDO), Requested, { id, ...m });
  ctx.start("expire");
}

function finish(state: AxodState, ctx: any, id: string, outcome: "opened" | "failed" | "expired", callback: string | null = null) {
  const request = state.requests[id];
  if (!request || request.outcome !== null) return;
  request.outcome = outcome;
  ctx.send(ctx.the(HostDO), Resolved, { id });
  if (request.forBy === "agent") ctx.send(ctx.the(Agent), LinkDone, { outcome, callback: outcomeOnly.on ? null : callback });
}

export const HostDO = defineActor({
  name: "HostDO",
  description: "Relays link requests to the person's clients and their callbacks back; keeps what it relays.",
  zone: cloud,
  singleton: true,
  initialState: () => ({ relayed: [] as string[] }),
  display: { icon: "cloud", status: (s) => `${s.relayed.length} callback(s) relayed`, rows: (s) => s.relayed.map((v) => ({ label: "relayed", detail: v, mood: v.includes("code-") ? ("bad" as const) : ("info" as const) })) },
  transitions: {
    requested: {
      on: Requested,
      description: "Sends the card to the phone (with a push) and the web app.",
      sends: [Requested],
      run(_s, m, ctx) {
        ctx.send(ctx.the(Phone), Requested, m);
        ctx.send(ctx.the(Web), Requested, m);
      },
    },
    callback: {
      on: RemoteCallback,
      description: "Forwards a client's callback to the Mac as it came.",
      sends: [ForwardedCallback],
      run(state, m, ctx) {
        state.relayed.push(m.sealed);
        ctx.send(ctx.the(Axod), ForwardedCallback, m);
      },
    },
    resolved: {
      on: Resolved,
      description: "Withdraws the cards.",
      sends: [Resolved],
      run(_s, m, ctx) {
        ctx.send(ctx.the(Phone), Resolved, m);
        ctx.send(ctx.the(Web), Resolved, m);
      },
    },
  },
});

type Card = { site: string; port: number; path: string; state: string; open: boolean };
const cardIds = (s: { cards: Record<string, Card> }, open?: boolean) => Object.entries(s.cards).filter(([, c]) => open === undefined || c.open === open).map(([id]) => id);

export const Phone = defineActor({
  name: "Leo's iPhone",
  description: "A push, then a card; Open slides up a browser sheet that watches where it is sent.",
  zone: away,
  singleton: true,
  initialState: () => ({ cards: {} as Record<string, Card>, done: [] as string[] }),
  display: {
    icon: "phone",
    status: (s) => (cardIds(s, true).length ? "signing in" : cardIds(s).length ? "sign-in to open" : "nothing to answer"),
    mood: (s) => (cardIds(s).length ? "warn" : "ok"),
    rows: (s) => Object.values(s.cards).map((c) => ({ label: c.open ? "sheet open" : "Sign in to", detail: c.site, mood: "warn" as const })),
  },
  actions: {
    open: {
      label: "Open",
      description: "Leo taps Open: the sheet loads the link.",
      inputs: { id: input(String, { examples: (w): string[] => cardIds(w.the(Phone).state, false) }) },
      when: (s) => cardIds(s, false).length > 0,
      run: (s, { id }) => void (s.cards[id] && (s.cards[id].open = true)),
    },
    signIn: {
      label: "Sign in",
      description: "Leo signs in with a passkey; the provider redirects the sheet to localhost, which the sheet catches, seals and sends instead of loading.",
      inputs: { id: input(String, { examples: (w): string[] => cardIds(w.the(Phone).state, true) }) },
      when: (s) => cardIds(s, true).length > 0,
      sends: [RemoteCallback],
      run(s, { id }, ctx) {
        const card = s.cards[id];
        if (!card) return;
        delete s.cards[id];
        ctx.send(ctx.the(HostDO), RemoteCallback, { id, sealed: seal({ port: card.port, path: card.path, code: ctx.fresh("code"), state: card.state }) });
      },
    },
    pageRedirects: {
      with: [atMost(1)],
      label: "The page sends the sheet to :3000",
      description: "A page in the sheet (a look-alike, or an injected script) sends it to http://localhost:3000/reset.",
      inputs: { id: input(String, { examples: (w): string[] => cardIds(w.the(Phone).state, true) }) },
      when: (s) => cardIds(s, true).length > 0,
      sends: [RemoteCallback],
      run(s, { id }, ctx) {
        delete s.cards[id];
        ctx.send(ctx.the(HostDO), RemoteCallback, { id, sealed: seal({ port: ADMIN_PORT, path: "/reset", code: "", state: "" }) });
      },
    },
  },
  transitions: {
    requested: { on: Requested, description: "The card shows, unless already resolved.", run: (s, m) => void (s.done.includes(m.id) || (s.cards[m.id] = { site: m.site, port: m.port, path: m.path, state: m.state, open: false })) },
    resolved: {
      on: Resolved,
      description: "The card and any open sheet go away.",
      run(s, m) {
        delete s.cards[m.id];
        s.done.push(m.id);
      },
    },
  },
});

export const Web = defineActor({
  name: "Leo's laptop (web)",
  description: "The web app: Open makes a new tab; the tab ends on a page that can't reach localhost, whose address Leo pastes into the card.",
  zone: away,
  singleton: true,
  initialState: () => ({ cards: {} as Record<string, Card>, done: [] as string[] }),
  display: { icon: "browser", status: (s) => (cardIds(s).length ? "sign-in to open" : "nothing to answer"), mood: (s) => (cardIds(s).length ? "warn" : "ok") },
  actions: {
    pasteAddress: {
      with: [atMost(1)],
      label: "Sign in and paste the address",
      description: "Leo signs in in a new tab and pastes the localhost address it ended on; the card seals it.",
      inputs: { id: input(String, { examples: (w): string[] => cardIds(w.the(Web).state) }) },
      when: (s) => cardIds(s).length > 0,
      sends: [RemoteCallback],
      run(s, { id }, ctx) {
        const card = s.cards[id];
        if (!card) return;
        delete s.cards[id];
        ctx.send(ctx.the(HostDO), RemoteCallback, { id, sealed: seal({ port: card.port, path: card.path, code: ctx.fresh("code"), state: card.state }) });
      },
    },
  },
  transitions: {
    requested: { on: Requested, description: "The card shows, unless already resolved.", run: (s, m) => void (s.done.includes(m.id) || (s.cards[m.id] = { site: m.site, port: m.port, path: m.path, state: m.state, open: false })) },
    resolved: {
      on: Resolved,
      description: "The card goes away.",
      run(s, m) {
        delete s.cards[m.id];
        s.done.push(m.id);
      },
    },
  },
});

const studio = defineGroup({ name: "Studio", actors: [Wrangler, Agent, Admin, Loopback, Axod], icon: "laptop", collapsed: false });

const codeOnlyToTheOpener = defineProperty("codeOnlyToTheOpener", {
  description: "An authorization code reaches only the process that opened the link: not a listener the agent put on the port after it, and not request_link's result.",
  always: (w) => w.the(Agent).state.caught.length === 0,
  needs: [ownerOnConnect, outcomeOnly, openerFromOutput],
});
const codeNeverInTheCloud = defineProperty("codeNeverInTheCloud", {
  description: "The cloud relays callbacks only sealed.",
  always: (w) => !w.the(HostDO).state.relayed.some((v) => v.includes("code-")),
  needs: [sealedCallbacks],
});
const onlyTheCommandIsCalled = defineProperty("onlyTheCommandIsCalled", {
  description: "A callback reaches only the command's redirect: no other local service gets a GET.",
  always: (w) => w.the(Admin).state.hits.length === 0,
});
const oneCallbackPerRequest = defineProperty("oneCallbackPerRequest", {
  description: "axod sends at most one callback per request, through lost and duplicated messages and restarts.",
  always: (w) => new Set(w.the(Loopback).state.delivered).size === w.the(Loopback).state.delivered.length,
  needs: [once],
});
const theAgentAlwaysHears = defineProperty("theAgentAlwaysHears", {
  description: "request_link always returns: opened, failed or expired.",
  leadsTo: { whenever: (w) => w.the(Agent).state.waiting, then: (w) => !w.the(Agent).state.waiting },
});

const firstCard = (cards: Record<string, Card>) => Object.keys(cards)[0]!;

const fromThePhone = defineScenario("Sign in from the phone", {
  description: "wrangler login opens its link through axod-open; Leo opens it on his iPhone and signs in; the redirect is carried back and wrangler is signed in.",
  run(s) {
    s.act(s.the(Wrangler), "login");
    s.settle({ until: (w) => Object.keys(w.the(Phone).state.cards).length > 0 });
    const id = firstCard(s.the(Phone).state.cards);
    s.act(s.the(Phone), "open", { id });
    s.act(s.the(Phone), "signIn", { id });
    s.settle({ until: (w) => w.the(Wrangler).state.phase === "signedIn" });
  },
});
const fromTheWeb = defineScenario("Sign in from the web, by pasting", {
  description: "The agent passes the printed link on; Leo signs in in a new tab on his laptop and pastes the address it ended on; request_link returns opened.",
  run(s) {
    s.act(s.the(Wrangler), "login");
    s.settle({ until: (w) => w.the(Agent).state.link !== null });
    s.act(s.the(Agent), "passLink");
    s.settle({ until: (w) => Object.keys(w.the(Web).state.cards).length > 1 });
    const id = Object.keys(s.the(Web).state.cards).at(-1)!;
    s.act(s.the(Web), "pasteAddress", { id });
    s.settle({ until: (w) => !w.the(Agent).state.waiting });
  },
});
const forgedRedirect = defineScenario("A page sends the sheet to another local service", {
  description: "The page in the sheet sends it to localhost:3000/reset; the sheet seals that like any loopback address, and axod refuses it because it is not the link's redirect.",
  run(s) {
    s.act(s.the(Wrangler), "login");
    s.settle({ until: (w) => Object.keys(w.the(Phone).state.cards).length > 0 });
    const id = firstCard(s.the(Phone).state.cards);
    s.act(s.the(Phone), "open", { id });
    s.act(s.the(Phone), "pageRedirects", { id });
    s.settle({ until: (w) => w.the(HostDO).state.relayed.length > 0 });
    s.settle();
  },
});
const portTaken = defineScenario("wrangler gives up and the agent takes its port", {
  description: "Leo signs in after wrangler timed out and the agent started listening on 8976; axod sees the port is not wrangler's and sends nothing.",
  run(s) {
    s.act(s.the(Wrangler), "login");
    s.settle({ until: (w) => Object.keys(w.the(Phone).state.cards).length > 0 });
    const id = firstCard(s.the(Phone).state.cards);
    s.act(s.the(Wrangler), "giveUp");
    s.settle({ until: (w) => w.the(Loopback).state.holders[LOGIN_PORT] === null });
    s.act(s.the(Agent), "takePort");
    s.settle({ until: (w) => w.the(Agent).state.listening });
    s.act(s.the(Phone), "open", { id });
    s.act(s.the(Phone), "signIn", { id });
    s.settle({ until: (w) => w.the(HostDO).state.relayed.length > 0 });
    s.settle();
  },
});

export default defineSpec({
  name: "Open a link",
  description: "How a terminal sign-in that wants a browser is done on the person's phone or laptop, with the loopback redirect carried back to the Mac.",
  actors: [Wrangler, Agent, Admin, Loopback, Axod, HostDO, Phone, Web],
  groups: [studio],
  limits: [expiry],
  properties: [codeOnlyToTheOpener, codeNeverInTheCloud, onlyTheCommandIsCalled, oneCallbackPerRequest, theAgentAlwaysHears],
  scenarios: [fromThePhone, fromTheWeb, forgedRedirect, portTaken],
  finalState: {
    description: "Every link request is resolved and no tool call waits.",
    when: (w) => Object.values(w.the(Axod).state.requests).every((r) => r.outcome !== null) && !w.the(Agent).state.waiting,
  },
});
