import { atMost, budget, defineActor, defineCall, defineGroup, defineLimit, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineVariable, defineZone, failed, FAULT, lose, nullable, oneOf, spend } from "@leostera/feynman";

// RFD0019: a planned restart of axod (an upgrade, or "Restart axod") looks planned to clients.
//
// Today Axo.app 250 finds axod 249 running and has launchd restart it. axod stops its relay
// worker and the socket closes with nothing said, so the HostDO handles it like a crash: in-flight
// prompts fail as "outcome unknown", and every client hears the Mac is offline. This spec models
// the proposal: the app tells axod why it is about to be restarted, axod says goodbye on the
// socket, the HostDO shows the host as restarting (with the build it is moving to) until it is
// back or a grace period runs out, and a newer generation's registration fences an older one's
// late goodbye.
//
// One Mac and one browser tab. Sessions, transcripts and progress are RFD0018's and left out:
// they survive a restart in the cloud. Most steps are not built yet, so they have no sources.

/** Faults on one path: lost messages, an axod crash, a new axod that fails to start. */
const faults = budget("faults", 1);

/** Ghost history for properties: goodbyes the network lost, and why each generation was stopped. */
const lostGoodbyes = defineVariable("lostGoodbyes", 0);
const stops = defineVariable("stops", {} as Record<string, Reason>);

type Reason = "upgrade" | "restart" | "stop";
type Status = "online" | "restarting" | "offline";
type End = "planned" | "stopped" | "dropped" | "graceExpired";
type Shown = { status: Status; generation: number; build: number; reason: Reason | null; toBuild: number | null; seq: number };

const OLD_BUILD = 249;
const NEW_BUILD = 250;

const label = (s: Shown | null): string => {
  if (!s) return "no Mac yet";
  if (s.status === "online") return `Studio · build ${s.build}`;
  if (s.status === "restarting") return s.reason === "upgrade" ? `Studio is upgrading to build ${s.toBuild}…` : "Studio is restarting…";
  return s.reason === "stop" ? "Studio was shut down" : "Studio is offline";
};

// ─── Messages ───────────────────────────────────────────────────────────────────

// Axo.app <-> axod (unix socket)
const PrepareRestart = defineCall("PrepareRestart", { reason: oneOf("upgrade", "restart"), toBuild: Number }, { name: "axo.daemon.prepareRestart", over: "unix socket" });
const RestartPrepared = defineMessage("RestartPrepared", {}, { name: "restart prepared", over: "unix socket", tone: "reply" });
const Ready = defineMessage("Ready", { build: Number }, { name: "axo.daemon.health", over: "unix socket" });
// Axo.app / logout <-> launchd <-> axod (process lifecycle; signals are not lost)
const Kickstart = defineMessage("Kickstart", { build: Number }, { name: "launchctl kickstart -k", over: "launchd" });
const Terminate = defineMessage("Terminate", {}, { name: "SIGTERM", over: "signal" });
const Exited = defineMessage("Exited", {}, { name: "process exited", over: "launchd" });
const Launch = defineMessage("Launch", { build: Number }, { name: "start axod", over: "launchd" });
// axod <-> HostDO (the host's WebSocket)
const Register = defineMessage("Register", { generation: Number, build: Number }, { name: "axo.host.register", over: "websocket" });
const Registered = defineMessage("Registered", { generation: Number }, { name: "register result", over: "websocket", tone: "reply" });
const Goodbye = defineMessage("Goodbye", { generation: Number, reason: oneOf("upgrade", "restart", "stop"), toBuild: nullable(Number) }, { name: "axo.host.leaving, then close 1012", over: "websocket" });
const Dropped = defineMessage("Dropped", { generation: Number }, { name: "socket closed without a goodbye", over: "websocket", tone: "refused" });
const Run = defineMessage("Run", { generation: Number }, { name: "axo.remote.session.prompt", over: "websocket" });
const Ran = defineMessage("Ran", { generation: Number }, { name: "prompt accepted by Pi", over: "websocket", tone: "reply" });
// HostDO <-> ClientDO (RPC), ClientDO <-> tab (WebSocket)
const presenceSchema = { status: oneOf("online", "restarting", "offline"), generation: Number, build: Number, reason: nullable(oneOf("upgrade", "restart", "stop")), toBuild: nullable(Number), seq: Number };
// RFD0031: a presence notice is a call, so a lost one fails and the HostDO sends it again at once;
// the ClientDO subscribes once, on hello, and nothing renews.
const Presence = defineCall("Presence", presenceSchema, { name: "presence notice (ClientDO.notify)", over: "rpc" });
const Subscribe = defineCall("Subscribe", {}, { name: "HostDO.subscribe", over: "rpc" });
const Subscribed = defineMessage("Subscribed", presenceSchema, { name: "subscription with presence", over: "rpc", tone: "reply" });
const Hosts = defineMessage("Hosts", presenceSchema, { name: "axo.client.hosts", over: "websocket" });
const Hello = defineMessage("Hello", {}, { name: "axo.client.hello", over: "websocket" });
const Command = defineMessage("Command", {}, { name: "axo.client.command (prompt)", over: "websocket" });
const Forward = defineMessage("Forward", {}, { name: "HostDO.command", over: "rpc" });
const Accepted = defineMessage("Accepted", {}, { name: "prompt accepted", tone: "reply" });
const Offline = defineMessage("Offline", {}, { name: "Studio is offline", tone: "refused" });
const Restarting = defineMessage("Restarting", { toBuild: nullable(Number) }, { name: "Studio is restarting; try again in a moment", tone: "refused" });
const Interrupted = defineMessage("Interrupted", { toBuild: nullable(Number) }, { name: "interrupted by a planned restart; check the transcript", tone: "refused" });
const MayHaveRun = defineMessage("MayHaveRun", {}, { name: "outcome unknown; check the transcript", tone: "refused" });

// ─── Zones, limits, rules ───────────────────────────────────────────────────────

const browsers = defineZone({ name: "Browsers", description: "the web app", place: { column: 0 } });
const cloudflare = defineZone({ name: "Cloudflare", description: "RFD0018's Durable Objects", place: { column: 1, region: true } });
const mac = defineZone({ name: "Studio", description: "Axo.app, launchd and axod", place: { column: 2 } });

const RESTART_GRACE = defineLimit({ name: "A restarting host is shown as restarting for at most", value: 60, unit: "seconds" });

const announceRestart = defineRule("announceRestart", {
  description: "Axo.app tells axod why it is about to restart it, and axod says goodbye on the socket before closing it.",
});
const graceFallback = defineRule("graceFallback", {
  description: "A host that does not come back within the grace period is shown offline.",
});
const noticesInOrder = defineRule("noticesInOrder", {
  description: "Presence notices carry a sequence number, and a ClientDO ignores one older than what it holds.",
});

// ─── Actors ─────────────────────────────────────────────────────────────────────

export const App = defineActor({
  name: "Axo.app",
  description: "The Mac app. When its build differs from axod's, it has launchd restart axod (DaemonController).",
  zone: mac,
  singleton: true,
  initialState: () => ({ build: OLD_BUILD, daemonBuild: OLD_BUILD, restarting: false }),
  display: {
    icon: "laptop",
    status: (s) => (s.restarting ? `restarting axod to build ${s.build}` : `build ${s.build}, axod ${s.daemonBuild}`),
    mood: (s) => (s.restarting ? "busy" : s.build === s.daemonBuild ? "ok" : "warn"),
  },
  actions: {
    installUpgrade: {
      with: [atMost(1)],
      label: "Install build 250",
      description: "A new Axo.app is installed and launched.",
      when: (s) => s.build === OLD_BUILD,
      run: (s) => void (s.build = NEW_BUILD),
    },
    restartDaemon: {
      with: [atMost(1)],
      label: "Restart axod",
      description: "The person asks Axo.app to restart axod.",
      sources: ["apple/AxoDaemonManager/Sources/AxoDaemonManager/DaemonController.swift#DaemonController.restartDaemon"],
      when: (s) => !s.restarting,
      sends: [PrepareRestart],
      run(s, _i, ctx) {
        s.restarting = true;
        ctx.send(ctx.the(Axod), PrepareRestart, { reason: "restart", toBuild: s.build });
      },
    },
  },
  transitions: {
    upgradeDaemon: {
      when: (s) => s.build !== s.daemonBuild && !s.restarting,
      description: "axod runs another build: tell it an upgrade restart is coming.",
      sources: ["apple/AxoDaemonManager/Sources/AxoDaemonManager/DaemonController.swift#DaemonController.checkBuildAndRestartIfNeeded"],
      sends: [PrepareRestart],
      say: (s) => `Restarting axod to build ${s.build}`,
      run(s, _, ctx) {
        s.restarting = true;
        ctx.send(ctx.the(Axod), PrepareRestart, { reason: "upgrade", toBuild: s.build });
      },
    },
    restartPrepared: {
      on: RestartPrepared,
      description: "axod knows why; have launchd restart it.",
      sources: ["apple/AxoDaemonManager/Sources/AxoDaemonManager/DaemonController.swift#DaemonController.kickstart"],
      sends: [Kickstart],
      run: (s, _m, ctx) => ctx.send(ctx.the(Launchd), Kickstart, { build: s.build }),
    },
    prepareRestartFailed: {
      on: failed(PrepareRestart),
      description: "axod did not answer; restart it anyway, unannounced.",
      sends: [Kickstart],
      run: (s, _f, ctx) => ctx.send(ctx.the(Launchd), Kickstart, { build: s.build }),
    },
    ready: {
      on: Ready,
      description: "axod is up; note its build.",
      sources: ["apple/AxoDaemonManager/Sources/AxoDaemonManager/DaemonController.swift#DaemonController.waitForDaemon"],
      run(s, m) {
        s.daemonBuild = m.build;
        s.restarting = false;
      },
    },
    restartPreparedLost: lose(RestartPrepared, { fails: PrepareRestart, spend: faults }),
  },
});

export const Launchd = defineActor({
  name: "launchd",
  description: "Runs axod as a LaunchAgent: kickstart stops it and starts it again; it restarts it after a crash; logout stops it for good.",
  zone: mac,
  singleton: true,
  initialState: () => ({ build: OLD_BUILD, keepAlive: true }),
  display: { icon: "gear", status: (s) => (s.keepAlive ? `keeps axod ${s.build} alive` : "logged out") },
  actions: {
    logout: {
      with: [atMost(1)],
      label: "Log out",
      description: "The person logs out: launchd stops axod and does not start it again.",
      sends: [Terminate],
      run(s, _i, ctx) {
        s.keepAlive = false;
        ctx.send(ctx.the(Axod), Terminate, {});
      },
    },
  },
  transitions: {
    kickstart: {
      on: Kickstart,
      description: "Stops axod; it starts again from the installed bundle once it exits.",
      sends: [Terminate],
      run(s, m, ctx) {
        s.build = m.build;
        ctx.send(ctx.the(Axod), Terminate, {});
      },
    },
    exited: {
      on: Exited,
      description: "axod exited: start it again, unless the person logged out.",
      sends: [Launch],
      run: (s, _m, ctx) => void (s.keepAlive && ctx.send(ctx.the(Axod), Launch, { build: s.build })),
    },
    launchFails: {
      on: Exited,
      fair: false,
      tags: [FAULT],
      with: [spend(faults)],
      description: "The new axod fails to start.",
      run: () => {},
    },
  },
});

export const Axod = defineActor({
  name: "axod",
  description: "The daemon: holds the host's socket to its HostDO and runs Pi. Each start is a new host generation.",
  zone: mac,
  singleton: true,
  initialState: () => ({
    build: OLD_BUILD,
    generation: 1,
    phase: "starting" as "starting" | "registering" | "running" | "down",
    notice: null as null | { reason: "upgrade" | "restart"; toBuild: number },
  }),
  display: {
    icon: "server",
    status: (s) => (s.phase === "down" ? "stopped" : `${s.phase} · build ${s.build} · generation ${s.generation}`),
    mood: (s) => (s.phase === "running" ? "ok" : s.phase === "down" ? "off" : "busy"),
  },
  links: (s) => (s.phase === "running" || s.phase === "registering" ? [{ to: "HostDO", kind: "websocket", style: s.phase === "running" ? "solid" : "dotted" }] : []),
  transitions: {
    connect: {
      when: (s) => s.phase === "starting",
      description: "Opens the host socket and registers this generation.",
      sources: ["crates/axo-relay/src/relay.rs#run_connection"],
      sends: [Register],
      starts: ["registerTimeout"],
      run(s, _, ctx) {
        s.phase = "registering";
        ctx.send(ctx.the(HostDO), Register, { generation: s.generation, build: s.build });
        ctx.start("registerTimeout");
      },
    },
    registered: {
      on: Registered,
      description: "The host is online.",
      run(s, m, ctx) {
        if (s.phase !== "registering" || m.generation !== s.generation) return;
        s.phase = "running";
        ctx.cancel("registerTimeout");
      },
    },
    registerTimeout: {
      after: "10 seconds",
      description: "No answer to the registration: connect again.",
      sources: ["crates/axo-relay/src/relay.rs#run_reconnect_loop"],
      run: (s) => void (s.phase === "registering" && (s.phase = "starting")),
    },
    prepareRestart: {
      on: PrepareRestart,
      description: "Remembers why it is about to be restarted.",
      sends: [RestartPrepared],
      run(s, m, ctx) {
        if (announceRestart.on) s.notice = { reason: m.reason, toBuild: m.toBuild };
        ctx.reply(RestartPrepared, {});
      },
    },
    terminate: {
      on: Terminate,
      uses: [stops],
      description: "SIGTERM: says goodbye on the socket with the reason it was given (or \"stop\"), stops Pi and its shells, and exits.",
      sources: ["crates/axo-server/src/lib.rs#stop_on_signal", "crates/axo-relay/src/relay.rs#RelayWorker::shutdown"],
      sends: [Goodbye, Dropped, Exited],
      say: (s) => `Stopping generation ${s.generation}`,
      run(s, _m, ctx) {
        if (s.phase === "down") return;
        const reason: Reason = s.notice?.reason ?? "stop";
        ctx.set(stops, { ...ctx.get(stops), [s.generation]: reason });
        if (s.phase === "running" || s.phase === "registering") {
          if (announceRestart.on) ctx.send(ctx.the(HostDO), Goodbye, { generation: s.generation, reason, toBuild: s.notice?.toBuild ?? null });
          else ctx.send(ctx.the(HostDO), Dropped, { generation: s.generation });
        }
        s.phase = "down";
        s.notice = null;
        ctx.cancel("registerTimeout");
        ctx.send(ctx.the(Launchd), Exited, {});
      },
    },
    launch: {
      on: Launch,
      description: "A new axod starts: a new generation, from the installed build. It restores its Sessions and tells Axo.app it is up.",
      sources: ["crates/axo-server/src/session/lifecycle.rs#SessionManager::restore_open_sessions"],
      sends: [Ready],
      say: (s) => `axod ${s.build} started (generation ${s.generation})`,
      run(s, m, ctx) {
        if (s.phase !== "down") return;
        s.build = m.build;
        s.generation += 1;
        s.phase = "starting";
        ctx.send(ctx.the(App), Ready, { build: m.build });
      },
    },
    run: {
      on: Run,
      description: "Hands the prompt to Pi and acknowledges it.",
      sends: [Ran],
      run: (s, m, ctx) => void (s.phase === "running" && m.generation === s.generation && ctx.reply(Ran, { generation: s.generation })),
    },
    crash: {
      when: (s) => s.phase === "running" || s.phase === "registering",
      fair: false,
      tags: [FAULT],
      with: [spend(faults)],
      description: "axod crashes: its socket is reset, and launchd starts it again.",
      sends: [Dropped, Exited],
      run(s, _, ctx) {
        ctx.send(ctx.the(HostDO), Dropped, { generation: s.generation });
        s.phase = "down";
        s.notice = null;
        ctx.cancel("registerTimeout");
        ctx.send(ctx.the(Launchd), Exited, {});
      },
    },
    prepareRestartLost: lose(PrepareRestart, { spend: faults }),
    registeredLost: lose(Registered, { spend: faults }),
    runLost: lose(Run, { spend: faults }),
  },
});

export const HostDO = defineActor({
  name: "HostDO",
  description: "One per host (RFD0018): owns the host's socket and presence, and forwards prompts to axod.",
  zone: cloudflare,
  singleton: true,
  initialState: () => ({
    status: "offline" as Status,
    generation: 0,
    build: OLD_BUILD,
    reason: null as Reason | null,
    toBuild: null as number | null,
    seq: 0,
    /** How each generation's socket ended, as the HostDO saw it. */
    ends: {} as Record<string, End>,
    /** A prompt sent to axod and not yet acknowledged. */
    pending: false,
  }),
  display: {
    icon: "cloud",
    status: (s) => label(s.generation ? { ...s } : null),
    mood: (s) => (s.status === "online" ? "ok" : s.status === "restarting" ? "busy" : "off"),
    rows: (s) => Object.entries(s.ends).map(([g, end]) => ({ group: "generations", label: `generation ${g}`, detail: end, mood: end === "planned" || end === "stopped" ? ("info" as const) : ("warn" as const) })),
  },
  transitions: {
    register: {
      on: Register,
      description: "A generation registers: the host is online. An older generation than the current one is ignored.",
      sources: ["packages/axo-api-worker/src/axo-host-relay.ts#AxoHostRelay.registerHost", "packages/axo-api-worker/src/host-do.ts#AxoHostDO.presenceChanged"],
      sends: [Registered, Presence],
      say: (_s, m) => `Generation ${m.generation} is online on build ${m.build}`,
      run(s, m, ctx) {
        if (m.generation < s.generation) return;
        const changed = s.status !== "online" || s.generation !== m.generation;
        s.status = "online";
        s.generation = m.generation;
        s.build = m.build;
        s.reason = null;
        s.toBuild = null;
        ctx.cancel("grace");
        ctx.reply(Registered, { generation: m.generation });
        if (changed) announce(s, ctx);
      },
    },
    goodbye: {
      on: Goodbye,
      description: "The host says it is going away and why. A restart shows as restarting until it is back; a stop shows offline. A prompt in flight is reported interrupted.",
      sends: [Presence, Interrupted],
      starts: ["grace"],
      say: (_s, m) => (m.reason === "stop" ? `Generation ${m.generation} stopped` : `Generation ${m.generation} is restarting (${m.reason}${m.toBuild ? ` to ${m.toBuild}` : ""})`),
      run(s, m, ctx) {
        if (m.generation !== s.generation || s.status !== "online") return;
        s.reason = m.reason;
        s.toBuild = m.toBuild;
        if (m.reason === "stop") {
          s.status = "offline";
          s.ends[m.generation] = "stopped";
        } else {
          s.status = "restarting";
          s.ends[m.generation] = "planned";
          if (graceFallback.on) ctx.start("grace");
        }
        if (s.pending) {
          s.pending = false;
          ctx.send(ctx.the(ClientDO), Interrupted, { toBuild: m.toBuild });
        }
        announce(s, ctx);
      },
    },
    dropped: {
      on: Dropped,
      description: "The socket closed without a goodbye: the host is offline, and a prompt in flight may have run.",
      sources: ["packages/axo-api-worker/src/axo-host-relay.ts#AxoHostRelay.webSocketClose", "packages/axo-api-worker/src/axo-host-relay.ts#AxoHostRelay.fence"],
      sends: [Presence, MayHaveRun],
      run(s, m, ctx) {
        if (m.generation !== s.generation || s.status !== "online") return;
        s.status = "offline";
        s.reason = null;
        s.toBuild = null;
        s.ends[m.generation] = "dropped";
        if (s.pending) {
          s.pending = false;
          ctx.send(ctx.the(ClientDO), MayHaveRun, {});
        }
        announce(s, ctx);
      },
    },
    grace: {
      after: "60 seconds",
      description: "The host did not come back in time: it is offline.",
      sends: [Presence],
      run(s, _, ctx) {
        if (s.status !== "restarting") return;
        s.status = "offline";
        s.ends[s.generation] = "graceExpired";
        announce(s, ctx);
      },
    },
    forward: {
      on: Forward,
      description: "Forwards a prompt to axod while online; otherwise says why it cannot.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.command"],
      sends: [Run, Offline, Restarting],
      run(s, _m, ctx) {
        if (s.status === "restarting") return ctx.send(ctx.the(ClientDO), Restarting, { toBuild: s.toBuild });
        if (s.status !== "online" || s.pending) return ctx.send(ctx.the(ClientDO), Offline, {});
        s.pending = true;
        ctx.send(ctx.the(Axod), Run, { generation: s.generation });
      },
    },
    ran: {
      on: Ran,
      description: "axod accepted the prompt.",
      sends: [Accepted],
      run(s, m, ctx) {
        if (!s.pending || m.generation !== s.generation) return;
        s.pending = false;
        ctx.send(ctx.the(ClientDO), Accepted, {});
      },
    },
    subscribe: {
      on: Subscribe,
      description: "A ClientDO subscribes, once per socket; the answer carries the current presence.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.subscribe"],
      sends: [Subscribed],
      run: (s, _m, ctx) => ctx.reply(Subscribed, presenceOf(s)),
    },
    // Faults: the network may lose what reaches the HostDO. A lost goodbye closes the socket
    // without one, as a crash does.
    goodbyeLost: {
      on: Goodbye,
      fair: false,
      tags: [FAULT],
      with: [spend(faults)],
      uses: [lostGoodbyes],
      description: "The goodbye is lost on the way; the HostDO only sees the socket close.",
      sends: [Dropped],
      run(_s, m, ctx) {
        ctx.set(lostGoodbyes, ctx.get(lostGoodbyes) + 1);
        ctx.forward({ message: Dropped, payload: { generation: m.generation } });
      },
    },
    registerLost: lose(Register, { spend: faults }),
    forwardLost: lose(Forward, { spend: faults }),
    ranLost: lose(Ran, { spend: faults }),
    subscribeLost: lose(Subscribe, { spend: faults }),
    presenceFailed: {
      on: failed(Presence),
      description: "The notice failed: the HostDO sends what it knows now, at once (RFD0031).",
      sends: [Presence],
      run: (s, _f, ctx) => ctx.send(ctx.the(ClientDO), Presence, presenceOf(s)),
    },
  },
});

function presenceOf(s: { status: Status; generation: number; build: number; reason: Reason | null; toBuild: number | null; seq: number }): Shown {
  return { status: s.status, generation: s.generation, build: s.build, reason: s.reason, toBuild: s.toBuild, seq: s.seq };
}

/** Tells the ClientDO the new presence, numbered so a late notice cannot undo a newer one. */
function announce(s: { status: Status; generation: number; build: number; reason: Reason | null; toBuild: number | null; seq: number }, ctx: { send: (to: any, m: typeof Presence, p: Shown) => void; the: (a: typeof ClientDO) => any }): void {
  s.seq += 1;
  ctx.send(ctx.the(ClientDO), Presence, presenceOf(s));
}

export const ClientDO = defineActor({
  name: "ClientDO",
  description: "One per tab (RFD0018): follows the account's hosts, keeps their presence, and relays prompts.",
  zone: cloudflare,
  singleton: true,
  initialState: () => ({ open: false, host: null as Shown | null }),
  display: {
    icon: "queue",
    status: (s) => (s.open ? label(s.host) : "no tab"),
    mood: (s) => (s.host?.status === "online" ? "ok" : s.host?.status === "restarting" ? "busy" : "off"),
  },
  transitions: {
    hello: {
      on: Hello,
      description: "A tab connects: subscribe to the host.",
      sources: ["packages/axo-api-worker/src/client-do.ts#AxoClientDO.webSocketMessage"],
      sends: [Subscribe],
      run(s, _m, ctx) {
        s.open = true;
        ctx.send(ctx.the(HostDO), Subscribe, {});
      },
    },
    presence: {
      on: Presence,
      description: "A presence notice: keep it, unless it is older than what is held, and tell the tab.",
      sources: ["packages/axo-api-worker/src/client-do.ts#AxoClientDO.notify"],
      sends: [Hosts],
      run: (s, m, ctx) => take(s, m, ctx),
    },
    subscribed: {
      on: Subscribed,
      description: "Subscribed: the current presence.",
      sends: [Hosts],
      run: (s, m, ctx) => take(s, m, ctx),
    },
    subscribeFailed: {
      on: failed(Subscribe),
      description: "The subscription failed: it is made again at once (RFD0031).",
      sends: [Subscribe],
      run: (_s, _f, ctx) => ctx.send(ctx.the(HostDO), Subscribe, {}),
    },
    command: { on: Command, description: "Forwards a prompt to the host.", sends: [Forward], run: (_s, _m, ctx) => ctx.send(ctx.the(HostDO), Forward, {}) },
    accepted: { on: Accepted, description: "Tells the tab.", sends: [Accepted], run: (_s, _m, ctx) => ctx.send(ctx.the(Tab), Accepted, {}) },
    offline: { on: Offline, description: "Tells the tab.", sends: [Offline], run: (_s, _m, ctx) => ctx.send(ctx.the(Tab), Offline, {}) },
    restarting: { on: Restarting, description: "Tells the tab.", sends: [Restarting], run: (_s, m, ctx) => ctx.send(ctx.the(Tab), Restarting, m) },
    interrupted: { on: Interrupted, description: "Tells the tab.", sends: [Interrupted], run: (_s, m, ctx) => ctx.send(ctx.the(Tab), Interrupted, m) },
    mayHaveRun: { on: MayHaveRun, description: "Tells the tab.", sends: [MayHaveRun], run: (_s, _m, ctx) => ctx.send(ctx.the(Tab), MayHaveRun, {}) },
    presenceLost: lose(Presence, { spend: faults }),
    subscribedLost: lose(Subscribed, { fails: Subscribe, spend: faults }),
    commandLost: lose(Command, { spend: faults }),
    acceptedLost: lose(Accepted, { spend: faults }),
    offlineLost: lose(Offline, { spend: faults }),
    restartingLost: lose(Restarting, { spend: faults }),
    interruptedLost: lose(Interrupted, { spend: faults }),
    mayHaveRunLost: lose(MayHaveRun, { spend: faults }),
  },
});

function take(s: { open: boolean; host: Shown | null }, m: Shown, ctx: { send: (to: any, msg: typeof Hosts, p: Shown) => void; the: (a: typeof Tab) => any }): void {
  if (noticesInOrder.on && s.host && m.seq < s.host.seq) return;
  s.host = { ...m };
  if (s.open) ctx.send(ctx.the(Tab), Hosts, { ...m });
}

export const Tab = defineActor({
  name: "Web app",
  description: "A browser tab on the chat: shows the Mac's presence and sends prompts.",
  zone: browsers,
  singleton: true,
  initialState: () => ({
    open: false,
    shown: null as Shown | null,
    prompt: "idle" as "idle" | "sending" | "accepted" | "offline" | "restarting" | "interrupted" | "unknown" | "timedOut",
  }),
  display: {
    icon: "browser",
    status: (s) => (s.open ? label(s.shown) : "closed"),
    mood: (s) => (s.shown?.status === "online" ? "ok" : s.shown?.status === "restarting" ? "info" : "off"),
    rows: (s) => (s.prompt === "idle" ? [] : [{ label: "last prompt", detail: s.prompt, mood: s.prompt === "accepted" ? ("ok" as const) : s.prompt === "unknown" ? ("bad" as const) : ("info" as const) }]),
  },
  actions: {
    open: {
      with: [atMost(1)],
      label: "Open the web app",
      description: "Connects the tab to its ClientDO.",
      when: (s) => !s.open,
      sends: [Hello],
      run(s, _i, ctx) {
        s.open = true;
        ctx.send(ctx.the(ClientDO), Hello, {});
      },
    },
    prompt: {
      with: [atMost(2)],
      label: "Send a prompt",
      description: "Sends a prompt to the agent on Studio.",
      when: (s) => s.open && s.prompt !== "sending",
      sends: [Command],
      starts: ["commandTimeout"],
      run(s, _i, ctx) {
        s.prompt = "sending";
        ctx.send(ctx.the(ClientDO), Command, {});
        ctx.start("commandTimeout");
      },
    },
  },
  transitions: {
    hosts: {
      on: Hosts,
      description: "Shows the Mac's presence: online with its build, a banner while it restarts, or offline.",
      sources: ["packages/axo-web-app/src/chat/workbench.ts#ChatWorkbench.listHosts"],
      say: (s) => label(s.shown),
      run(s, m) {
        // The tab keeps the newest notice too: the ClientDO's subscription replies and notices come
        // from different calls to it, so one may overtake the other on the way here.
        if (noticesInOrder.on && s.shown && m.seq < s.shown.seq) return;
        s.shown = { ...m };
      },
    },
    accepted: { on: Accepted, description: "The prompt reached the agent.", run: (s, _m, ctx) => answer(s, "accepted", ctx) },
    offline: { on: Offline, description: "The Mac is offline: the text stays in the box.", run: (s, _m, ctx) => answer(s, "offline", ctx) },
    restarting: { on: Restarting, description: "The Mac is restarting: the text stays in the box, to send once it is back.", run: (s, _m, ctx) => answer(s, "restarting", ctx) },
    interrupted: { on: Interrupted, description: "A planned restart interrupted the prompt; the transcript will say whether it ran.", run: (s, _m, ctx) => answer(s, "interrupted", ctx) },
    mayHaveRun: { on: MayHaveRun, description: "The connection to the Mac dropped; the transcript will say whether it ran.", run: (s, _m, ctx) => answer(s, "unknown", ctx) },
    commandTimeout: {
      after: "15 seconds",
      description: "No answer in time: the tab says it does not know yet, and the transcript will tell.",
      run: (s) => void (s.prompt === "sending" && (s.prompt = "timedOut")),
    },
    // A frame lost on the tab's socket is the socket dropping (RFD0031): the web app connects again
    // and says hello, and the answer carries the current presence.
    hostsLost: {
      on: Hosts,
      fair: false,
      tags: [FAULT],
      with: [spend(faults)],
      description: "Axo.client.hosts is lost: the socket drops, and the web app connects again.",
      sends: [Hello],
      run(s, _m, ctx) {
        if (s.prompt === "sending") s.prompt = "unknown";
        ctx.cancel("commandTimeout");
        ctx.send(ctx.the(ClientDO), Hello, {});
      },
    },
  },
});

function answer(s: { prompt: string }, outcome: "accepted" | "offline" | "restarting" | "interrupted" | "unknown", ctx: { cancel: (t: string) => void }): void {
  if (s.prompt !== "sending") return;
  s.prompt = outcome;
  ctx.cancel("commandTimeout");
}

// ─── Properties ─────────────────────────────────────────────────────────────────

const plannedStopsLookPlanned = defineProperty("plannedStopsLookPlanned", {
  description: "Unless the network lost the goodbye, every generation axod stopped on purpose ends as planned or stopped in the cloud, never as a dropped socket.",
  always: (w) => {
    if (w.get(lostGoodbyes) > 0) return true;
    const ends = w.the(HostDO).state.ends;
    return Object.keys(w.get(stops)).every((g) => ends[g] !== "dropped");
  },
  needs: [announceRestart],
});

const restartIsNeverShownOffline = defineProperty("restartIsNeverShownOffline", {
  description: "The tab never shows a host offline for a generation that is restarting as planned, unless the grace period ran out.",
  always: (w) => {
    const shown = w.the(Tab).state.shown;
    return !shown || shown.status !== "offline" || w.the(HostDO).state.ends[shown.generation] !== "planned";
  },
});

const promptsDuringARestartSayWhy = defineProperty("promptsDuringARestartSayWhy", {
  description: "A prompt only ends with \"outcome unknown\" (the socket dropped while it was in flight) after a fault: a crash or a lost goodbye. A planned restart says it was interrupted.",
  always: (w) => w.the(Tab).state.prompt !== "unknown" || w.get(faults) < faults.initial,
  needs: [announceRestart],
});

const presenceNeverGoesBack = defineProperty("presenceNeverGoesBack", {
  description: "The tab never goes back to an older notice: what it shows only moves forward.",
  everyStep: (before, after) => {
    const a = before.the(Tab).state.shown;
    const b = after.the(Tab).state.shown;
    return !a || !b || b.seq >= a.seq;
  },
  needs: [noticesInOrder],
});

const restartsEnd = defineProperty("restartsEnd", {
  description: "A host shown as restarting ends up online again or, past the grace period, offline.",
  leadsTo: { whenever: (w) => w.the(HostDO).state.status === "restarting", then: (w) => w.the(HostDO).state.status !== "restarting" },
  needs: [graceFallback],
});

const tabCatchesUp = defineProperty("tabCatchesUp", {
  description: "An open tab ends up showing what the HostDO knows.",
  leadsTo: {
    whenever: (w) => w.the(Tab).state.open,
    then: (w) => {
      const shown = w.the(Tab).state.shown;
      const host = w.the(HostDO).state;
      return !!shown && shown.status === host.status && shown.generation === host.generation;
    },
  },
});

// ─── Scenarios ──────────────────────────────────────────────────────────────────

const connected = (s: Parameters<Parameters<typeof defineScenario>[1]["run"]>[0]) => {
  s.act(s.the(Tab), "open");
  s.settle({ until: (w) => w.the(Tab).state.shown?.status === "online" });
};

const anUpgrade = defineScenario("An upgrade", {
  description: "Build 250 is installed. Axo.app tells axod an upgrade restart is coming; the tab shows \"upgrading to build 250\" and then the Mac back on build 250. It never says offline.",
  run(s) {
    connected(s);
    s.act(s.the(App), "installUpgrade");
    s.settle({ until: (w) => w.the(Tab).state.shown?.status === "online" && w.the(Tab).state.shown?.build === NEW_BUILD });
  },
});

const aPromptDuringAnUpgrade = defineScenario("A prompt during an upgrade", {
  description: "A prompt is in flight when axod says goodbye: the tab says it was interrupted by the restart, and a prompt sent while restarting is told to wait.",
  run(s) {
    connected(s);
    s.act(s.the(Tab), "prompt");
    s.deliver(s.the(ClientDO), Command);
    s.deliver(s.the(HostDO), Forward);
    // The upgrade overtakes the prompt on its way to axod.
    s.act(s.the(App), "installUpgrade");
    s.step(s.the(App), "upgradeDaemon");
    s.deliver(s.the(Axod), PrepareRestart);
    s.deliver(s.the(App), RestartPrepared);
    s.deliver(s.the(Launchd), Kickstart);
    s.deliver(s.the(Axod), Terminate);
    s.deliver(s.the(HostDO), Goodbye);
    s.deliver(s.the(ClientDO), Interrupted);
    s.deliver(s.the(Tab), Interrupted);
    // Sent again while Studio restarts: told to wait, not failed.
    s.act(s.the(Tab), "prompt");
    s.deliver(s.the(ClientDO), Command);
    s.deliver(s.the(HostDO), Forward);
    s.deliver(s.the(ClientDO), Restarting);
    s.deliver(s.the(Tab), Restarting);
    s.settle({ until: (w) => w.the(Tab).state.shown?.status === "online" && w.the(Tab).state.shown?.build === NEW_BUILD });
  },
});

const aCrash = defineScenario("axod crashes", {
  description: "An unplanned stop: the socket drops with no goodbye, the tab says offline, and the Mac comes back.",
  run(s) {
    connected(s);
    s.step(s.the(Axod), "crash");
    s.settle({ until: (w) => w.the(Tab).state.shown?.status === "offline" });
    s.settle({ until: (w) => w.the(Tab).state.shown?.status === "online" && w.the(Tab).state.shown?.generation === 2 });
  },
});

const theNewAxodNeverStarts = defineScenario("The new axod never starts", {
  description: "The upgrade is announced but build 250 fails to start: the tab shows \"upgrading\" for the grace period, then offline.",
  run(s) {
    connected(s);
    s.act(s.the(App), "installUpgrade");
    s.settle({ until: (w) => w.the(HostDO).state.status === "restarting" });
    s.settle({ until: (w) => w.the(Axod).state.phase === "down" });
    s.step(s.the(Launchd), "launchFails");
    s.settle({ until: (w) => w.the(Tab).state.shown?.status === "offline" });
  },
});

const loggingOut = defineScenario("Logging out", {
  description: "launchd stops axod at logout without a restart notice: the tab says Studio was shut down, not that it dropped.",
  run(s) {
    connected(s);
    s.act(s.the(Launchd), "logout");
    s.settle({ until: (w) => w.the(Tab).state.shown?.status === "offline" });
  },
});

export default defineSpec({
  name: "Planned restarts",
  description:
    "How an upgrade or a requested restart of axod reaches clients as a planned restart, with the build it moves to, rather than as the Mac dropping offline.",
  actors: [Tab, ClientDO, HostDO, App, Launchd, Axod],
  groups: [
    defineGroup({ name: "Axo cloud", actors: [ClientDO, HostDO], icon: "cloud", collapsed: false }),
    defineGroup({ name: "Studio", actors: [App, Launchd, Axod], icon: "laptop", collapsed: false }),
  ],
  limits: [RESTART_GRACE],
  properties: [plannedStopsLookPlanned, restartIsNeverShownOffline, promptsDuringARestartSayWhy, presenceNeverGoesBack, restartsEnd, tabCatchesUp],
  scenarios: [anUpgrade, aPromptDuringAnUpgrade, aCrash, theNewAxodNeverStarts, loggingOut],
});
