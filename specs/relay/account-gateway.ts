import { atMost, budget, crash, defineActor, defineCall, defineGroup, defineLimit, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone, failed, input, listOf, lose, oneOf } from "@leostera/feynman";

// RFD0020: the account gateway. One AxoGateway per Axo account holds every credential the account
// gave Axo for other services and makes every call to them; AxoAccountManager keeps identity and
// the account's Macs. An account that had apps in its account manager moves them to its
// gateway once, on the gateway's first request: export, store, confirm, and only then delete.
//
// Not built yet, so no step has sources. Modelled: the move, the gateway's list of the account's
// Macs (pushed by the account manager, pulled on a miss), and who calls out. Left out: how a
// script runs and its limits (apps.ts), sign-in (connection-sign-in.ts), tool lists
// (tool-lists.ts). A Session's call reaches the gateway through axod and its AxoHostDO, as in
// apps.ts; here it is one call, since that path does not change. One account (Ada's), one
// Gmail grant, a call log with one call from before the move ("c0"); the log's chain head is
// modelled as the log itself, joined, which changes whenever the log does, as a hash would.

const GRANT = "grant:ada-gmail";
const OLD_LOG = ["c0"];
const headOf = (log: readonly string[]) => (log.length ? log.join(">") : "genesis");
type Script = "gmail" | "bash:studio" | "bash:laptop";
const SCRIPTS: Script[] = ["gmail", "bash:studio", "bash:laptop"];
type Waiting = { request: string; script: Script; from: string; pulled: boolean };

/** Faults on one path: lost messages and restarts (RFD0012). `--set faults=2` raises it. */
const faults = budget("faults", 1);

// Session -> AxoGateway (through axod and the Session's AxoHostDO, as in apps.ts)
const AppsCall = defineCall("AppsCall", { request: String, script: oneOf("gmail", "bash:studio", "bash:laptop") }, { name: "axo.apps.run", over: "rpc" });
const Result = defineMessage("Result", { request: String, output: String }, { name: "execute result", over: "rpc", tone: "reply" });
const CallFailed = defineMessage("CallFailed", { request: String, error: String }, { name: "execute failed", over: "rpc", tone: "refused" });
// AxoGateway <-> AxoAccountManager (Durable Object RPC)
const ExportApps = defineCall("ExportApps", {}, { name: "exportApps", over: "rpc" });
const Snapshot = defineMessage("Snapshot", { grants: listOf(String), log: listOf(String), head: String }, { name: "snapshot", over: "rpc", tone: "reply" });
const AlreadyMoved = defineMessage("AlreadyMoved", { head: String }, { name: "moved", over: "rpc", tone: "reply" });
const NothingToMove = defineMessage("NothingToMove", {}, { name: "none", over: "rpc", tone: "reply" });
const ConfirmMoved = defineCall("ConfirmMoved", { head: String }, { name: "confirmAppsMoved", over: "rpc" });
const Confirmed = defineMessage("Confirmed", {}, { name: "deleted", over: "rpc", tone: "reply" });
const Mismatch = defineMessage("Mismatch", {}, { name: "mismatch", over: "rpc", tone: "refused" });
const GatewayMacs = defineCall("GatewayMacs", {}, { name: "gatewayMacs", over: "rpc" });
const MacsList = defineMessage("MacsList", { version: Number, macs: listOf(String) }, { name: "Macs", over: "rpc", tone: "reply" });
const MacsChanged = defineMessage("MacsChanged", { version: Number, macs: listOf(String) }, { name: "macsChanged", over: "rpc" });
// AxoAccountManager -> AxoHostDO
const Revoke = defineMessage("Revoke", {}, { name: "close 4003: host revoked", over: "rpc" });
// AxoGateway -> AxoHostDO -> the Mac
const CallHost = defineCall("CallHost", { call: String, command: String }, { name: "callHost", over: "rpc" });
const BashResult = defineMessage("BashResult", { call: String, output: String }, { name: "callHost result", over: "rpc", tone: "reply" });
const HostRefused = defineMessage("HostRefused", { call: String, error: String }, { name: "host offline; nothing sent", over: "rpc", tone: "refused" });
// AxoGateway -> Gmail
const GmailCall = defineCall("GmailCall", { call: String, grant: String }, { name: "users.messages.list", over: "https" });
const GmailResult = defineMessage("GmailResult", { call: String, output: String }, { name: "messages", over: "https", tone: "reply" });

const macs = defineZone({ name: "Ada's Macs", description: "Sessions, and each Mac's socket owner" });
const cloudflare = defineZone({ name: "Cloudflare", description: "one account manager and one gateway per account", place: { column: 1, region: true } });
const services = defineZone({ name: "Other services", description: "Google, MCP servers, later token apps", place: { column: 2 } });

const macListAge = defineLimit({ name: "Mac list pulled when older than", value: 1, unit: "minute" });

/** RFD0020, Moving apps state: the account manager deletes only when the gateway confirms the head it stored. */
const deleteOnConfirmedHead = defineRule("deleteOnConfirmedHead", {
  description: "The account manager keeps its apps until the gateway confirms it stored them, with the chain head it exported.",
});
/** RFD0013, kept by RFD0020: a revoked Mac's socket owner refuses its commands, whatever the gateway's list says. */
const hostRefusesRevoked = defineRule("hostRefusesRevoked", {
  description: "AxoHostDO sends nothing to a revoked Mac.",
});

export const Manager = defineActor({
  name: "AxoAccountManager",
  description: "The account's identity: profile, sign-ins, login codes and paired Macs. After the move it holds no credential for another service and calls none.",
  zone: cloudflare,
  singleton: true,
  initialState: () => ({
    /** Apps state from before RFD0020, until it is handed off; null once deleted. */
    conns: { grants: [GRANT], log: [...OLD_LOG] } as null | { grants: string[]; log: string[] },
    /** The head the gateway confirmed, once handed off: the record of the move. */
    handoff: null as string | null,
    macs: ["studio"] as string[],
    macsVersion: 1,
  }),
  display: {
    icon: "shield",
    status: (s) => (s.handoff ? "apps moved" : s.conns ? "holds apps" : "no apps"),
    mood: (s) => (s.handoff ? "ok" : s.conns ? "info" : "off"),
    rows: (s) => [
      ...(s.conns ? [{ group: "Apps (before the move)", label: `${s.conns.grants.length} grant(s)`, detail: `log head ${headOf(s.conns.log)}` }] : []),
      ...(s.handoff ? [{ group: "Apps", label: "handed off", detail: `head ${s.handoff}`, mood: "ok" as const }] : []),
      ...s.macs.map((m) => ({ group: "Paired Macs", label: m, detail: `list v${s.macsVersion}` })),
    ],
  },
  actions: {
    pairLaptop: {
      with: [atMost(1)],
      label: "Pair the laptop",
      description: "Ada pairs another Mac; the account manager tells the gateway its new list of Macs.",
      when: (s) => !s.macs.includes("laptop"),
      sends: [MacsChanged],
      run(state, _inputs, ctx) {
        state.macs.push("laptop");
        state.macsVersion += 1;
        ctx.send(ctx.the(Gateway), MacsChanged, { version: state.macsVersion, macs: [...state.macs] });
      },
    },
    revoke: {
      with: [atMost(1)],
      label: "Unpair a Mac",
      description: "Ada revokes a Mac: its socket owner refuses it from now on, and the gateway hears its new list of Macs.",
      inputs: { host: input(String, { examples: ["studio", "laptop"] }) },
      when: (s) => s.macs.length > 0,
      sends: [MacsChanged, Revoke],
      run(state, { host }, ctx) {
        if (!state.macs.includes(host)) return;
        state.macs = state.macs.filter((m) => m !== host);
        state.macsVersion += 1;
        const owner = ctx.all(HostDO).find((h) => h.state.host === host);
        if (owner) ctx.send(owner, Revoke, {});
        ctx.send(ctx.the(Gateway), MacsChanged, { version: state.macsVersion, macs: [...state.macs] });
      },
    },
  },
  transitions: {
    exportApps: {
      on: ExportApps,
      description: "Answers with every apps row and the chain head, keeping its copy; or says it already handed off, or that there is nothing.",
      sends: [Snapshot, AlreadyMoved, NothingToMove],
      run(state, _m, ctx) {
        if (state.conns) {
          const snapshot = { grants: [...state.conns.grants], log: [...state.conns.log], head: headOf(state.conns.log) };
          // Without the rule, the copy goes as soon as it is sent, before anything stored it.
          if (!deleteOnConfirmedHead.on) {
            state.handoff = snapshot.head;
            state.conns = null;
          }
          return ctx.reply(Snapshot, snapshot);
        }
        if (state.handoff) return ctx.reply(AlreadyMoved, { head: state.handoff });
        ctx.reply(NothingToMove, {});
      },
    },
    confirmMoved: {
      on: ConfirmMoved,
      description: "Deletes its copy and records the hand-off, together, if the head is the one it would export; a repeat of a confirmation it already acted on is acknowledged again.",
      sends: [Confirmed, Mismatch],
      run(state, m, ctx) {
        if (state.conns && headOf(state.conns.log) === m.head) {
          state.conns = null;
          state.handoff = m.head;
          return ctx.reply(Confirmed, {});
        }
        if (!state.conns && state.handoff === m.head) return ctx.reply(Confirmed, {});
        ctx.reply(Mismatch, {});
      },
    },
    gatewayMacs: {
      on: GatewayMacs,
      description: "Answers with the account's paired Macs and the list's version.",
      sends: [MacsList],
      run: (state, _m, ctx) => ctx.reply(MacsList, { version: state.macsVersion, macs: [...state.macs] }),
    },
    // Faults: what the network and restarts may do here. Its storage survives a restart.
    exportAppsLost: lose(ExportApps, { spend: faults }),
    confirmMovedLost: lose(ConfirmMoved, { spend: faults }),
    gatewayMacsLost: lose(GatewayMacs, { spend: faults }),
    crash: crash({ keeps: ["conns", "handoff", "macs", "macsVersion"], spend: faults }),
  },
});

/** The gateway's state: what it stores, and what it holds only in memory. */
function gatewayStart() {
  return {
    // Stored: survives a restart.
    imported: false,
    confirmed: false,
    importedHead: null as string | null,
    grants: [] as string[],
    log: [] as string[],
    macs: [] as string[],
    macsVersion: 0,
    /** The account manager had handed off, but this gateway had nothing: storage was lost. */
    lost: false,
    mismatch: false,
    // In memory: gone on a restart.
    moving: false,
    confirming: false,
    /** Requests waiting for the move to end, or for a fresh list of Macs. */
    waiting: [] as Waiting[],
    /** Calls sent, by call, with the request they answer. */
    dispatched: {} as Record<string, { request: string; from: string }>,
  };
}
type GatewayState = ReturnType<typeof gatewayStart>;

export const Gateway = defineActor({
  name: "AxoGateway",
  description: "The account's gateway: it holds the account's grants, runs its scripts, writes the call log first, and makes every call to another service or a Mac.",
  zone: cloudflare,
  singleton: true,
  initialState: () => gatewayStart(),
  display: {
    icon: "key",
    status: (s) => (s.lost ? "apps lost" : s.moving ? "moving apps" : !s.imported ? "not moved yet" : s.confirmed ? `${s.grants.length} grant(s), ${s.log.length} call(s) logged` : "moved, confirming"),
    mood: (s) => (s.lost || s.mismatch ? "bad" : s.moving || (s.imported && !s.confirmed) ? "busy" : s.imported ? "ok" : "off"),
    rows: (s) => [
      ...s.grants.map((g) => ({ group: "Grants (sealed)", label: g.replace(/^grant:/, ""), detail: "held here" })),
      ...(s.log.length ? [{ group: "Call log", label: `${s.log.length} record(s)`, detail: `head ${headOf(s.log)}` }] : []),
      ...s.macs.map((m) => ({ group: `Macs (list v${s.macsVersion})`, label: m })),
    ],
  },
  transitions: {
    appsCall: {
      on: AppsCall,
      description: "Takes a Session's call; before the first request is served, the gateway moves the account's apps from the account manager, and every other request waits for that.",
      sends: [ExportApps, ConfirmMoved, GmailCall, CallHost, GatewayMacs, CallFailed],
      say: (s, m) => (s.moving ? `Waiting for the move to end before ${m.script}` : `Serving ${m.script}`),
      run(state, m, ctx) {
        const request: Waiting = { request: m.request, script: m.script, from: ctx.from.id, pulled: false };
        if (state.lost) return ctx.reply(CallFailed, { request: m.request, error: "apps are unavailable" });
        if (!state.imported) {
          state.waiting.push(request);
          if (!state.moving) {
            state.moving = true;
            ctx.send(ctx.the(Manager), ExportApps, {});
          }
          return;
        }
        serve(state, request, ctx);
      },
    },
    snapshot: {
      on: Snapshot,
      description: "Stores every row and the head in one transaction, confirms the head to the account manager, and serves the requests that waited.",
      sends: [ConfirmMoved, GmailCall, CallHost, GatewayMacs, CallFailed],
      say: (_s, m) => `Stored ${m.grants.length} grant(s) and ${m.log.length} logged call(s); confirming head ${m.head}`,
      run(state, m, ctx) {
        state.moving = false;
        if (!state.imported) {
          state.grants = [...m.grants];
          state.log = [...m.log];
          state.importedHead = m.head;
          state.imported = true;
        }
        serveWaiting(state, ctx);
      },
    },
    nothingToMove: {
      on: NothingToMove,
      description: "The account never had apps: the gateway starts empty and serves.",
      sends: [ConfirmMoved, GmailCall, CallHost, GatewayMacs, CallFailed],
      run(state, _m, ctx) {
        state.moving = false;
        state.imported = true;
        state.confirmed = true;
        serveWaiting(state, ctx);
      },
    },
    alreadyMoved: {
      on: AlreadyMoved,
      description: "The account manager handed off, yet this gateway holds nothing: its storage was lost. It refuses rather than start empty and hide that.",
      sends: [ConfirmMoved, GmailCall, CallHost, GatewayMacs, CallFailed],
      run(state, _m, ctx) {
        state.moving = false;
        if (state.imported) return serveWaiting(state, ctx);
        state.lost = true;
        failWaiting(state, "apps are unavailable", ctx);
      },
    },
    exportFailed: {
      on: failed(ExportApps),
      description: "The account manager did not answer; nothing changed on either side, and the requests that waited fail with try again.",
      sends: [CallFailed],
      run(state, _f, ctx) {
        state.moving = false;
        failWaiting(state, "apps are moving; try again", ctx);
      },
    },
    confirmed: {
      on: Confirmed,
      description: "The account manager deleted its copy: the move is done.",
      run(state) {
        state.confirming = false;
        state.confirmed = true;
      },
    },
    mismatch: {
      on: Mismatch,
      description: "The account manager's copy changed since the export, which nothing should do: it deleted nothing, and the gateway reports it.",
      run(state) {
        state.confirming = false;
        state.mismatch = true;
      },
    },
    confirmFailed: {
      on: failed(ConfirmMoved),
      description: "The confirmation got no answer; the next request sends it again.",
      run: (state) => void (state.confirming = false),
    },
    macsChanged: {
      on: MacsChanged,
      description: "Takes the account's new list of Macs, if it is newer than the one it has.",
      run(state, m) {
        if (m.version <= state.macsVersion) return;
        state.macs = [...m.macs];
        state.macsVersion = m.version;
      },
    },
    macsList: {
      on: MacsList,
      description: "Takes the pulled list of Macs, if newer, and serves the requests that waited for it.",
      sends: [ConfirmMoved, GmailCall, CallHost, GatewayMacs, CallFailed],
      run(state, m, ctx) {
        if (m.version > state.macsVersion) {
          state.macs = [...m.macs];
          state.macsVersion = m.version;
        }
        serveWaiting(state, ctx);
      },
    },
    macsFailed: {
      on: failed(GatewayMacs),
      description: "The account manager did not answer; requests that waited for the list fail with try again.",
      sends: [CallFailed],
      run: (state, _f, ctx) => failWaiting(state, "apps are unavailable; try again", ctx),
    },
    gmailResult: {
      on: GmailResult,
      description: "Hands Gmail's answer back to the Session.",
      sends: [Result],
      run(state, m, ctx) {
        const d = state.dispatched[m.call];
        if (!d) return;
        delete state.dispatched[m.call];
        reply(ctx, d.from, Result, { request: d.request, output: m.output });
      },
    },
    gmailFailed: {
      on: failed(GmailCall),
      description: "Gmail did not answer; the call fails as may-have-run and is not sent again.",
      sends: [CallFailed],
      run(state, f, ctx) {
        const d = state.dispatched[f.payload.call];
        if (!d) return;
        delete state.dispatched[f.payload.call];
        reply(ctx, d.from, CallFailed, { request: d.request, error: "Gmail did not answer; it may have run" });
      },
    },
    bashResult: {
      on: BashResult,
      description: "Hands the command's output back to the Session.",
      sends: [Result],
      run(state, m, ctx) {
        const d = state.dispatched[m.call];
        if (!d) return;
        delete state.dispatched[m.call];
        reply(ctx, d.from, Result, { request: d.request, output: m.output });
      },
    },
    hostRefused: {
      on: HostRefused,
      description: "The Mac's socket owner sent nothing: the Mac is offline or revoked.",
      sends: [CallFailed],
      run(state, m, ctx) {
        const d = state.dispatched[m.call];
        if (!d) return;
        delete state.dispatched[m.call];
        reply(ctx, d.from, CallFailed, { request: d.request, error: m.error });
      },
    },
    callHostFailed: {
      on: failed(CallHost),
      description: "The socket owner did not answer; the command may have run, and is not sent again.",
      sends: [CallFailed],
      run(state, f, ctx) {
        const d = state.dispatched[f.payload.call];
        if (!d) return;
        delete state.dispatched[f.payload.call];
        reply(ctx, d.from, CallFailed, { request: d.request, error: "the Mac did not answer; the command may have run" });
      },
    },
    // Faults: what the network and restarts may do here. Its storage survives a restart.
    appsCallLost: lose(AppsCall, { spend: faults }),
    snapshotLost: lose(Snapshot, { fails: ExportApps, spend: faults }),
    confirmedLost: lose(Confirmed, { fails: ConfirmMoved, spend: faults }),
    macsChangedLost: lose(MacsChanged, { spend: faults }),
    macsListLost: lose(MacsList, { fails: GatewayMacs, spend: faults }),
    gmailResultLost: lose(GmailResult, { fails: GmailCall, spend: faults }),
    crash: crash({ keeps: ["imported", "confirmed", "importedHead", "grants", "log", "macs", "macsVersion", "lost", "mismatch"], spend: faults }),
  },
});


/** Serves one request: logs the call before sending it, with the account's grant or to one of its Macs. */
function serve(state: GatewayState, request: Waiting, ctx: any): void {
  // A confirmation that got no answer goes again with the next request.
  if (state.imported && !state.confirmed && !state.confirming && state.importedHead !== null) {
    state.confirming = true;
    ctx.send(ctx.the(Manager), ConfirmMoved, { head: state.importedHead });
  }
  if (request.script === "gmail") {
    const grant = state.grants[0];
    if (!grant) return reply(ctx, request.from, CallFailed, { request: request.request, error: "needs sign-in" });
    const call = ctx.fresh("call");
    state.log.push(call);
    state.dispatched[call] = { request: request.request, from: request.from };
    return ctx.send(ctx.the(Gmail), GmailCall, { call, grant });
  }
  const host = request.script.slice("bash:".length);
  if (!state.macs.includes(host)) {
    // A Mac it does not know: pull the account's list once before saying there is no such connection.
    if (request.pulled) return reply(ctx, request.from, CallFailed, { request: request.request, error: `no connection named ${host}` });
    state.waiting.push({ ...request, pulled: true });
    return ctx.send(ctx.the(Manager), GatewayMacs, {});
  }
  const owner = ctx.all(HostDO).find((h: any) => h.state.host === host);
  if (!owner) return reply(ctx, request.from, CallFailed, { request: request.request, error: `${host} is offline` });
  const call = ctx.fresh("call");
  state.log.push(call);
  state.dispatched[call] = { request: request.request, from: request.from };
  ctx.send(owner, CallHost, { call, command: "uptime" });
}

function serveWaiting(state: GatewayState, ctx: any): void {
  const waiting = state.waiting;
  state.waiting = [];
  for (const request of waiting) serve(state, request, ctx);
}

function failWaiting(state: GatewayState, error: string, ctx: any): void {
  for (const request of state.waiting) reply(ctx, request.from, CallFailed, { request: request.request, error });
  state.waiting = [];
}

function reply(ctx: any, to: string, message: any, payload: any): void {
  const session = ctx.all(Session).find((x: any) => x.id === to);
  if (session) ctx.send(session, message, payload);
}

export const HostDO = defineActor({
  name: "AxoHostDO",
  description: "A Mac's socket owner, and the Mac behind it: it runs a command the gateway sends, unless the Mac was revoked.",
  zone: macs,
  initialState: (ctx) => ({
    host: ctx.label.toLowerCase(),
    revoked: false,
    ran: [] as { call: string; revoked: boolean }[],
  }),
  display: {
    icon: "laptop",
    names: ["Studio", "Laptop"],
    status: (s) => (s.revoked ? "revoked" : `${s.ran.length} command(s) run`),
    mood: (s) => (s.revoked ? "off" : "ok"),
    owner: () => "Ada",
  },
  transitions: {
    callHost: {
      on: CallHost,
      description: "Runs the command on the Mac and answers with its output; a revoked Mac's socket owner sends nothing.",
      sends: [BashResult, HostRefused],
      run(state, m, ctx) {
        if (state.revoked && hostRefusesRevoked.on) return ctx.reply(HostRefused, { call: m.call, error: "host offline; nothing sent" });
        state.ran.push({ call: m.call, revoked: state.revoked });
        ctx.reply(BashResult, { call: m.call, output: `uptime on ${state.host}` });
      },
    },
    revoke: {
      on: Revoke,
      description: "The account revoked this Mac: its socket closes, and it is refused from now on.",
      run: (state) => void (state.revoked = true),
    },
    // Faults: the call or its answer may be lost.
    callHostLost: lose(CallHost, { spend: faults }),
  },
});

export const Gmail = defineActor({
  name: "Gmail",
  description: "Google's Gmail API: it answers whoever presents a valid grant.",
  zone: services,
  singleton: true,
  initialState: () => ({ calls: [] as { call: string; grant: string }[] }),
  display: { icon: "mail", status: (s) => `${s.calls.length} call(s) served` },
  transitions: {
    gmailCall: {
      on: GmailCall,
      description: "Lists the messages of the grant's account.",
      sends: [GmailResult],
      run(state, m, ctx) {
        state.calls.push({ call: m.call, grant: m.grant });
        ctx.reply(GmailResult, { call: m.call, output: "3 unread" });
      },
    },
    gmailCallLost: lose(GmailCall, { spend: faults }),
  },
});

export const Session = defineActor({
  name: "Session",
  description: "Ada's agent in an Axo Session, calling her apps.",
  zone: macs,
  initialState: () => ({ pending: null as null | { request: string; script: Script }, last: null as string | null }),
  display: {
    icon: "robot",
    names: ["Studio session"],
    status: (s) => (s.pending ? `running ${s.pending.script}` : s.last ?? "idle"),
    mood: (s) => (s.pending ? "busy" : s.last?.startsWith("ok") ? "ok" : s.last ? "warn" : "off"),
    owner: () => "Ada",
  },
  actions: {
    call: {
      with: [atMost(2)],
      label: "Run a script",
      description: "The agent calls Gmail, or runs a command on one of Ada's Macs.",
      inputs: { script: input(String, { examples: SCRIPTS }) },
      when: (s) => s.pending === null,
      sends: [AppsCall],
      starts: ["deadline"],
      run(state, { script }, ctx) {
        const request = ctx.fresh("req");
        state.pending = { request, script: script as Script };
        ctx.send(ctx.the(Gateway), AppsCall, { request, script: script as Script });
        ctx.start("deadline");
      },
    },
  },
  transitions: {
    result: {
      on: Result,
      description: "The call returned.",
      run(state, m, ctx) {
        if (state.pending?.request !== m.request) return;
        state.last = "ok";
        state.pending = null;
        ctx.cancel("deadline");
      },
    },
    callFailed: {
      on: CallFailed,
      description: "The call failed with an error the agent can read.",
      run(state, m, ctx) {
        if (state.pending?.request !== m.request) return;
        state.last = `error: ${m.error}`;
        state.pending = null;
        ctx.cancel("deadline");
      },
    },
    unanswered: {
      on: failed(AppsCall),
      description: "The gateway did not answer: the call failed, and may have run.",
      run(state, f, ctx) {
        if (state.pending?.request !== f.payload.request) return;
        state.last = "error: no answer; it may have run";
        state.pending = null;
        ctx.cancel("deadline");
      },
    },
    deadline: {
      description: "No answer in time; the call fails, and its outcome is unknown.",
      after: "5 minutes",
      run(state) {
        if (!state.pending) return;
        state.last = "error: deadline passed, outcome unknown";
        state.pending = null;
      },
    },
    resultLost: lose(Result, { fails: AppsCall, spend: faults }),
  },
});

const grants = (w: any): string[] => [...(w.the(Manager).state.conns?.grants ?? []), ...w.the(Gateway).state.grants];
/** Whether the account had apps to move: the account manager holds them, handed them off, or the gateway stored them. */
const hadApps = (w: any): boolean => w.the(Manager).state.conns !== null || w.the(Manager).state.handoff !== null || w.the(Gateway).state.importedHead !== null;
const logs = (w: any): string[][] => [w.the(Manager).state.conns?.log ?? [], w.the(Gateway).state.log];

const credentialsNeverLost = defineProperty("credentialsNeverLost", {
  description: "Ada's Gmail grant is always held by the account manager, the gateway, or both while the move runs.",
  always: (w) => !hadApps(w) || grants(w).includes(GRANT),
  needs: [deleteOnConfirmedHead],
});
const oneHomeOnceMoved = defineProperty("oneHomeOnceMoved", {
  description: "Once the account manager records the hand-off, it holds no apps, and the gateway holds the grant and the head it confirmed.",
  always: (w) => {
    const m = w.the(Manager).state;
    const g = w.the(Gateway).state;
    if (!m.handoff) return true;
    return m.conns === null && g.grants.includes(GRANT) && g.importedHead === m.handoff;
  },
  needs: [deleteOnConfirmedHead],
});
const confirmedMeansDeleted = defineProperty("confirmedMeansDeleted", {
  description: "When the gateway believes the move is done, the account manager's copy is gone.",
  always: (w) => !w.the(Gateway).state.confirmed || w.the(Manager).state.conns === null,
});
const logKeptWhole = defineProperty("logKeptWhole", {
  description: "The call log from before the move survives it: one of the two objects always holds it from its first record, and the gateway's log starts with it.",
  always: (w) => {
    if (!hadApps(w)) return true;
    const g = w.the(Gateway).state;
    const kept = logs(w).some((log) => OLD_LOG.every((c, i) => log[i] === c));
    return kept && (!g.imported || OLD_LOG.every((c, i) => g.log[i] === c));
  },
  needs: [deleteOnConfirmedHead],
});
const loggedBeforeSent = defineProperty("loggedBeforeSent", {
  description: "Every call that reached Gmail or a Mac is in the gateway's call log.",
  always: (w) => {
    const log = new Set(w.the(Gateway).state.log);
    return w.the(Gmail).state.calls.every((c) => log.has(c.call)) && w.all(HostDO).every((h) => h.state.ran.every((r) => log.has(r.call)));
  },
});
const onlyAfterTheMove = defineProperty("onlyAfterTheMove", {
  description: "No call reaches Gmail or a Mac until the gateway holds the account's history: the gateway never serves from an empty store while the account manager still holds it.",
  always: (w) => {
    const g = w.the(Gateway).state;
    const anything = w.the(Gmail).state.calls.length > 0 || w.all(HostDO).some((h) => h.state.ran.length > 0);
    return !anything || (g.imported && (!hadApps(w) || g.log[0] === OLD_LOG[0]));
  },
});
const accountManagerCallsNothing = defineProperty("accountManagerCallsNothing", {
  description: "The account manager never holds runs, sent calls or a call log of its own: only identity, Macs, and apps waiting to be handed off.",
  always: (w) => Object.keys(w.the(Manager).state).every((k) => ["conns", "handoff", "macs", "macsVersion"].includes(k)),
});
const revokedMacsRunNothingNew = defineProperty("revokedMacsRunNothingNew", {
  description: "A revoked Mac runs no command, even when the gateway's list of Macs is stale.",
  always: (w) => w.all(HostDO).every((h) => h.state.ran.every((r) => !r.revoked)),
  needs: [hostRefusesRevoked],
});
const sessionsGetAnAnswer = defineProperty("sessionsGetAnAnswer", {
  description: "A Session waiting on a call always gets an answer: a result, an error, or its deadline.",
  leadsTo: { whenever: (w) => w.all(Session).some((s) => s.state.pending !== null), then: (w) => w.all(Session).every((s) => s.state.pending === null) },
});

const adaWithHistory = (w: any) => {
  w.spawn(Session, "Studio session");
  w.spawn(HostDO, "Studio");
  w.spawn(HostDO, "Laptop");
};

const theFirstCallMovesTheAccount = defineScenario("The first call moves the account", {
  description: "Ada's first Gmail call after the deploy: the gateway copies her grant and call log from the account manager, stores them, serves the call, and confirms; the account manager deletes its copy.",
  setup: adaWithHistory,
  run(s) {
    s.act(s.world.all(Session)[0]!, "call", { script: "gmail" });
    s.settle();
  },
});
const theGatewayRestartsBeforeConfirming = defineScenario("The gateway restarts before confirming", {
  description: "The gateway stores the snapshot and restarts before its confirmation lands; the account manager keeps its copy, serving nothing from it, until the next call confirms again.",
  setup: adaWithHistory,
  run(s) {
    const session = s.world.all(Session)[0]!;
    s.act(session, "call", { script: "gmail" });
    s.settle({ until: (w) => w.the(Gateway).state.imported });
    s.step(s.the(Gateway), "crash");
    s.settle();
    s.act(session, "call", { script: "gmail" });
    s.settle();
  },
});
const theExportIsLost = defineScenario("The export is lost", {
  description: "The account manager never gets the export: Ada's call fails with try again, nothing changed on either side, and her next call moves the account.",
  setup: adaWithHistory,
  run(s) {
    const session = s.world.all(Session)[0]!;
    s.act(session, "call", { script: "gmail" });
    s.settle({ until: (w) => w.the(Gateway).state.moving });
    s.step(s.the(Manager), "exportAppsLost");
    s.settle();
    s.act(session, "call", { script: "gmail" });
    s.settle();
  },
});
const aMacPairedAfterTheMove = defineScenario("A Mac paired after the move", {
  description: "Ada pairs her laptop after the move; the gateway hears the new list, and a command runs there.",
  setup: adaWithHistory,
  run(s) {
    const session = s.world.all(Session)[0]!;
    s.act(session, "call", { script: "gmail" });
    s.settle();
    s.act(s.the(Manager), "pairLaptop");
    s.settle();
    s.act(session, "call", { script: "bash:laptop" });
    s.settle();
  },
});
const aRevokedMacWithAStaleList = defineScenario("A revoked Mac with a stale list", {
  description: "Ada revokes her Studio and the gateway never hears it; it still sends the command, and the Studio's socket owner refuses it.",
  setup: adaWithHistory,
  run(s) {
    const session = s.world.all(Session)[0]!;
    s.act(session, "call", { script: "bash:studio" });
    s.settle();
    s.act(s.the(Manager), "revoke", { host: "studio" });
    s.settle({ until: (w) => w.all(HostDO).some((h) => h.state.revoked) });
    s.step(s.the(Gateway), "macsChangedLost");
    s.settle();
    s.act(session, "call", { script: "bash:studio" });
    s.settle();
  },
});

const anAccountWithNoApps = defineScenario("An account with no apps", {
  description: "An account that never added an app or a server: the gateway starts empty, with nothing to move, and asks for sign-in.",
  setup(w) {
    w.set(Manager, { conns: null });
    adaWithHistory(w);
  },
  run(s) {
    s.act(s.world.all(Session)[0]!, "call", { script: "gmail" });
    s.settle();
  },
});

const macGroup = defineGroup({ name: "Mac", actors: { session: Session }, icon: "laptop", names: ["Studio"] });
const accountGroup = defineGroup({ name: "Ada's account", actors: [Manager, Gateway], icon: "cloud", collapsed: false });

export default defineSpec({
  name: "Account gateway",
  description:
    "How one Durable Object per account, AxoGateway, comes to hold every credential and make every call to another service or a Mac, and how an account's apps move there from AxoAccountManager without being lost or kept twice.",
  actors: [Manager, Gateway, HostDO, Gmail, Session],
  groups: [macGroup, accountGroup],
  limits: [macListAge],
  properties: [credentialsNeverLost, oneHomeOnceMoved, confirmedMeansDeleted, logKeptWhole, loggedBeforeSent, onlyAfterTheMove, accountManagerCallsNothing, revokedMacsRunNothingNew, sessionsGetAnAnswer],
  scenarios: [theFirstCallMovesTheAccount, theGatewayRestartsBeforeConfirming, theExportIsLost, aMacPairedAfterTheMove, aRevokedMacWithAStaleList, anAccountWithNoApps],
});
