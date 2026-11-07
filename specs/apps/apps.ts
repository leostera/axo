import { atMost, budget, crash, defineActor, defineCall, defineGroup, defineLimit, defineMessage, defineProperty, defineScenario, defineSpec, defineZone, failed, input, listOf, lose, oneOf } from "@leostera/feynman";

const SEC = 1_000;
const MIN = 60 * SEC;

// RFD0016: an agent in an Axo Session runs a apps script. The script runs in the account's
// cloud Dynamic Worker; third-party tools are called from the cloud with the account's grant, and
// `bash` travels over the host relay to the Mac it names.
//
// Each Mac's relay socket ends in its own Durable Object, HostDO: axod connects to
// api.axo.leostera.dev and the Worker routes the socket to HostDO by host ID (relay data flow
// redesign; until it lands, AxoAccountManager owns the socket itself). Apps state lives
// only in the account's AxoAccountManager, one RPC hop away: the socket owner forwards a Mac's
// apps calls to it, and sends it `bash` for its Mac. The model holds whichever object owns
// the socket. Names match the relay data flow specs: zones "Host Mac" and "Cloudflare"; actors
// "axod relay", "HostDO", "AxoAccountManager".
//
// Not built yet, so no step has sources. Left out: pairing (RFD0013, see remote-access.ts),
// third-party sign-in and refresh (connection-sign-in.ts), tool lists (tool-lists.ts), and how a
// large message crosses the relay (relay-fragments.ts). Limits are scaled down: a script may make
// 2 tool calls (100 in the code) and runs one call at a time (4 at once in the code). The Session's
// deadline stands for every way an answer can go missing inside the cloud. Messages on one relay
// WebSocket cannot overtake each other in the real system; the checker lets them, so every message
// on a relay carries its socket's epoch and stale ones are dropped.

/** Who owns which Mac, by the Mac's host name. */
const MACS: Record<string, string> = { studio: "acct-alice", laptop: "acct-alice", workbench: "acct-bob" };
const ACCOUNTS = ["acct-alice", "acct-bob"];
/** The scripts an agent may run, by what they call. */
type ScriptName = "linear" | "bash:studio" | "bash:laptop" | "bash:workbench" | "linear+bash:studio" | "bash:studio x3";
type Call = { service: string; tool: string; input: string };
const CALLS: Record<ScriptName, Call[]> = {
  linear: [{ service: "linear", tool: "list_issues", input: "team AXO" }],
  "bash:studio": [{ service: "studio", tool: "bash", input: "uptime" }],
  "bash:laptop": [{ service: "laptop", tool: "bash", input: "uptime" }],
  "bash:workbench": [{ service: "workbench", tool: "bash", input: "uptime" }],
  "linear+bash:studio": [
    { service: "linear", tool: "list_issues", input: "team AXO" },
    { service: "studio", tool: "bash", input: "open-issues.sh" },
  ],
  "bash:studio x3": [
    { service: "studio", tool: "bash", input: "date" },
    { service: "studio", tool: "bash", input: "whoami" },
    { service: "studio", tool: "bash", input: "uptime" },
  ],
};
/** Tool calls one script may make: 100 in the code, scaled down. */
const MAX_CALLS = 2;

const who = (account: string) => account.replace(/^acct-/, "");
const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
/** "Studio daemon" and "Studio session" are both on the Mac named studio. */
const hostOf = (label: string) => label.replace(/ (daemon|session)$/, "").toLowerCase();
const grantOf = (account: string) => `grant:${who(account)}-linear`;

type Connection = { kind: "third-party"; grant: string } | { kind: "host" };
type Run = { account: string; host: string; calls: number };
type Dispatch = { request: string; account: string; target: string };
type LogRecord = { account: string; request: string; service: string; tool: string; input: string; call: string };

/** Faults on one path: lost messages and crashes (RFD0012). `--set faults=2` raises it. */
const faults = budget("faults", 1);

// Session agent -> axod (axod mcp over axod.sock)
const Execute = defineMessage("Execute", { request: String, script: oneOf("linear", "bash:studio", "bash:laptop", "bash:workbench", "linear+bash:studio", "bash:studio x3") }, { name: "apps_execute", over: "unix socket" });
const Done = defineMessage("Done", { request: String, results: listOf(String) }, { name: "script result", over: "unix socket", tone: "reply" });
const Failed = defineMessage("Failed", { request: String, error: String }, { name: "script failed", over: "unix socket", tone: "refused" });
const RelayDown = defineMessage("RelayDown", { request: String }, { name: "this Mac is not connected to its account", over: "unix socket", tone: "refused" });
// axod <-> the Durable Object that owns its relay socket
const Forward = defineMessage("Forward", { request: String, script: oneOf("linear", "bash:studio", "bash:laptop", "bash:workbench", "linear+bash:studio", "bash:studio x3"), epoch: Number }, { name: "axo.apps.execute", over: "websocket" });
const Answer = defineMessage("Answer", { request: String, results: listOf(String), epoch: Number }, { name: "execute result", over: "websocket", tone: "reply" });
const Refused = defineMessage("Refused", { request: String, error: String, epoch: Number }, { name: "execute failed", over: "websocket", tone: "refused" });
const Bash = defineMessage("Bash", { call: String, account: String, command: String, epoch: Number }, { name: "axo.apps.bash", over: "websocket" });
const BashDone = defineMessage("BashDone", { call: String, output: String, epoch: Number }, { name: "bash result", over: "websocket", tone: "reply" });
const Disconnected = defineMessage("Disconnected", { host: String, epoch: Number }, { name: "relay socket closed", over: "websocket", tone: "refused" });
const Reconnected = defineMessage("Reconnected", { host: String, epoch: Number }, { name: "relay socket open", over: "websocket" });
const Revoked = defineMessage("Revoked", { epoch: Number }, { name: "close 4003: host revoked", over: "websocket", tone: "refused" });
// The socket owner <-> AxoAccountManager (Durable Object RPC)
const ExecuteFor = defineCall("ExecuteFor", { request: String, account: String, host: String, script: oneOf("linear", "bash:studio", "bash:laptop", "bash:workbench", "linear+bash:studio", "bash:studio x3") }, { name: "executeApps", over: "rpc" });
const Finished = defineMessage("Finished", { request: String, results: listOf(String) }, { name: "script finished", over: "rpc", tone: "reply" });
const NotFinished = defineMessage("NotFinished", { request: String, error: String }, { name: "script failed", over: "rpc", tone: "refused" });
const CallHost = defineCall("CallHost", { call: String, account: String, host: String, command: String }, { name: "callHost", over: "rpc" });
const BashResult = defineMessage("BashResult", { call: String, host: String, output: String }, { name: "callHost result", over: "rpc", tone: "reply" });
const HostOffline = defineMessage("HostOffline", { host: String, call: String, error: String }, { name: "callHost error", over: "rpc", tone: "refused" });
const Unpair = defineCall("Unpair", { host: String }, { name: "closeHost", over: "rpc" });
// AxoAccountManager <-> script Worker (Dynamic Worker binding)
const RunScript = defineMessage("RunScript", { request: String, account: String, calls: listOf({ service: String, tool: String, input: String }) }, { name: "run script", over: "rpc" });
const ToolCall = defineMessage("ToolCall", { request: String, call: { service: String, tool: String, input: String } }, { name: "codemode tool call", over: "rpc" });
const ToolResult = defineMessage("ToolResult", { request: String, output: String }, { name: "tool result", over: "rpc", tone: "reply" });
const ToolError = defineMessage("ToolError", { request: String, error: String }, { name: "tool failed", over: "rpc", tone: "refused" });
const ScriptDone = defineMessage("ScriptDone", { request: String, results: listOf(String) }, { name: "script returned", over: "rpc", tone: "reply" });
const ScriptFailed = defineMessage("ScriptFailed", { request: String, error: String }, { name: "script threw", over: "rpc", tone: "refused" });
const Abort = defineMessage("Abort", { request: String }, { name: "abort the script", over: "rpc" });
// AxoAccountManager <-> Linear's MCP server
const McpCall = defineCall("McpCall", { call: String, tool: String, token: String }, { name: "tools/call", over: "https" });
const McpResult = defineMessage("McpResult", { call: String, output: String }, { name: "tools/call result", over: "https", tone: "reply" });


const macs = defineZone({ name: "Host Mac", description: "each runs axod and Axo Sessions" });
const cloudflare = defineZone({ name: "Cloudflare", description: "the host's socket owner, the account's Durable Object and its script Worker", place: { column: 1, region: true } });
const services = defineZone({ name: "Third-party services", description: "remote MCP servers", place: { column: 2 } });

const limit1 = defineLimit({ name: "Script wall time", value: 5 * MIN, sources: ["packages/axo-api/src/apps.ts#APPS_LIMITS"] });
const limit2 = defineLimit({ name: "Tool calls per script", value: 100, unit: "calls", sources: ["packages/axo-api/src/apps.ts#APPS_LIMITS"] });
const limit3 = defineLimit({ name: "Concurrent tool calls per script", value: 4, unit: "calls", sources: ["packages/axo-api/src/apps.ts#APPS_LIMITS"] });
const limit4 = defineLimit({ name: "bash default timeout", value: 60 * SEC, sources: ["packages/axo-api/src/apps.ts#APPS_LIMITS"] });
const limit5 = defineLimit({ name: "Call log retention", value: 30, unit: "days" });

export const Ingress = defineActor({
  name: "HostDO",
  description: "The Durable Object that owns each Mac's relay socket. It knows which sockets are open, forwards a Mac's apps calls to the account, and sends the account's commands down the right socket. It holds no apps state.",
  zone: cloudflare,
  singleton: true,
  initialState: () => ({
    /** Each Mac's current socket, if open, with its epoch. */
    sockets: Object.fromEntries(Object.keys(MACS).map((host) => [host, { open: true, epoch: 1 }])) as Record<string, { open: boolean; epoch: number }>,
    /** Hosts the account revoked; their sockets are refused. */
    revoked: [] as string[],
    /** Scripts forwarded for a Mac, so the answer goes back down its socket. */
    forwarded: {} as Record<string, { host: string; epoch: number }>,
    /** callHost RPCs waiting for the Mac's reply, with the socket the request went down. */
    calling: {} as Record<string, { host: string; epoch: number }>,
  }),
  display: {
    icon: "plug",
    status: (s) => `${Object.values(s.sockets).filter((x) => x.open).length} socket(s) open`,
    rows: (s) => Object.entries(s.sockets).map(([host, x]) => ({ group: "Host sockets", label: host, detail: x.open ? `open, epoch ${x.epoch}` : "closed", mood: x.open ? ("ok" as const) : ("off" as const) })),
  },
  transitions: {
    forward: {
      on: Forward,
      description: "A Mac's script goes to its account, if it came on the Mac's current socket.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.receiveHostCall"],
      sends: [ExecuteFor],
      run(state, m, ctx) {
        const host = hostOf(ctx.from.label);
        const socket = state.sockets[host];
        if (!socket?.open || socket.epoch !== m.epoch) return;
        state.forwarded[m.request] = { host, epoch: m.epoch };
        ctx.send(ctx.the(Manager), ExecuteFor, { request: m.request, account: MACS[host]!, host, script: m.script });
      },
    },
    finished: {
      on: Finished,
      description: "Returns the script's result down the socket it came on; if that socket closed, the Mac already failed the call.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.receiveHostCall"],
      sends: [Answer],
      run(state, m, ctx) {
        const f = state.forwarded[m.request];
        delete state.forwarded[m.request];
        if (!f || state.sockets[f.host]?.epoch !== f.epoch || !state.sockets[f.host]?.open) return;
        const daemon = ctx.all(Axod).find((a) => hostOf(a.label) === f.host);
        if (daemon) ctx.send(daemon, Answer, { request: m.request, results: m.results, epoch: f.epoch });
      },
    },
    notFinished: {
      on: NotFinished,
      description: "Returns the script's error down the socket it came on.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.receiveHostCall"],
      sends: [Refused],
      run(state, m, ctx) {
        const f = state.forwarded[m.request];
        delete state.forwarded[m.request];
        if (!f || state.sockets[f.host]?.epoch !== f.epoch || !state.sockets[f.host]?.open) return;
        const daemon = ctx.all(Axod).find((a) => hostOf(a.label) === f.host);
        if (daemon) ctx.send(daemon, Refused, { request: m.request, error: m.error, epoch: f.epoch });
      },
    },
    executeForFailed: {
      on: failed(ExecuteFor),
      description: "The account did not answer; the Mac hears that the script failed and may have run.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.receiveHostCall"],
      sends: [Refused],
      run(state, failure, ctx) {
        const f = state.forwarded[failure.payload.request];
        delete state.forwarded[failure.payload.request];
        if (!f || state.sockets[f.host]?.epoch !== f.epoch || !state.sockets[f.host]?.open) return;
        const daemon = ctx.all(Axod).find((a) => hostOf(a.label) === f.host);
        if (daemon) ctx.send(daemon, Refused, { request: failure.payload.request, error: "the account did not answer; the script may have run", epoch: f.epoch });
      },
    },
    callHost: {
      on: CallHost,
      description: "Sends a command down the Mac's current socket and waits for its reply, or answers at once that the Mac is offline and nothing was sent.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.callHost"],
      sends: [Bash, HostOffline],
      starts: ["callDeadline"],
      run(state, m, ctx) {
        const socket = state.sockets[m.host];
        const daemon = ctx.all(Axod).find((a) => hostOf(a.label) === m.host);
        if (!socket?.open || !daemon) return ctx.reply(HostOffline, { host: m.host, call: m.call, error: "host offline; nothing sent" });
        state.calling[m.call] = { host: m.host, epoch: socket.epoch };
        ctx.send(daemon, Bash, { call: m.call, account: m.account, command: m.command, epoch: socket.epoch });
        ctx.start("callDeadline");
      },
    },
    bashDone: {
      on: BashDone,
      description: "Answers the waiting callHost with the command's output, if it came on the socket the command went down; a reply on a later socket is ignored.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.receiveReply"],
      sends: [BashResult],
      run(state, m, ctx) {
        const host = hostOf(ctx.from.label);
        const c = state.calling[m.call];
        if (!c || c.host !== host || c.epoch !== m.epoch) return;
        delete state.calling[m.call];
        ctx.send(ctx.the(Manager), BashResult, { call: m.call, host, output: m.output });
      },
    },
    callDeadline: {
      description: "A command's reply did not come in time; every callHost still waiting fails with an unknown outcome.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.callHost"],
      after: "10 minutes",
      sends: [HostOffline],
      run(state, _, ctx) {
        for (const [call, c] of Object.entries(state.calling)) {
          delete state.calling[call];
          ctx.send(ctx.the(Manager), HostOffline, { host: c.host, call, error: "no answer in time; the command may have run" });
        }
      },
    },
    disconnected: {
      on: Disconnected,
      description: "A Mac's socket closed; every callHost waiting on it fails, since its command may have run.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.fence"],
      sends: [HostOffline],
      run(state, m, ctx) {
        const socket = state.sockets[m.host];
        if (!socket || socket.epoch !== m.epoch || !socket.open) return;
        socket.open = false;
        for (const [request, f] of Object.entries(state.forwarded)) if (f.host === m.host) delete state.forwarded[request];
        failCallsTo(state, m.host, "host disconnected; the command may have run", ctx);
      },
    },
    reconnected: {
      on: Reconnected,
      description: "A Mac opened a new socket; a revoked Mac is refused.",
      run(state, m) {
        if (state.revoked.includes(m.host)) return;
        const socket = state.sockets[m.host];
        if (socket && m.epoch > socket.epoch) state.sockets[m.host] = { open: true, epoch: m.epoch };
      },
    },
    unpair: {
      on: Unpair,
      description: "The account revoked a Mac: its socket closes with 4003 and is refused from now on, and every callHost waiting on it fails.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.disconnect"],
      sends: [Revoked, HostOffline],
      run(state, m, ctx) {
        if (!state.revoked.includes(m.host)) state.revoked.push(m.host);
        failCallsTo(state, m.host, "host revoked; the command may have run", ctx);
        const socket = state.sockets[m.host];
        if (!socket?.open) return;
        socket.open = false;
        const daemon = ctx.all(Axod).find((a) => hostOf(a.label) === m.host);
        if (daemon) ctx.send(daemon, Revoked, { epoch: socket.epoch });
      },
    },
    // Faults: what the network and restarts may do here.
    forwardLost: lose(Forward, { spend: faults }),
    finishedLost: lose(Finished, { spend: faults }),
    notFinishedLost: lose(NotFinished, { spend: faults }),
    callHostLost: lose(CallHost, { spend: faults }),
    bashDoneLost: lose(BashDone, { spend: faults }),
    disconnectedLost: lose(Disconnected, { spend: faults }),
    reconnectedLost: lose(Reconnected, { spend: faults }),
    unpairLost: lose(Unpair, { spend: faults }),
  },
});

export const Manager = defineActor({
  name: "AxoAccountManager",
  description: "The account's Durable Object: it holds apps and grants, runs scripts in a Worker, and dispatches their tool calls.",
  zone: cloudflare,
  singleton: true,
  initialState: () => ({
    apps: Object.fromEntries(
      ACCOUNTS.map((account) => [
        account,
        {
          linear: { kind: "third-party", grant: grantOf(account) } as Connection,
          ...Object.fromEntries(Object.entries(MACS).filter(([, a]) => a === account).map(([host]) => [host, { kind: "host" } as Connection])),
        },
      ]),
    ) as Record<string, Record<string, Connection>>,
    runs: {} as Record<string, Run>,
    dispatched: {} as Record<string, Dispatch>,
    log: [] as LogRecord[],
    /** How long the call log was when each Mac was unpaired. */
    unpairedAt: {} as Record<string, number>,
  }),
  display: {
    icon: "cloud",
    status: (s) => `${Object.keys(s.runs).length} script(s) running`,
    rows: (s) => [
      ...Object.entries(s.apps).flatMap(([account, cs]) =>
        Object.entries(cs).map(([name, c]) => ({
          group: `${cap(who(account))}'s apps`,
          owner: cap(who(account)),
          label: name,
          detail: c.kind === "host" ? "host" : "third-party, grant held here",
        })),
      ),
      ...(s.log.length ? [{ group: "Call log", label: `${s.log.length} record(s)`, detail: s.log.at(-1)!.service + "." + s.log.at(-1)!.tool }] : []),
    ],
  },
  actions: {
    unpair: {
      with: [atMost(2)],
      label: "Unpair a Mac",
      description: "The person revokes a Mac (RFD0013): its host connection is removed, commands sent to it fail, and its socket is closed.",
      sources: ["packages/axo-api-worker/src/auth/account-manager.ts#AxoAccountManager.revokeHost"],
      inputs: { host: input(String, { examples: ["studio"] }) },
      when: (s) => Object.values(s.apps).some((cs) => "studio" in cs),
      sends: [ToolError, Unpair],
      run(state, { host }, ctx) {
        for (const cs of Object.values(state.apps)) delete cs[host];
        state.unpairedAt[host] = state.log.length;
        failCommandsTo(state, host, `${host} was unpaired; the command may have run`, ctx);
        ctx.send(ctx.the(Ingress), Unpair, { host });
      },
    },
  },
  transitions: {
    executeFor: {
      on: ExecuteFor,
      description: "Starts the script in the account's Worker, under the script's wall time.",
      sources: ["packages/axo-api-worker/src/apps/account.ts#AccountApps.call", "packages/axo-api-worker/src/apps/runner.ts#runScript"],
      sends: [RunScript],
      starts: ["wallTime"],
      say: (_s, m) => `Running ${m.script} for ${cap(who(m.account))} in a Dynamic Worker`,
      run(state, m, ctx) {
        state.runs[m.request] = { account: m.account, host: m.host, calls: 0 };
        ctx.send(ctx.the(Worker), RunScript, { request: m.request, account: m.account, calls: CALLS[m.script] });
        ctx.start("wallTime");
      },
    },
    wallTime: {
      description: "A script ran past its wall time: it is aborted, its calls in flight are abandoned, and the Mac that asked hears so.",
      sources: ["packages/axo-api-worker/src/apps/runner.ts#runScript"],
      after: "5 minutes",
      sends: [Abort, NotFinished],
      run(state, _, ctx) {
        for (const request of Object.keys(state.runs)) {
          delete state.runs[request];
          for (const [call, d] of Object.entries(state.dispatched)) if (d.request === request) delete state.dispatched[call];
          ctx.send(ctx.the(Worker), Abort, { request });
          ctx.send(ctx.the(Ingress), NotFinished, { request, error: "script wall time exceeded; calls in flight may have run" });
        }
      },
    },
    unpairFailed: {
      on: failed(Unpair),
      description: "Closing the Mac's socket failed; the Mac is already no connection, and its socket owner refuses it when it reconnects.",
      run: () => {},
    },
    toolCall: {
      on: ToolCall,
      description: "Counts the call against the script's limit, looks the service up among the account's own apps, logs the call, and sends it to the service or, through the Mac's socket owner, to the Mac.",
      sources: ["packages/axo-api-worker/src/apps/account.ts#AccountApps.caller", "packages/axo-api-worker/src/apps/runner.ts#ToolDispatcher.call"],
      sends: [McpCall, CallHost, ToolError],
      run(state, m, ctx) {
        const run = state.runs[m.request];
        if (!run) return;
        if (run.calls >= MAX_CALLS) return ctx.reply(ToolError, { request: m.request, error: `a script may make at most ${MAX_CALLS} tool calls` });
        run.calls += 1;
        const connection = state.apps[run.account]?.[m.call.service];
        if (!connection) return ctx.reply(ToolError, { request: m.request, error: `no connection named ${m.call.service}` });
        const call = ctx.fresh("call");
        state.log.push({ account: run.account, request: m.request, service: m.call.service, tool: m.call.tool, input: m.call.input, call });
        state.dispatched[call] = { request: m.request, account: run.account, target: m.call.service };
        if (connection.kind === "third-party") return ctx.send(ctx.the(Linear), McpCall, { call, tool: m.call.tool, token: connection.grant });
        ctx.send(ctx.the(Ingress), CallHost, { call, account: run.account, host: m.call.service, command: m.call.input });
      },
    },
    mcpResult: {
      on: McpResult,
      description: "Hands the service's answer back to the script.",
      sends: [ToolResult],
      run(state, m, ctx) {
        const d = state.dispatched[m.call];
        if (!d) return;
        delete state.dispatched[m.call];
        ctx.send(ctx.the(Worker), ToolResult, { request: d.request, output: m.output });
      },
    },
    mcpCallFailed: {
      on: failed(McpCall),
      description: "The request to the service failed or its answer was lost; the tool call fails and is not sent again, since the service may already have acted.",
      sends: [ToolError],
      run(state, failure, ctx) {
        const d = state.dispatched[failure.payload.call];
        if (!d) return;
        delete state.dispatched[failure.payload.call];
        ctx.send(ctx.the(Worker), ToolError, { request: d.request, error: `${d.target} did not answer; the call may have run` });
      },
    },
    callHostFailed: {
      on: failed(CallHost),
      description: "The socket owner did not answer; the command may have been sent, so it fails and is not sent again.",
      sources: ["packages/axo-api-worker/src/apps/account.ts#AccountApps.caller"],
      sends: [ToolError],
      run(state, failure, ctx) {
        const d = state.dispatched[failure.payload.call];
        if (!d) return;
        delete state.dispatched[failure.payload.call];
        ctx.send(ctx.the(Worker), ToolError, { request: d.request, error: `${d.target} did not answer; the command may have run` });
      },
    },
    bashResult: {
      on: BashResult,
      description: "Hands the command's output back to the script.",
      sources: ["packages/axo-api-worker/src/apps/account.ts#AccountApps.caller"],
      sends: [ToolResult],
      run(state, m, ctx) {
        const d = state.dispatched[m.call];
        if (!d || d.target !== m.host) return;
        delete state.dispatched[m.call];
        ctx.send(ctx.the(Worker), ToolResult, { request: d.request, output: m.output });
      },
    },
    hostOffline: {
      on: HostOffline,
      description: "The command failed before or after reaching the Mac; the tool call fails with the reason and is not sent again.",
      sources: ["packages/axo-api-worker/src/apps/account.ts#AccountApps.caller"],
      sends: [ToolError],
      run(state, m, ctx) {
        const d = state.dispatched[m.call];
        if (!d) return;
        delete state.dispatched[m.call];
        ctx.send(ctx.the(Worker), ToolError, { request: d.request, error: `${m.host}: ${m.error}` });
      },
    },
    scriptDone: {
      on: ScriptDone,
      description: "Returns the script's result to the socket owner of the Mac that asked.",
      sources: ["packages/axo-api-worker/src/apps/account.ts#scriptOutcome"],
      sends: [Finished],
      run(state, m, ctx) {
        if (!state.runs[m.request]) return;
        delete state.runs[m.request];
        if (!Object.keys(state.runs).length) ctx.cancel("wallTime");
        ctx.send(ctx.the(Ingress), Finished, { request: m.request, results: m.results });
      },
    },
    scriptFailed: {
      on: ScriptFailed,
      description: "Returns the script's error to the socket owner of the Mac that asked.",
      sources: ["packages/axo-api-worker/src/apps/account.ts#scriptOutcome"],
      sends: [NotFinished],
      run(state, m, ctx) {
        if (!state.runs[m.request]) return;
        delete state.runs[m.request];
        if (!Object.keys(state.runs).length) ctx.cancel("wallTime");
        ctx.send(ctx.the(Ingress), NotFinished, { request: m.request, error: m.error });
      },
    },
    // Faults: what the network and restarts may do here.
    executeForLost: lose(ExecuteFor, { spend: faults }),
    toolCallLost: lose(ToolCall, { spend: faults }),
    mcpResultLost: lose(McpResult, { fails: McpCall, spend: faults }),
    bashResultLost: lose(BashResult, { fails: CallHost, spend: faults }),
    hostOfflineLost: lose(HostOffline, { fails: CallHost, spend: faults }),
    scriptDoneLost: lose(ScriptDone, { spend: faults }),
    scriptFailedLost: lose(ScriptFailed, { spend: faults }),
  },
});

/** Fails every callHost waiting on `host`'s socket: it is not sent again, since it may already have run. */
function failCallsTo(state: any, host: string, error: string, ctx: any): void {
  for (const [call, c] of Object.entries(state.calling) as [string, { host: string }][]) {
    if (c.host !== host) continue;
    delete state.calling[call];
    ctx.send(ctx.the(Manager), HostOffline, { host, call, error });
  }
}

/** Fails every command in flight to `host`: it is not sent again, since it may already have run. */
function failCommandsTo(state: any, host: string, error: string, ctx: any): void {
  for (const [call, d] of Object.entries(state.dispatched) as [string, Dispatch][]) {
    if (d.target !== host) continue;
    delete state.dispatched[call];
    ctx.send(ctx.the(Worker), ToolError, { request: d.request, error });
  }
}

export const Worker = defineActor({
  name: "Script Worker",
  description: "The Dynamic Worker that runs scripts. It has no network of its own; every tool call goes back to the account's Durable Object.",
  zone: cloudflare,
  singleton: true,
  initialState: () => ({ runs: {} as Record<string, { calls: Call[]; next: number; results: string[] }> }),
  display: {
    icon: "code",
    status: (s) => (Object.keys(s.runs).length ? `${Object.keys(s.runs).length} script(s)` : "idle"),
    mood: (s) => (Object.keys(s.runs).length ? "busy" : "off"),
  },
  transitions: {
    runScript: {
      on: RunScript,
      description: "Runs the script up to its first tool call.",
      sources: ["packages/axo-api-worker/src/apps/runner.ts#WORKER_SOURCE"],
      sends: [ToolCall],
      run(state, m, ctx) {
        state.runs[m.request] = { calls: m.calls, next: 1, results: [] };
        ctx.reply(ToolCall, { request: m.request, call: m.calls[0]! });
      },
    },
    toolResult: {
      on: ToolResult,
      description: "Continues the script with the result: makes the next call, or returns.",
      sources: ["packages/axo-api-worker/src/apps/runner.ts#WORKER_SOURCE"],
      sends: [ToolCall, ScriptDone],
      run(state, m, ctx) {
        const run = state.runs[m.request];
        if (!run) return;
        run.results.push(m.output);
        const call = run.calls[run.next];
        if (call) {
          run.next += 1;
          return ctx.send(ctx.the(Manager), ToolCall, { request: m.request, call });
        }
        delete state.runs[m.request];
        ctx.send(ctx.the(Manager), ScriptDone, { request: m.request, results: run.results });
      },
    },
    abort: {
      on: Abort,
      description: "The Durable Object aborted the script; it stops where it is.",
      sources: ["packages/axo-api-worker/src/apps/runner.ts#ToolDispatcher.close"],
      run: (state, m) => void delete state.runs[m.request],
    },
    toolError: {
      on: ToolError,
      description: "The tool call threw; the script does not catch it, so it fails.",
      sources: ["packages/axo-api-worker/src/apps/runner.ts#WORKER_SOURCE"],
      sends: [ScriptFailed],
      run(state, m, ctx) {
        if (!state.runs[m.request]) return;
        delete state.runs[m.request];
        ctx.send(ctx.the(Manager), ScriptFailed, { request: m.request, error: m.error });
      },
    },
    // Faults: what the network and restarts may do here.
    runScriptLost: lose(RunScript, { spend: faults }),
    toolResultLost: lose(ToolResult, { spend: faults }),
    abortLost: lose(Abort, { spend: faults }),
    toolErrorLost: lose(ToolError, { spend: faults }),
  },
});

export const Linear = defineActor({
  name: "Linear MCP",
  description: "A third-party MCP server. It answers whoever presents a valid grant.",
  zone: services,
  singleton: true,
  initialState: () => ({ calls: [] as { call: string; token: string }[] }),
  display: { icon: "server", status: (s) => `${s.calls.length} call(s) served` },
  transitions: {
    mcpCall: {
      on: McpCall,
      description: "Runs the tool for the grant's owner.",
      sends: [McpResult],
      run(state, m, ctx) {
        state.calls.push({ call: m.call, token: m.token });
        ctx.reply(McpResult, { call: m.call, output: `issues for ${m.token.replace(/^grant:/, "").replace(/-linear$/, "")}` });
      },
    },
    // Faults: what the network and restarts may do here.
    mcpCallLost: lose(McpCall, { spend: faults }),
  },
});

export const Axod = defineActor({
  name: "axod relay",
  description: "The daemon on each Mac and its relay socket: it forwards Sessions' scripts and runs bash, each command on a thread of its own.",
  zone: macs,
  initialState: (ctx) => ({
    host: hostOf(ctx.label),
    account: (MACS[hostOf(ctx.label)] ?? null) as string | null,
    connected: false,
    /** Each relay socket gets a new epoch; replies only go out on the socket their request came on. */
    epoch: 1,
    waiting: {} as Record<string, string>,
    /** Commands running on their own threads, by call, with the socket they came on. */
    jobs: {} as Record<string, { epoch: number; command: string }>,
    ran: [] as { call: string; account: string; command: string; owner: string }[],
  }),
  // The relay closes when axod restarts, and running commands die with it; what ran stays run.
  display: {
    icon: "terminal",
    names: ["Laptop daemon", "Studio daemon", "Workbench daemon"],
    status: (s) => (s.connected ? `connected, ${s.ran.length} command(s) run` : "relay down"),
    mood: (s) => (s.connected ? "ok" : "off"),
    owner: (s) => (s.account ? cap(who(s.account)) : null),
  },
  links: (s) => (s.connected ? [{ to: "HostDO", kind: "websocket", row: s.host }] : []),
  actions: {
    dropRelay: {
      with: [atMost(2)],
      label: "Relay drops",
      description: "The relay socket closes; scripts this Mac's Sessions are waiting on fail at once.",
      when: (s) => s.connected,
      sends: [Disconnected, RelayDown],
      run(state, _inputs, ctx) {
        state.connected = false;
        ctx.send(ctx.the(Ingress), Disconnected, { host: state.host, epoch: state.epoch });
        failWaiting(state, ctx);
      },
    },
    reconnect: {
      with: [atMost(2)],
      label: "Relay reconnects",
      description: "axod brings the relay back up on a new socket.",
      when: (s) => !s.connected && s.account !== null,
      sends: [Reconnected],
      run(state, _inputs, ctx) {
        state.connected = true;
        state.epoch += 1;
        ctx.send(ctx.the(Ingress), Reconnected, { host: state.host, epoch: state.epoch });
      },
    },
  },
  transitions: {
    execute: {
      on: Execute,
      description: "Forwards a Session's script over the relay, or refuses at once when the relay is down.",
      sources: ["crates/axo-server/src/apps.rs#forward"],
      sends: [Forward, RelayDown],
      run(state, m, ctx) {
        if (!state.connected || !state.account) return ctx.reply(RelayDown, { request: m.request });
        state.waiting[m.request] = ctx.from.id;
        ctx.send(ctx.the(Ingress), Forward, { request: m.request, script: m.script, epoch: state.epoch });
      },
    },
    answer: {
      on: Answer,
      description: "Hands the script's result to the Session that asked.",
      sources: ["crates/axo-server/src/apps.rs#forward"],
      sends: [Done],
      run(state, m, ctx) {
        if (m.epoch !== state.epoch) return;
        const session = ctx.all(Session).find((x) => x.id === state.waiting[m.request]);
        delete state.waiting[m.request];
        if (session) ctx.send(session, Done, { request: m.request, results: m.results });
      },
    },
    refused: {
      on: Refused,
      description: "Hands the script's error to the Session that asked.",
      sources: ["crates/axo-server/src/apps.rs#forward"],
      sends: [Failed],
      run(state, m, ctx) {
        if (m.epoch !== state.epoch) return;
        const session = ctx.all(Session).find((x) => x.id === state.waiting[m.request]);
        delete state.waiting[m.request];
        if (session) ctx.send(session, Failed, { request: m.request, error: m.error });
      },
    },
    revoked: {
      on: Revoked,
      description: "The account revoked this Mac: the relay closes and axod forgets its link.",
      sends: [RelayDown],
      run(state, m, ctx) {
        if (m.epoch !== state.epoch) return;
        state.account = null;
        state.connected = false;
        failWaiting(state, ctx);
      },
    },
    bash: {
      on: Bash,
      description: "Starts the command on a thread of its own as axod's user, so the relay keeps serving; one for another socket or account is dropped.",
      sources: ["crates/axo-relay/src/relay/jobs.rs#start_bash"],
      say: (s, m) => `Started \`${m.command}\` on ${cap(s.host)}`,
      run(state, m) {
        if (!state.connected || !state.account || m.epoch !== state.epoch || m.account !== state.account) return;
        state.jobs[m.call] = { epoch: m.epoch, command: m.command };
        state.ran.push({ call: m.call, account: m.account, command: m.command, owner: MACS[state.host]! });
      },
    },
    finish: {
      description: "A command exits; its output goes back on the socket it came on, or nowhere if that socket closed.",
      sources: ["crates/axo-relay/src/relay/jobs.rs#start_bash"],
      when: (s) => Object.keys(s.jobs).length > 0,
      sends: [BashDone],
      run(state, _, ctx) {
        const [call, job] = Object.entries(state.jobs)[0]!;
        delete state.jobs[call];
        if (state.connected && job.epoch === state.epoch)
          ctx.send(ctx.the(Ingress), BashDone, { call, output: `${job.command} on ${state.host}`, epoch: job.epoch });
      },
    },
    // Faults: what the network and restarts may do here.
    executeLost: lose(Execute, { spend: faults }),
    answerLost: lose(Answer, { spend: faults }),
    refusedLost: lose(Refused, { spend: faults }),
    revokedLost: lose(Revoked, { spend: faults }),
    bashLost: lose(Bash, { spend: faults }),
    crash: crash({ keeps: ["account", "ran", "epoch"], spend: faults }),
  },
});

function failWaiting(state: any, ctx: any): void {
  for (const [request, session] of Object.entries(state.waiting) as [string, string][]) {
    const s = ctx.all(Session).find((x: any) => x.id === session);
    if (s) ctx.send(s, RelayDown, { request });
  }
  state.waiting = {};
}

export const Session = defineActor({
  name: "Session",
  description: "The Pi agent in an Axo Session, calling apps_execute through axod mcp.",
  zone: macs,
  initialState: (ctx) => ({
    host: hostOf(ctx.label),
    account: MACS[hostOf(ctx.label)] ?? null,
    pending: null as null | { request: string; script: ScriptName },
    outcomes: [] as { script: ScriptName; outcome: string }[],
  }),
  display: {
    icon: "robot",
    names: ["Laptop session", "Workbench session"],
    status: (s) => (s.pending ? `running ${s.pending.script}` : s.outcomes.length ? s.outcomes.at(-1)!.outcome : "idle"),
    mood: (s) => (s.pending ? "busy" : s.outcomes.at(-1)?.outcome.startsWith("ok") ? "ok" : s.outcomes.length ? "warn" : "off"),
    owner: (s) => (s.account ? cap(who(s.account)) : null),
  },
  actions: {
    execute: {
      with: [atMost(2)],
      label: "Run a script",
      description: "The agent runs a apps script.",
      sources: ["crates/axo-mcp/src/lib.rs#McpServer.call_tool"],
      inputs: { script: input(String, { examples: Object.keys(CALLS) }) },
      when: (s) => s.pending === null,
      sends: [Execute],
      starts: ["deadline"],
      run(state, { script }, ctx) {
        const request = ctx.fresh("req");
        state.pending = { request, script: script as ScriptName };
        const daemon = ctx.all(Axod).find((a) => a.state.host === state.host);
        if (daemon) ctx.send(daemon, Execute, { request, script: script as ScriptName });
        ctx.start("deadline");
      },
    },
  },
  transitions: {
    done: {
      on: Done,
      description: "The script returned.",
      run(state, m, ctx) {
        if (state.pending?.request !== m.request) return;
        state.outcomes.push({ script: state.pending.script, outcome: `ok: ${m.results.join("; ")}` });
        state.pending = null;
        ctx.cancel("deadline");
      },
    },
    failed: {
      on: Failed,
      description: "The script failed with an error the agent can read.",
      run(state, m, ctx) {
        if (state.pending?.request !== m.request) return;
        state.outcomes.push({ script: state.pending.script, outcome: `error: ${m.error}` });
        state.pending = null;
        ctx.cancel("deadline");
      },
    },
    relayDown: {
      on: RelayDown,
      description: "This Mac cannot reach its account right now.",
      run(state, m, ctx) {
        if (state.pending?.request !== m.request) return;
        state.outcomes.push({ script: state.pending.script, outcome: "error: relay down" });
        state.pending = null;
        ctx.cancel("deadline");
      },
    },
    deadline: {
      description: "No answer in time; the call fails and its outcome is unknown.",
      after: "5 minutes",
      run(state) {
        if (!state.pending) return;
        state.outcomes.push({ script: state.pending.script, outcome: "error: deadline passed, outcome unknown" });
        state.pending = null;
      },
    },
    // Faults: what the network and restarts may do here.
    doneLost: lose(Done, { spend: faults }),
    failedLost: lose(Failed, { spend: faults }),
    relayDownLost: lose(RelayDown, { spend: faults }),
    crash: crash({ spend: faults }),
  },
});

const bashOnlyOnOwnMacs = defineProperty("bashOnlyOnOwnMacs", {
  description: "A Mac only runs commands for the account it is paired with.",
  always: (w) => w.all(Axod).every((a) => a.state.ran.every((r) => r.account === r.owner)),
});
const grantsOnlyFromTheirAccount = defineProperty("grantsOnlyFromTheirAccount", {
  description: "Every third-party call uses the grant of the account whose script made it.",
  always: (w) => {
    const log = w.the(Manager).state.log;
    return w.the(Linear).state.calls.every((c) => { const rec = log.find((r) => r.call === c.call); return rec !== undefined && grantOf(rec.account) === c.token; });
  },
});
const grantsStayInTheCloud = defineProperty("grantsStayInTheCloud", {
  description: "No Mac, Session or socket owner ever holds a grant.",
  always: (w) => [...w.all(Axod), ...w.all(Session), w.the(Ingress)].every((x) => !JSON.stringify(x.state).includes("grant:")),
});
const noThirdPartyCallRunsTwice = defineProperty("noThirdPartyCallRunsTwice", {
  description: "A third-party tool call reaches the service at most once, even when its answer is lost.",
  always: (w) => { const calls = w.the(Linear).state.calls.map((c) => c.call); return new Set(calls).size === calls.length; },
});
const revokedMacsRunNothingNew = defineProperty("revokedMacsRunNothingNew", {
  description: "Once a Mac is unpaired, no command dispatched after that runs on it.",
  always: (w) => {
    const m = w.the(Manager).state;
    return w.all(Axod).every((a) => {
      const at = m.unpairedAt[a.state.host];
      return at === undefined || a.state.ran.every((r) => m.log.findIndex((l) => l.call === r.call) < at);
    });
  },
});
const scriptsStayWithinLimit = defineProperty("scriptsStayWithinLimit", {
  description: "No script reaches a service or a Mac more often than its call limit allows.",
  always: (w) => { const per: Record<string, number> = {}; for (const r of w.the(Manager).state.log) per[r.request] = (per[r.request] ?? 0) + 1; return Object.values(per).every((n) => n <= MAX_CALLS); },
});
const noCommandRunsTwice = defineProperty("noCommandRunsTwice", {
  description: "A dispatched command runs at most once, even when the relay drops around it.",
  always: (w) => { const calls = w.all(Axod).flatMap((a) => a.state.ran.map((r) => r.call)); return new Set(calls).size === calls.length; },
});
const everyCallIsLogged = defineProperty("everyCallIsLogged", {
  description: "Every command a Mac ran and every third-party call has a record in the call log.",
  always: (w) => {
    const logged = new Set(w.the(Manager).state.log.map((r) => r.call));
    return w.all(Axod).every((a) => a.state.ran.every((r) => logged.has(r.call))) && w.the(Linear).state.calls.every((c) => logged.has(c.call));
  },
});
const appsStateStaysInTheAccount = defineProperty("appsStateStaysInTheAccount", {
  description: "The socket owner never holds apps, runs or the call log: it only knows sockets, what it forwarded, and the callHost RPCs waiting on a socket.",
  always: (w) => Object.keys(w.the(Ingress).state).every((k) => ["sockets", "revoked", "forwarded", "calling"].includes(k)),
});
const sessionsGetAnAnswer = defineProperty("sessionsGetAnAnswer", {
  description: "A Session waiting on a script always gets an answer: a result, an error, or its deadline.",
  leadsTo: { whenever: (w) => w.all(Session).some((s) => s.state.pending !== null), then: (w) => w.all(Session).every((s) => s.state.pending === null) },
});

const aliceAndBob = (w: any) => {
  w.spawn(Axod, "Laptop daemon", { connected: true });
  w.spawn(Axod, "Studio daemon", { connected: true });
  w.spawn(Axod, "Workbench daemon", { connected: true });
  w.spawn(Session, "Laptop session");
};
const jobRunning = (w: any) => w.all(Axod).some((a: any) => Object.keys(a.state.jobs).length > 0);

const readLinearFromASession = defineScenario("Read Linear from a Session", {
  description: "Alice's agent on her laptop lists Linear issues; the cloud calls Linear with Alice's grant.",
  setup: aliceAndBob,
  run(s) {
    s.act(s.world.all(Session)[0]!, "execute", { script: "linear" });
    s.settle();
  },
});
const runACommandOnAnotherMac = defineScenario("Run a command on another Mac", {
  description: "Alice's agent on her laptop runs uptime on her Studio: through the laptop's socket owner to the account, and through the Studio's socket owner down to the Studio.",
  setup: aliceAndBob,
  run(s) {
    s.act(s.world.all(Session)[0]!, "execute", { script: "bash:studio" });
    s.settle();
  },
});
const linearThenACommandInOneScript = defineScenario("Linear, then a command, in one script", {
  description: "One script reads Linear in the cloud and passes the result to a command on the Studio.",
  setup: aliceAndBob,
  run(s) {
    s.act(s.world.all(Session)[0]!, "execute", { script: "linear+bash:studio" });
    s.settle();
  },
});
const bobSMacIsNotAliceSConnection = defineScenario("Bob's Mac is not Alice's connection", {
  description: "Alice's script names Bob's workbench; her account has no connection by that name, so nothing reaches Bob's Mac.",
  setup: aliceAndBob,
  run(s) {
    s.act(s.world.all(Session)[0]!, "execute", { script: "bash:workbench" });
    s.settle();
  },
});
const theStudioDropsMidCommand = defineScenario("The Studio drops mid-command", {
  description: "The Studio's relay closes while its command runs; the script fails with 'may have run', the command is not sent again, and its late output is dropped.",
  setup: aliceAndBob,
  run(s) {
    const studio = s.world.all(Axod).find((a) => a.label === "Studio daemon")!;
    s.act(s.world.all(Session)[0]!, "execute", { script: "bash:studio" });
    s.settle({ until: jobRunning });
    s.act(studio, "dropRelay");
    s.settle();
  },
});
const aScriptThatMakesTooManyCalls = defineScenario("A script that makes too many calls", {
  description: "The third call is refused against the script's limit, so the script fails; the first two ran.",
  setup: aliceAndBob,
  run(s) {
    s.act(s.world.all(Session)[0]!, "execute", { script: "bash:studio x3" });
    s.settle();
  },
});
const theStudioIsUnpairedMidCommand = defineScenario("The Studio is unpaired mid-command", {
  description: "Alice unpairs her Studio while a command runs there; the script fails at once, the Studio's socket closes, its late output is dropped, and the Studio is no longer a connection.",
  setup: aliceAndBob,
  run(s) {
    s.act(s.world.all(Session)[0]!, "execute", { script: "bash:studio" });
    s.settle({ until: jobRunning });
    s.act(s.the(Manager), "unpair", { host: "studio" });
    s.settle();
  },
});
const aScriptRunsOutOfTime = defineScenario("A script runs out of time", {
  description: "The script's wall time passes while a command runs; the account aborts it and tells the laptop, and the command's late output is ignored.",
  setup: aliceAndBob,
  run(s) {
    s.act(s.world.all(Session)[0]!, "execute", { script: "bash:studio" });
    s.settle({ until: jobRunning });
    s.fire(s.the(Manager), "wallTime");
    s.settle();
  },
});
const theLaptopSRelayIsDown = defineScenario("The laptop's relay is down", {
  description: "With its relay down, the laptop refuses the script at once instead of waiting.",
  setup: aliceAndBob,
  run(s) {
    s.act(s.world.all(Axod).find((a) => a.label === "Laptop daemon")!, "dropRelay");
    s.settle();
    s.act(s.world.all(Session)[0]!, "execute", { script: "linear" });
    s.settle();
  },
});

const macGroup = defineGroup({ name: "Mac", actors: { daemon: Axod, session: Session }, icon: "laptop", names: ["Laptop", "Studio", "Workbench"] });
const axoCloudGroup = defineGroup({ name: "Axo cloud", actors: [Ingress, Manager, Worker], icon: "cloud", collapsed: false });

export default defineSpec({
  name: "Apps",
  description:
    "How an agent in an Axo Session runs a script over its account's apps: third-party tools are called from the cloud with the account's grant, and bash runs on the Mac it names, reached over that Mac's relay.",
  actors: [Ingress, Manager, Worker, Linear, Axod, Session],
  groups: [macGroup, axoCloudGroup],
  limits: [limit1, limit2, limit3, limit4, limit5],
  properties: [bashOnlyOnOwnMacs, grantsOnlyFromTheirAccount, grantsStayInTheCloud, noThirdPartyCallRunsTwice, revokedMacsRunNothingNew, scriptsStayWithinLimit, noCommandRunsTwice, everyCallIsLogged, appsStateStaysInTheAccount, sessionsGetAnAnswer],
  scenarios: [readLinearFromASession, runACommandOnAnotherMac, linearThenACommandInOneScript, bobSMacIsNotAliceSConnection, theStudioDropsMidCommand, aScriptThatMakesTooManyCalls, theStudioIsUnpairedMidCommand, aScriptRunsOutOfTime, theLaptopSRelayIsDown],
});
