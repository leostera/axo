import { atMost, defineActor, defineLimit, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineVariable, defineZone } from "@leostera/feynman";

// RFD0037: the host's lease and heartbeat, every minute instead of every ten seconds.
//
// axod renews its route on the HostDO with `axo.host.heartbeat`; a route whose lease runs out is
// fenced, and the Mac is shown offline. The lease only matters when a socket dies without the
// HostDO seeing it close: a Mac that loses power, or a laptop that sleeps and wakes on another
// network. Heartbeats every 60s need a lease of 150s (two missed heartbeats and a deadline).
//
// A longer lease made one thing worse: the HostDO refused a second socket from the same Mac with
// 409 while the first one's lease lasted. A Mac whose old socket died silently would have been
// refused for up to 150s when it reconnected. So the newest socket now replaces the old one, as
// clients' sockets do (RFD0032), and the lease is left to do only its job.

const RECONNECTS = 2;

/**
 * Ghost: whether the Mac's newest socket has gone silent (dead without a close, or the Mac gone).
 * The model has no clock, so it stands for the one fact about time that matters: a live Mac's
 * heartbeat every 60s always arrives within the 150s lease (pinned by a test on both constants).
 */
const silent = defineVariable("silent", true);

// ─── Messages ───────────────────────────────────────────────────────────────────

const Open = defineMessage("Open", { conn: Number }, { name: "connect /api/v1/host", over: "websocket" });
const Accepted = defineMessage("Accepted", { conn: Number }, { name: "101 Switching Protocols", over: "websocket", tone: "reply" });
const Refused = defineMessage("Refused", { conn: Number }, { name: "409 Duplicate machine connection", over: "websocket", tone: "refused" });
const Closed = defineMessage("Closed", { conn: Number }, { name: "close 4002 Lease ended", over: "websocket", tone: "refused" });

// ─── Zones, limits, rules ───────────────────────────────────────────────────────

const mac = defineZone({ name: "Studio", description: "axod", place: { column: 0 } });
const cloudflare = defineZone({ name: "Cloudflare", description: "the host's HostDO", place: { column: 1, region: true } });

const HEARTBEAT = defineLimit({ name: "axod renews its lease every", value: 60, unit: "seconds", sources: ["crates/axo-relay/src/relay.rs#HEARTBEAT_INTERVAL"] });
const LEASE = defineLimit({ name: "A route is kept without a heartbeat for", value: 150, unit: "seconds", sources: ["packages/axo-api/src/contracts.ts#LIMITS"] });

const newestWins = defineRule("newestWins", {
  description: "A socket from a Mac that already has a route replaces it: the old socket is fenced and closed, instead of the new one being refused while the old lease lasts.",
});
const leaseExpires = defineRule("leaseExpires", {
  description: "A route with no heartbeat for the lease's length is fenced, and the Mac shown offline.",
});

// ─── Actors ─────────────────────────────────────────────────────────────────────

export const Axod = defineActor({
  name: "axod",
  description: "The Mac's daemon: it keeps one socket to its HostDO, reconnecting when it breaks, and heartbeats on it.",
  zone: mac,
  singleton: true,
  initialState: () => ({ conn: 0, closed: 0, connected: false, connecting: true, gone: false, refusals: 0 }),
  display: {
    icon: "gear",
    status: (s) => (s.gone ? "powered off" : s.connected ? `connected (socket ${s.conn})` : "reconnecting"),
    mood: (s) => (s.gone ? "off" : s.connected ? "ok" : "busy"),
  },
  actions: {
    dropSilently: {
      with: [atMost(RECONNECTS)],
      label: "Wake on another network",
      description: "The socket dies without a close reaching the HostDO; axod notices and reconnects.",
      when: (s) => s.connected && !s.gone,
      uses: [silent],
      run(s, _i, ctx) {
        ctx.set(silent, true);
        s.connected = false;
        s.connecting = true;
      },
    },
    powerOff: {
      with: [atMost(1)],
      label: "Lose power",
      description: "The Mac goes away and says nothing.",
      when: (s) => !s.gone,
      uses: [silent],
      run(s, _i, ctx) {
        ctx.set(silent, true);
        s.gone = true;
        s.connected = false;
        s.connecting = false;
      },
    },
  },
  transitions: {
    connect: {
      when: (s) => s.connecting && !s.gone,
      description: "Opens a new socket.",
      sources: ["crates/axo-relay/src/relay.rs#run_connection"],
      sends: [Open],
      uses: [silent],
      run(s, _m, ctx) {
        // A live Mac registers within the deadline, then heartbeats: its socket is not silent.
        ctx.set(silent, false);
        s.connecting = false;
        s.conn += 1;
        ctx.send(ctx.the(HostDO), Open, { conn: s.conn });
      },
    },
    accepted: {
      on: Accepted,
      description: "The socket is up; from now on axod heartbeats on it every minute (see `silent`).",
      uses: [silent],
      run(s, m, ctx) {
        // A socket the HostDO already closed stays closed.
        if (s.gone || m.conn !== s.conn || m.conn <= s.closed) return;
        ctx.set(silent, false);
        s.connected = true;
      },
    },
    refused: {
      on: Refused,
      description: "The HostDO still routes to the old socket: try again after a backoff.",
      run(s, m) {
        if (s.gone || m.conn !== s.conn) return;
        s.refusals += 1;
        s.connecting = true;
      },
    },
    closed: {
      on: Closed,
      description: "The HostDO closed this socket (its lease ended, or a newer one replaced it): reconnect.",
      sources: ["crates/axo-relay/src/relay.rs#run_reconnect_loop"],
      uses: [silent],
      run(s, m, ctx) {
        if (s.gone || m.conn !== s.conn || m.conn <= s.closed) return;
        s.closed = m.conn;
        ctx.set(silent, true);
        s.connected = false;
        s.connecting = true;
      },
    },
  },
});

export const HostDO = defineActor({
  name: "HostDO",
  description: "The Mac's Durable Object: one route, to one socket, held by a lease.",
  zone: cloudflare,
  singleton: true,
  initialState: () => ({ route: 0, online: false, fenced: 0 }),
  display: {
    icon: "server",
    status: (s) => (s.online ? `online on socket ${s.route}` : "offline"),
    mood: (s) => (s.online ? "ok" : "off"),
  },
  transitions: {
    open: {
      on: Open,
      description: "A socket from the Mac. With newestWins it replaces the route; before, a live route refused it.",
      sources: ["packages/axo-api-worker/src/axo-host-relay.ts#AxoHostRelay.fetch"],
      sends: [Accepted, Refused, Closed],
      starts: ["lease"],
      run(s, m, ctx) {
        if (s.online && !newestWins.on) return ctx.reply(Refused, { conn: m.conn });
        if (s.online) ctx.send(ctx.the(Axod), Closed, { conn: s.route });
        if (s.route) s.fenced = s.route;
        s.route = m.conn;
        s.online = true;
        ctx.start("lease");
        ctx.reply(Accepted, { conn: m.conn });
      },
    },
    lease: {
      after: "150 seconds",
      description: "No heartbeat for the lease's length: fence the route; the Mac is offline.",
      sources: ["packages/axo-api-worker/src/axo-host-relay.ts#AxoHostRelay.alarm", "packages/axo-api-worker/src/axo-host-relay.ts#AxoHostRelay.fence"],
      uses: [silent],
      sends: [Closed],
      starts: ["lease"],
      run(s, _m, ctx) {
        if (!s.online) return;
        // A live Mac's heartbeat always came in time (see `silent`).
        if (!ctx.get(silent)) return ctx.start("lease");
        if (!leaseExpires.on) return;
        s.fenced = s.route;
        s.online = false;
        ctx.send(ctx.the(Axod), Closed, { conn: s.route });
      },
    },
  },
});

// ─── Properties ─────────────────────────────────────────────────────────────────

const reconnectsAreNeverRefused = defineProperty("reconnectsAreNeverRefused", {
  description: "A Mac that reconnects is let in at once, however long the old socket's lease had left.",
  always: (w) => w.the(Axod).state.refusals === 0,
  needs: [newestWins],
});

const aMacThatReconnectsIsOnline = defineProperty("aMacThatReconnectsIsOnline", {
  description: "A Mac that is up ends up routed to on its newest socket.",
  leadsTo: {
    whenever: (w) => !w.the(Axod).state.gone && !w.the(Axod).state.connected,
    then: (w) => w.the(Axod).state.gone || (w.the(HostDO).state.online && w.the(HostDO).state.route === w.the(Axod).state.conn),
  },
});

const aSilentMacGoesOffline = defineProperty("aSilentMacGoesOffline", {
  description: "A Mac that goes away without a word is shown offline once its lease runs out.",
  leadsTo: { whenever: (w) => w.the(Axod).state.gone, then: (w) => !w.the(HostDO).state.online },
  needs: [leaseExpires],
});

const oldSocketsStayFenced = defineProperty("oldSocketsStayFenced", {
  description: "Once replaced, a socket is never routed to again.",
  always: (w) => !w.the(HostDO).state.online || w.the(HostDO).state.route > w.the(HostDO).state.fenced,
});

// ─── Scenarios ──────────────────────────────────────────────────────────────────

const wakesElsewhere = defineScenario("A laptop wakes on another network", {
  description: "The old socket died where the HostDO could not see it. The new one replaces it at once; the old lease does not hold the Mac out.",
  run(s) {
    s.settle({ until: (w) => w.the(Axod).state.connected });
    s.act(s.the(Axod), "dropSilently");
    s.settle({ until: (w) => w.the(Axod).state.connected && w.the(HostDO).state.route === 2 });
  },
});

const losesPower = defineScenario("A Mac loses power", {
  description: "No goodbye and no close: the lease runs out and the Mac is shown offline.",
  run(s) {
    s.settle({ until: (w) => w.the(Axod).state.connected });
    s.act(s.the(Axod), "powerOff");
    s.settle({ until: (w) => !w.the(HostDO).state.online });
  },
});

export default defineSpec({
  name: "Host lease",
  description: "How a Mac's route on its HostDO is kept by a heartbeat every minute, replaced by its newest socket, and given up when the Mac goes silent.",
  actors: [Axod, HostDO],
  limits: [HEARTBEAT, LEASE],
  finalState: { description: "The Mac lost power, and its HostDO shows it offline.", when: (w) => w.the(Axod).state.gone && !w.the(HostDO).state.online },
  properties: [reconnectsAreNeverRefused, aMacThatReconnectsIsOnline, aSilentMacGoesOffline, oldSocketsStayFenced],
  scenarios: [wakesElsewhere, losesPower],
});
