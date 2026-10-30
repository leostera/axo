import { call, defineSpec, message } from "@leostera/feynman";

const SEC = 1_000;
const MIN = 60 * SEC;

// RFD0016: an agent in an Axo Session runs a connections script. The script runs in the account's
// cloud Dynamic Worker; third-party tools are called from the cloud with the account's grant, and
// `bash` travels over the host relay to the Mac it names.
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
type Run = { account: string; from: string; calls: number };
type Dispatch = { request: string; account: string; target: string };
type LogRecord = { account: string; request: string; service: string; tool: string; input: string; call: string };

export default defineSpec(
  "Connections",
  {
    description:
      "How an agent in an Axo Session runs a script over its account's connections: third-party tools are called from the cloud with the account's grant, and bash runs on the Mac it names, reached over that Mac's relay.",
    messages: {
      // Session agent -> axod (axod mcp over axod.sock)
      Execute: message<{ request: string; script: ScriptName }>({ name: "connections_execute", over: "unix socket" }),
      Done: message<{ request: string; results: string[] }>({ name: "script result", over: "unix socket", tone: "reply" }),
      Failed: message<{ request: string; error: string }>({ name: "script failed", over: "unix socket", tone: "refused" }),
      RelayDown: message<{ request: string }>({ name: "this Mac is not connected to its account", over: "unix socket", tone: "refused" }),
      // axod <-> AxoAccountManager over the host relay WebSocket
      Forward: message<{ request: string; account: string; script: ScriptName }>({ name: "axo.connections.execute", over: "websocket" }),
      Answer: message<{ request: string; results: string[] }>({ name: "execute result", over: "websocket", tone: "reply" }),
      Refused: message<{ request: string; error: string }>({ name: "execute failed", over: "websocket", tone: "refused" }),
      Bash: message<{ call: string; account: string; command: string; epoch: number }>({ name: "axo.connections.bash", over: "websocket" }),
      BashDone: message<{ call: string; output: string; epoch: number }>({ name: "bash result", over: "websocket", tone: "reply" }),
      Disconnected: message<{ host: string; epoch: number }>({ name: "relay socket closed", over: "websocket", tone: "refused" }),
      Reconnected: message<{ host: string; epoch: number }>({ name: "relay socket open", over: "websocket" }),
      Revoked: message<{ epoch: number }>({ name: "close 4003: host revoked", over: "websocket", tone: "refused" }),
      // AxoAccountManager <-> script Worker (Dynamic Worker binding)
      RunScript: message<{ request: string; account: string; calls: Call[] }>({ name: "run script", over: "rpc" }),
      ToolCall: message<{ request: string; call: Call }>({ name: "codemode tool call", over: "rpc" }),
      ToolResult: message<{ request: string; output: string }>({ name: "tool result", over: "rpc", tone: "reply" }),
      ToolError: message<{ request: string; error: string }>({ name: "tool failed", over: "rpc", tone: "refused" }),
      ScriptDone: message<{ request: string; results: string[] }>({ name: "script returned", over: "rpc", tone: "reply" }),
      ScriptFailed: message<{ request: string; error: string }>({ name: "script threw", over: "rpc", tone: "refused" }),
      Abort: message<{ request: string }>({ name: "abort the script", over: "rpc" }),
      // AxoAccountManager <-> Linear's MCP server
      McpCall: call<{ call: string; tool: string; token: string }>({ name: "tools/call", over: "https" }),
      McpResult: message<{ call: string; output: string }>({ name: "tools/call result", over: "https", tone: "reply" }),
    },
  },
  (spec) => {
    const {
      Execute, Done, Failed, RelayDown, Forward, Answer, Refused, Bash, BashDone, Disconnected, Reconnected, Revoked,
      RunScript, ToolCall, ToolResult, ToolError, ScriptDone, ScriptFailed, Abort, McpCall, McpResult,
    } = spec.messages;

    const macs = spec.defineZone({ name: "Macs", description: "each runs axod and Axo Sessions" });
    const cloudflare = spec.defineZone({ name: "Cloudflare", description: "the account's Durable Object and its script Worker", place: { column: 1, region: true } });
    const services = spec.defineZone({ name: "Third-party services", description: "remote MCP servers", place: { column: 2 } });

    spec.defineLimit({ name: "Script wall time", value: 5 * MIN });
    spec.defineLimit({ name: "Tool calls per script", value: 100, unit: "calls" });
    spec.defineLimit({ name: "Concurrent tool calls per script", value: 4, unit: "calls" });
    spec.defineLimit({ name: "bash default timeout", value: 60 * SEC });
    spec.defineLimit({ name: "Call log retention", value: 30, unit: "days" });

    const Manager = spec.defineActor({
      name: "AxoAccountManager",
      description: "The account's Durable Object: it holds connections and grants, runs scripts in a Worker, and dispatches their tool calls.",
      zone: cloudflare,
      singleton: true,
      initialState: () => ({
        connections: Object.fromEntries(
          ACCOUNTS.map((account) => [
            account,
            {
              linear: { kind: "third-party", grant: grantOf(account) } as Connection,
              ...Object.fromEntries(Object.entries(MACS).filter(([, a]) => a === account).map(([host]) => [host, { kind: "host" } as Connection])),
            },
          ]),
        ) as Record<string, Record<string, Connection>>,
        online: Object.fromEntries(Object.keys(MACS).map((host) => [host, true])) as Record<string, boolean>,
        /** The epoch of each Mac's current relay socket. */
        epochs: Object.fromEntries(Object.keys(MACS).map((host) => [host, 1])) as Record<string, number>,
        runs: {} as Record<string, Run>,
        dispatched: {} as Record<string, Dispatch>,
        log: [] as LogRecord[],
      }),
      durable: ["connections", "log"],
      display: {
        icon: "cloud",
        status: (s) => `${Object.keys(s.runs).length} script(s) running`,
        rows: (s) => [
          ...Object.entries(s.connections).flatMap(([account, cs]) =>
            Object.entries(cs).map(([name, c]) => ({
              group: `${cap(who(account))}'s connections`,
              owner: cap(who(account)),
              label: name,
              detail: c.kind === "host" ? (s.online[name] ? "host, online" : "host, offline") : "third-party, grant held here",
              mood: c.kind === "host" && !s.online[name] ? ("off" as const) : ("ok" as const),
            })),
          ),
          ...(s.log.length ? [{ group: "Call log", label: `${s.log.length} record(s)`, detail: s.log.at(-1)!.service + "." + s.log.at(-1)!.tool }] : []),
        ],
      },
      actions: {
        unpair: {
          label: "Unpair a Mac",
          description: "The person revokes a Mac (RFD0013): its host connection is removed, its relay closed, and commands sent to it fail.",
          inputs: { host: spec.defineInput(String, { examples: ["studio"] }) },
          when: (s) => Object.values(s.connections).some((cs) => "studio" in cs),
          sends: [ToolError, Revoked],
          run(state, { host }, ctx) {
            for (const cs of Object.values(state.connections)) delete cs[host];
            state.online[host] = false;
            failCommandsTo(state, host, `${host} was unpaired; the command may have run`, ctx);
            const daemon = ctx.all(Axod).find((a) => hostOf(a.label) === host);
            if (daemon) ctx.send(daemon, Revoked, { epoch: state.epochs[host]! });
          },
        },
      },
      transitions: {
        [Forward]: {
          description: "Starts the script in the account's Worker, under the script's wall time.",
          sends: [RunScript],
          starts: ["wallTime"],
          say: (_s, m) => `Running ${m.script} for ${cap(who(m.account))} in a Dynamic Worker`,
          run(state, m, ctx) {
            state.runs[m.request] = { account: m.account, from: ctx.from.id, calls: 0 };
            ctx.send(ctx.the(Worker), RunScript, { request: m.request, account: m.account, calls: CALLS[m.script] });
            ctx.start("wallTime");
          },
        },
        wallTime: {
          description: "A script ran past its wall time: it is aborted, its calls in flight are abandoned, and the Mac that asked hears so.",
          after: "5 minutes",
          sends: [Abort, Refused],
          run(state, ctx) {
            for (const [request, run] of Object.entries(state.runs)) {
              delete state.runs[request];
              for (const [call, d] of Object.entries(state.dispatched)) if (d.request === request) delete state.dispatched[call];
              ctx.send(ctx.the(Worker), Abort, { request });
              const from = ctx.all(Axod).find((a) => a.id === run.from);
              if (from) ctx.send(from, Refused, { request, error: "script wall time exceeded; calls in flight may have run" });
            }
          },
        },
        [ToolCall]: {
          description: "Counts the call against the script's limit, looks the service up among the account's own connections, logs the call, and sends it to the service or the Mac.",
          sends: [McpCall, Bash, ToolError],
          run(state, m, ctx) {
            const run = state.runs[m.request];
            if (!run) return;
            if (run.calls >= MAX_CALLS) return ctx.reply(ToolError, { request: m.request, error: `a script may make at most ${MAX_CALLS} tool calls` });
            run.calls += 1;
            const connection = state.connections[run.account]?.[m.call.service];
            if (!connection) return ctx.reply(ToolError, { request: m.request, error: `no connection named ${m.call.service}` });
            if (connection.kind === "host" && !state.online[m.call.service]) return ctx.reply(ToolError, { request: m.request, error: `${m.call.service} is offline` });
            const call = ctx.fresh("call");
            state.log.push({ account: run.account, request: m.request, service: m.call.service, tool: m.call.tool, input: m.call.input, call });
            state.dispatched[call] = { request: m.request, account: run.account, target: m.call.service };
            if (connection.kind === "third-party") return ctx.send(ctx.the(Linear), McpCall, { call, tool: m.call.tool, token: connection.grant });
            const daemon = ctx.all(Axod).find((a) => hostOf(a.label) === m.call.service);
            if (daemon) ctx.send(daemon, Bash, { call, account: run.account, command: m.call.input, epoch: state.epochs[m.call.service]! });
          },
        },
        [McpResult]: {
          description: "Hands the service's answer back to the script.",
          sends: [ToolResult],
          run(state, m, ctx) {
            const d = state.dispatched[m.call];
            if (!d) return;
            delete state.dispatched[m.call];
            ctx.send(ctx.the(Worker), ToolResult, { request: d.request, output: m.output });
          },
        },
        [spec.failed(McpCall)]: {
          description: "The request to the service failed or its answer was lost; the tool call fails and is not sent again, since the service may already have acted.",
          sends: [ToolError],
          run(state, failure, ctx) {
            const d = state.dispatched[failure.payload.call];
            if (!d) return;
            delete state.dispatched[failure.payload.call];
            ctx.send(ctx.the(Worker), ToolError, { request: d.request, error: `${d.target} did not answer; the call may have run` });
          },
        },
        [BashDone]: {
          description: "Hands the command's output back to the script, if it came on the socket the command was sent on.",
          sends: [ToolResult],
          run(state, m, ctx) {
            const d = state.dispatched[m.call];
            if (!d || state.epochs[d.target] !== m.epoch) return;
            delete state.dispatched[m.call];
            ctx.send(ctx.the(Worker), ToolResult, { request: d.request, output: m.output });
          },
        },
        [Disconnected]: {
          description: "The Mac's relay closed: every command sent to it fails at once and is not sent again, since it may already have run.",
          sends: [ToolError],
          run(state, m, ctx) {
            if (m.epoch !== state.epochs[m.host]) return;
            state.online[m.host] = false;
            failCommandsTo(state, m.host, `${m.host} went offline; the command may have run`, ctx);
            for (const [request, run] of Object.entries(state.runs)) if (hostOf(ctx.all(Axod).find((a) => a.id === run.from)?.label ?? "") === m.host) delete state.runs[request];
          },
        },
        [Reconnected]: {
          description: "The Mac's relay is back on a new socket, if the Mac is still paired.",
          run(state, m) {
            if (m.epoch <= state.epochs[m.host]!) return;
            state.epochs[m.host] = m.epoch;
            if (Object.values(state.connections).some((cs) => m.host in cs)) state.online[m.host] = true;
          },
        },
        [ScriptDone]: {
          description: "Returns the script's result to the Mac that asked.",
          sends: [Answer],
          run(state, m, ctx) {
            const run = state.runs[m.request];
            if (!run) return;
            delete state.runs[m.request];
            if (!Object.keys(state.runs).length) ctx.cancel("wallTime");
            const from = ctx.all(Axod).find((a) => a.id === run.from);
            if (from) ctx.send(from, Answer, { request: m.request, results: m.results });
          },
        },
        [ScriptFailed]: {
          description: "Returns the script's error to the Mac that asked.",
          sends: [Refused],
          run(state, m, ctx) {
            const run = state.runs[m.request];
            if (!run) return;
            delete state.runs[m.request];
            if (!Object.keys(state.runs).length) ctx.cancel("wallTime");
            const from = ctx.all(Axod).find((a) => a.id === run.from);
            if (from) ctx.send(from, Refused, { request: m.request, error: m.error });
          },
        },
      },
    });

    /** Fails every command in flight to `host`: it is not sent again, since it may already have run. */
    function failCommandsTo(state: any, host: string, error: string, ctx: any): void {
      for (const [call, d] of Object.entries(state.dispatched) as [string, Dispatch][]) {
        if (d.target !== host) continue;
        delete state.dispatched[call];
        ctx.send(ctx.the(Worker), ToolError, { request: d.request, error });
      }
    }

    const Worker = spec.defineActor({
      name: "Script Worker",
      description: "The Dynamic Worker that runs connections scripts. It has no network of its own; every tool call goes back to the account's Durable Object.",
      zone: cloudflare,
      singleton: true,
      initialState: () => ({ runs: {} as Record<string, { calls: Call[]; next: number; results: string[] }> }),
      display: {
        icon: "code",
        status: (s) => (Object.keys(s.runs).length ? `${Object.keys(s.runs).length} script(s)` : "idle"),
        mood: (s) => (Object.keys(s.runs).length ? "busy" : "off"),
      },
      transitions: {
        [RunScript]: {
          description: "Runs the script up to its first tool call.",
          sends: [ToolCall],
          run(state, m, ctx) {
            state.runs[m.request] = { calls: m.calls, next: 1, results: [] };
            ctx.reply(ToolCall, { request: m.request, call: m.calls[0]! });
          },
        },
        [ToolResult]: {
          description: "Continues the script with the result: makes the next call, or returns.",
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
        [Abort]: {
          description: "The Durable Object aborted the script; it stops where it is.",
          run: (state, m) => void delete state.runs[m.request],
        },
        [ToolError]: {
          description: "The tool call threw; the script does not catch it, so it fails.",
          sends: [ScriptFailed],
          run(state, m, ctx) {
            if (!state.runs[m.request]) return;
            delete state.runs[m.request];
            ctx.send(ctx.the(Manager), ScriptFailed, { request: m.request, error: m.error });
          },
        },
      },
    });

    const Linear = spec.defineActor({
      name: "Linear MCP",
      description: "A third-party MCP server. It answers whoever presents a valid grant.",
      zone: services,
      singleton: true,
      initialState: () => ({ calls: [] as { call: string; token: string }[] }),
      display: { icon: "server", status: (s) => `${s.calls.length} call(s) served` },
      transitions: {
        [McpCall]: {
          description: "Runs the tool for the grant's owner.",
          sends: [McpResult],
          run(state, m, ctx) {
            state.calls.push({ call: m.call, token: m.token });
            ctx.reply(McpResult, { call: m.call, output: `issues for ${m.token.replace(/^grant:/, "").replace(/-linear$/, "")}` });
          },
        },
      },
    });

    const Axod = spec.defineActor({
      name: "axod",
      description: "The daemon on each Mac: it holds the relay to the account, forwards Sessions' scripts, and runs bash.",
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
      durable: ["account", "ran", "epoch"],
      display: {
        icon: "terminal",
        names: ["Laptop daemon", "Studio daemon", "Workbench daemon"],
        status: (s) => (s.connected ? `connected, ${s.ran.length} command(s) run` : "relay down"),
        mood: (s) => (s.connected ? "ok" : "off"),
        owner: (s) => (s.account ? cap(who(s.account)) : null),
      },
      links: (s) => (s.connected ? [{ to: "AxoAccountManager", kind: "websocket", row: s.host }] : []),
      actions: {
        dropRelay: {
          label: "Relay drops",
          description: "The relay socket closes; scripts this Mac's Sessions are waiting on fail at once.",
          when: (s) => s.connected,
          sends: [Disconnected, RelayDown],
          run(state, _inputs, ctx) {
            state.connected = false;
            ctx.send(ctx.the(Manager), Disconnected, { host: state.host, epoch: state.epoch });
            for (const [request, session] of Object.entries(state.waiting)) {
              const s = ctx.all(Session).find((x) => x.id === session);
              if (s) ctx.send(s, RelayDown, { request });
            }
            state.waiting = {};
          },
        },
        reconnect: {
          label: "Relay reconnects",
          description: "axod brings the relay back up.",
          when: (s) => !s.connected && s.account !== null,
          sends: [Reconnected],
          run(state, _inputs, ctx) {
            state.connected = true;
            state.epoch += 1;
            ctx.send(ctx.the(Manager), Reconnected, { host: state.host, epoch: state.epoch });
          },
        },
      },
      transitions: {
        [Execute]: {
          description: "Forwards a Session's script over the relay, or refuses at once when the relay is down.",
          sends: [Forward, RelayDown],
          run(state, m, ctx) {
            if (!state.connected || !state.account) return ctx.reply(RelayDown, { request: m.request });
            state.waiting[m.request] = ctx.from.id;
            ctx.send(ctx.the(Manager), Forward, { request: m.request, account: state.account, script: m.script });
          },
        },
        [Answer]: {
          description: "Hands the script's result to the Session that asked.",
          sends: [Done],
          run(state, m, ctx) {
            const session = ctx.all(Session).find((x) => x.id === state.waiting[m.request]);
            delete state.waiting[m.request];
            if (session) ctx.send(session, Done, { request: m.request, results: m.results });
          },
        },
        [Refused]: {
          description: "Hands the script's error to the Session that asked.",
          sends: [Failed],
          run(state, m, ctx) {
            const session = ctx.all(Session).find((x) => x.id === state.waiting[m.request]);
            delete state.waiting[m.request];
            if (session) ctx.send(session, Failed, { request: m.request, error: m.error });
          },
        },
        [Revoked]: {
          description: "The account revoked this Mac: the relay closes and axod forgets its link.",
          sends: [RelayDown],
          run(state, m, ctx) {
            if (m.epoch !== state.epoch) return;
            state.account = null;
            state.connected = false;
            for (const [request, session] of Object.entries(state.waiting)) {
              const s = ctx.all(Session).find((x) => x.id === session);
              if (s) ctx.send(s, RelayDown, { request });
            }
            state.waiting = {};
          },
        },
        [Bash]: {
          description: "Starts the command on a thread of its own as axod's user, so the relay keeps serving; one for another socket is dropped.",
          say: (s, m) => `Started \`${m.command}\` on ${cap(s.host)}`,
          run(state, m) {
            if (!state.connected || !state.account || m.epoch !== state.epoch || m.account !== state.account) return;
            state.jobs[m.call] = { epoch: m.epoch, command: m.command };
            state.ran.push({ call: m.call, account: m.account, command: m.command, owner: MACS[state.host]! });
          },
        },
        finish: {
          description: "A command exits; its output goes back on the socket it came on, or nowhere if that socket closed.",
          when: (s) => Object.keys(s.jobs).length > 0,
          sends: [BashDone],
          run(state, ctx) {
            const [call, job] = Object.entries(state.jobs)[0]!;
            delete state.jobs[call];
            if (state.connected && job.epoch === state.epoch)
              ctx.send(ctx.the(Manager), BashDone, { call, output: `${job.command} on ${state.host}`, epoch: job.epoch });
          },
        },
      },
    });

    const Session = spec.defineActor({
      name: "Session",
      description: "The Pi agent in an Axo Session, calling connections_execute through axod mcp.",
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
          label: "Run a script",
          description: "The agent runs a connections script.",
          inputs: { script: spec.defineInput(String, { examples: Object.keys(CALLS) }) },
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
        [Done]: {
          description: "The script returned.",
          run(state, m, ctx) {
            if (state.pending?.request !== m.request) return;
            state.outcomes.push({ script: state.pending.script, outcome: `ok: ${m.results.join("; ")}` });
            state.pending = null;
            ctx.cancel("deadline");
          },
        },
        [Failed]: {
          description: "The script failed with an error the agent can read.",
          run(state, m, ctx) {
            if (state.pending?.request !== m.request) return;
            state.outcomes.push({ script: state.pending.script, outcome: `error: ${m.error}` });
            state.pending = null;
            ctx.cancel("deadline");
          },
        },
        [RelayDown]: {
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
      },
    });

    spec.defineProperties({
      bashOnlyOnOwnMacs: {
        description: "A Mac only runs commands for the account it is paired with.",
        always: (w) => w.all(Axod).every((a) => a.state.ran.every((r) => r.account === r.owner)),
      },
      grantsOnlyFromTheirAccount: {
        description: "Every third-party call uses the grant of the account whose script made it.",
        always: (w) => {
          const log = w.the(Manager).state.log;
          return w.the(Linear).state.calls.every((c) => { const rec = log.find((r) => r.call === c.call); return rec !== undefined && grantOf(rec.account) === c.token; });
        },
      },
      grantsStayInTheCloud: {
        description: "No Mac or Session ever holds a grant.",
        always: (w) => [...w.all(Axod), ...w.all(Session)].every((x) => !JSON.stringify(x.state).includes("grant:")),
      },
      noThirdPartyCallRunsTwice: {
        description: "A third-party tool call reaches the service at most once, even when its answer is lost.",
        always: (w) => { const calls = w.the(Linear).state.calls.map((c) => c.call); return new Set(calls).size === calls.length; },
      },
      onlinePairedMacsOnly: {
        description: "A Mac is offered as an online connection only while it is paired.",
        always: (w) => { const m = w.the(Manager).state; return Object.entries(m.online).every(([host, on]) => !on || Object.values(m.connections).some((cs) => host in cs)); },
      },
      scriptsStayWithinLimit: {
        description: "No script reaches a service or a Mac more often than its call limit allows.",
        always: (w) => { const per: Record<string, number> = {}; for (const r of w.the(Manager).state.log) per[r.request] = (per[r.request] ?? 0) + 1; return Object.values(per).every((n) => n <= MAX_CALLS); },
      },
      noCommandRunsTwice: {
        description: "A dispatched command runs at most once, even when the relay drops around it.",
        always: (w) => { const calls = w.all(Axod).flatMap((a) => a.state.ran.map((r) => r.call)); return new Set(calls).size === calls.length; },
      },
      everyCallIsLogged: {
        description: "Every command a Mac ran and every third-party call has a record in the call log.",
        always: (w) => {
          const logged = new Set(w.the(Manager).state.log.map((r) => r.call));
          return w.all(Axod).every((a) => a.state.ran.every((r) => logged.has(r.call))) && w.the(Linear).state.calls.every((c) => logged.has(c.call));
        },
      },
      sessionsGetAnAnswer: {
        description: "A Session waiting on a script always gets an answer: a result, an error, or its deadline.",
        leadsTo: { whenever: (w) => w.all(Session).some((s) => s.state.pending !== null), then: (w) => w.all(Session).every((s) => s.state.pending === null) },
      },
    });

    const aliceAndBob = (w: any) => {
      w.spawn(Axod, "Laptop daemon", { connected: true });
      w.spawn(Axod, "Studio daemon", { connected: true });
      w.spawn(Axod, "Workbench daemon", { connected: true });
      w.spawn(Session, "Laptop session");
    };

    spec.defineScenario({
      name: "Read Linear from a Session",
      description: "Alice's agent on her laptop lists Linear issues; the cloud calls Linear with Alice's grant.",
      setup: aliceAndBob,
      run(s) {
        s.act(s.world.all(Session)[0]!, "execute", { script: "linear" });
        s.settle();
      },
    });
    spec.defineScenario({
      name: "Run a command on another Mac",
      description: "Alice's agent on her laptop runs uptime on her Studio, through the cloud and the Studio's relay.",
      setup: aliceAndBob,
      run(s) {
        s.act(s.world.all(Session)[0]!, "execute", { script: "bash:studio" });
        s.settle();
      },
    });
    spec.defineScenario({
      name: "Linear, then a command, in one script",
      description: "One script reads Linear in the cloud and passes the result to a command on the Studio.",
      setup: aliceAndBob,
      run(s) {
        s.act(s.world.all(Session)[0]!, "execute", { script: "linear+bash:studio" });
        s.settle();
      },
    });
    spec.defineScenario({
      name: "Bob's Mac is not Alice's connection",
      description: "Alice's script names Bob's workbench; her account has no connection by that name, so nothing reaches Bob's Mac.",
      setup: aliceAndBob,
      run(s) {
        s.act(s.world.all(Session)[0]!, "execute", { script: "bash:workbench" });
        s.settle();
      },
    });
    spec.defineScenario({
      name: "The Studio drops mid-command",
      description: "The Studio's relay closes after the command was sent; the script fails with 'may have run' and the command is not sent again.",
      setup: aliceAndBob,
      run(s) {
        const studio = s.world.all(Axod).find((a) => a.label === "Studio daemon")!;
        s.act(s.world.all(Session)[0]!, "execute", { script: "bash:studio" });
        s.settle({ until: (w) => Object.keys(w.the(Manager).state.dispatched).length > 0 });
        s.act(studio, "dropRelay");
        s.settle();
      },
    });
    spec.defineScenario({
      name: "A script that makes too many calls",
      description: "The third call is refused against the script's limit, so the script fails; the first two ran.",
      setup: aliceAndBob,
      run(s) {
        s.act(s.world.all(Session)[0]!, "execute", { script: "bash:studio x3" });
        s.settle();
      },
    });
    spec.defineScenario({
      name: "The Studio is unpaired mid-command",
      description: "Alice unpairs her Studio while a command runs there; the script fails at once, the Studio's late output is dropped, and the Studio is no longer a connection.",
      setup: aliceAndBob,
      run(s) {
        s.act(s.world.all(Session)[0]!, "execute", { script: "bash:studio" });
        s.settle({ until: (w) => w.all(Axod).some((a) => Object.keys(a.state.jobs).length > 0) });
        s.act(s.the(Manager), "unpair", { host: "studio" });
        s.settle();
      },
    });
    spec.defineScenario({
      name: "A script runs out of time",
      description: "The script's wall time passes while a command runs; the Durable Object aborts it and tells the laptop, and the command's late output is ignored.",
      setup: aliceAndBob,
      run(s) {
        s.act(s.world.all(Session)[0]!, "execute", { script: "bash:studio" });
        s.settle({ until: (w) => w.all(Axod).some((a) => Object.keys(a.state.jobs).length > 0) });
        s.fire(s.the(Manager), "wallTime");
        s.settle();
      },
    });
    spec.defineScenario({
      name: "The laptop's relay is down",
      description: "With its relay down, the laptop refuses the script at once instead of waiting.",
      setup: aliceAndBob,
      run(s) {
        s.act(s.world.all(Axod).find((a) => a.label === "Laptop daemon")!, "dropRelay");
        s.settle();
        s.act(s.world.all(Session)[0]!, "execute", { script: "linear" });
        s.settle();
      },
    });

    spec.defineGroup({ name: "Mac", actors: { daemon: Axod, session: Session }, icon: "laptop", names: ["Laptop", "Studio", "Workbench"] });
    spec.defineGroup({ name: "Axo cloud", actors: [Manager, Worker], icon: "cloud", collapsed: false });

    return { Manager, Worker, Linear, Axod, Session };
  },
);
