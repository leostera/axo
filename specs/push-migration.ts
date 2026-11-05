import { atMost, budget, defineActor, defineCall, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone, FAULT, oneOf, spend } from "@leostera/feynman";

const faults = budget("faults", 1);

// RFD0032, Migration: how protocol 3 (host sockets) is deployed, and rolled back, while clients
// on protocol 2 keep working, without a moment where a client silently stops getting records.
//
// What the platform does, which the design has to survive:
// - A deploy is not atomic. The Worker takes the new code at once; each Durable Object adopts it
//   on its own, when it next wakes after hibernating (deferred code updates, up to 5 minutes, or a
//   forced reset after that). For a while, objects on the old and the new code call each other.
// - Hibernated WebSockets survive the adoption: a socket accepted by one version delivers its next
//   frame to whichever version the object runs then. A rollback is a deploy like any other.
// - Clients update when they update: a tab runs the JavaScript it loaded, the Mac and iPhone apps
//   run the build they have. A protocol 2 client must keep working indefinitely.
//
// Versions: 1 is the preparatory release (P), which already knows that protocol 3 exists: its
// HostDO closes client sockets it does not own when it wakes, and it is the oldest release a
// rollback may go to. 2 is the release with protocol 3. The release before P (today's) is not a
// safe rollback target once protocol 3 has run, since it keeps such sockets open and never writes
// to them.
//
// Records are a counter here (push-delivery.ts and client-delivery.ts model them); what matters is
// whether a connected client keeps hearing about new ones. One HostDO, one ClientDO, one client.

const closeUnknownSockets = defineRule("closeUnknownSockets", {
  description: "A HostDO on code without protocol 3 (the preparatory release) closes, when it wakes, every client socket it does not own, so a client on a socket a newer version accepted reconnects.",
});
const fallBackToTwo = defineRule("fallBackToTwo", {
  description: "A protocol 3 client that is refused (hello 3 is invalid, or the host socket fails or closes before its welcome) connects again with protocol 2 for that connection.",
});
const newerConnectionWins = defineRule("newerConnectionWins", {
  description: "A client numbers its connections; a HostDO keeps the newest host socket of a client and refuses an older one that arrives late, so a delayed hello can't take over from the socket in use.",
});
const frozenWire = defineRule("frozenWire", {
  description: "Protocol 2 frames keep their exact shape: the web app parses them strictly, so a field added for protocol 3 would break every tab on protocol 2.",
});

const Hello = defineMessage("Hello", { protocol: oneOf(2, 3), socket: Number }, { name: "axo.client.hello", over: "websocket" });
const Welcome = defineMessage("Welcome", { socket: Number, protocol: oneOf(2, 3), extra: Boolean }, { name: "hosts (and Sessions, in protocol 2)", over: "websocket", tone: "reply" });
const Invalid = defineMessage("Invalid", { socket: Number }, { name: "invalid params: protocol 2 only", over: "websocket", tone: "refused" });
const HostHello = defineMessage("HostHello", { socket: Number }, { name: "host socket: axo.client.hello (protocol 3)", over: "websocket" });
const HostWelcome = defineMessage("HostWelcome", { socket: Number, head: Number }, { name: "the host's index", over: "websocket", tone: "reply" });
const HostRefused = defineMessage("HostRefused", { socket: Number }, { name: "host socket refused or closed", over: "websocket", tone: "refused" });
const Head = defineMessage("Head", { socket: Number, head: Number }, { name: "records (as a head)", over: "websocket", tone: "stream" });
const AccountClosed = defineMessage("AccountClosed", { socket: Number }, { name: "account socket closed", over: "websocket", tone: "refused" });
const Subscribe = defineCall("Subscribe", {}, { name: "HostDO.subscribe", over: "rpc" });
const Subscribed = defineMessage("Subscribed", { head: Number }, { name: "the host's index", over: "rpc", tone: "reply" });
const Notify = defineCall("Notify", { head: Number }, { name: "ClientDO.notify", over: "rpc" });
const Noted = defineMessage("Noted", {}, { name: "noted", over: "rpc", tone: "reply" });
const Update = defineMessage("Update", { version: Number }, { name: "code update", over: "rpc" });

const people = defineZone({ name: "Clients", description: "a tab, or the Mac and iPhone apps", place: { column: 0 } });
const cloud = defineZone({ name: "Cloudflare", description: "the Worker, a ClientDO per client, a HostDO per Mac", place: { column: 1, region: true } });

export const Cloudflare = defineActor({
  name: "Cloudflare",
  description: "Deploys and rollbacks: the Worker takes the code at once, each Durable Object when it next wakes.",
  zone: cloud,
  singleton: true,
  initialState: () => ({ latest: 1 }),
  display: { icon: "cloud", status: (s) => `version ${s.latest} deployed` },
  actions: {
    deploy: {
      with: [atMost(1)],
      label: "Deploy protocol 3",
      description: "Deploys version 2. Each Durable Object adopts it when it next wakes.",
      when: (s) => s.latest === 1,
      sends: [Update],
      run(s, _i, ctx) {
        s.latest = 2;
        ctx.send(ctx.the(HostDO), Update, { version: 2 });
        ctx.send(ctx.the(ClientDO), Update, { version: 2 });
      },
    },
    rollback: {
      with: [atMost(1)],
      label: "Roll back",
      description: "Deploys version 1 again, the preparatory release.",
      when: (s) => s.latest === 2,
      sends: [Update],
      run(s, _i, ctx) {
        s.latest = 1;
        ctx.send(ctx.the(HostDO), Update, { version: 1 });
        ctx.send(ctx.the(ClientDO), Update, { version: 1 });
      },
    },
  },
  transitions: {},
});

export const Client = defineActor({
  name: "Client",
  description: "A client: on protocol 2 (an old build, or a tab loaded before the update) or one that tries protocol 3 first.",
  zone: people,
  singleton: true,
  initialState: () => ({
    /** What it speaks: 2, or 3 with 2 to fall back on. */
    speaks: 3 as 2 | 3,
    /** The protocol of the connection it holds now; 0 while it has none. */
    using: 0 as 0 | 2 | 3,
    /** Protocol 3 was refused on this connection attempt: the next one uses 2. */
    pinned: false,
    socket: 0,
    connecting: false,
    /** The account socket said hello back; for protocol 3, the host socket too. */
    account: false,
    host: false,
    /** The newest head it has heard. */
    head: 0,
    /** A frame it could not parse: a protocol 2 client that saw a protocol 3 field. */
    broken: false,
  }),
  display: {
    icon: "browser",
    status: (s) => (s.broken ? "broken: could not parse a frame" : !s.using ? "connecting" : `protocol ${s.using}, head ${s.head}`),
    mood: (s) => (s.broken ? "bad" : s.using ? "ok" : "busy"),
  },
  actions: {
    connect: {
      with: [atMost(1)],
      label: "Open the app",
      description: "Connects its account socket and says hello in the newest protocol it may use.",
      when: (s) => !s.connecting && s.using === 0,
      sends: [Hello],
      run: (s, _i, ctx) => connect(s, ctx),
    },
  },
  transitions: {
    welcome: {
      on: Welcome,
      description: "The account socket is open. In protocol 3 it then opens a socket on the Mac's HostDO; in protocol 2 the Sessions come on the account socket.",
      sends: [HostHello],
      run(s, m, ctx) {
        if (m.socket !== s.socket) return;
        // The web app's schemas are strict: a protocol 2 frame with a field it does not know fails to parse.
        if (m.protocol === 2 && m.extra && s.speaks === 2) s.broken = true;
        s.account = true;
        if (m.protocol === 2) {
          s.using = 2;
          s.connecting = false;
          return;
        }
        ctx.send(ctx.the(HostDO), HostHello, { socket: s.socket });
      },
    },
    invalid: {
      on: Invalid,
      description: "The ClientDO speaks only protocol 2: it says hello again in protocol 2, on the same socket.",
      sends: [Hello],
      run(s, m, ctx) {
        if (m.socket !== s.socket || !fallBackToTwo.on) return;
        s.pinned = true;
        ctx.send(ctx.the(ClientDO), Hello, { protocol: 2, socket: s.socket });
      },
    },
    hostWelcome: {
      on: HostWelcome,
      description: "The host socket is open: records come on it from now on.",
      run(s, m) {
        if (m.socket !== s.socket) return;
        s.host = true;
        s.using = 3;
        s.connecting = false;
        s.head = Math.max(s.head, m.head);
      },
    },
    hostRefused: {
      on: HostRefused,
      description: "The host socket was refused, or closed: it drops both sockets and connects again, in protocol 2 if this one never got going.",
      sends: [Hello],
      run(s, m, ctx) {
        if (m.socket !== s.socket) return;
        if (!s.host && fallBackToTwo.on) s.pinned = true;
        reconnect(s, ctx);
      },
    },
    accountClosed: {
      on: AccountClosed,
      description: "The account socket closed: it connects again.",
      sends: [Hello],
      run: (s, m, ctx) => void (m.socket === s.socket && reconnect(s, ctx)),
    },
    head: {
      on: Head,
      description: "New records: on the host socket in protocol 3, on the account socket in protocol 2.",
      run: (s, m) => void (m.socket === s.socket && (s.head = Math.max(s.head, m.head))),
    },
  },
});

type ClientState = any;

function connect(s: ClientState, ctx: any): void {
  s.socket += 1;
  s.connecting = true;
  s.using = 0;
  s.account = false;
  s.host = false;
  ctx.send(ctx.the(ClientDO), Hello, { protocol: s.speaks === 3 && !s.pinned ? 3 : 2, socket: s.socket });
}
/** Drops what it holds and connects again, after a backoff; a pin to protocol 2 lasts one connection. */
function reconnect(s: ClientState, ctx: any): void {
  connect(s, ctx);
  s.pinned = false;
}

export const ClientDO = defineActor({
  name: "ClientDO",
  description: "The client's Durable Object: the account socket. In protocol 2 it also follows the HostDO and passes its records on.",
  zone: cloud,
  singleton: true,
  initialState: () => ({
    version: 1,
    socket: 0,
    protocol: 0 as 0 | 2 | 3,
    following: false,
    /** The newest socket the reset closed: frames still in flight on it are never delivered. */
    closed: 0,
  }),
  display: { icon: "server", status: (s) => `version ${s.version}${s.socket ? `, protocol ${s.protocol}` : ""}` },
  actions: {
    forcedUpdate: {
      with: [spend(faults)],
      tags: [FAULT],
      label: "Force the update",
      description: "The ClientDO did not hibernate within the deadline, so it is reset on the code deployed: the account socket closes, and what it held in memory goes.",
      when: (s) => s.socket > 0,
      sends: [AccountClosed],
      run(s, _i, ctx) {
        ctx.send(ctx.the(Client), AccountClosed, { socket: s.socket });
        s.closed = s.socket;
        s.socket = 0;
      },
    },
  },
  transitions: {
    hello: {
      on: Hello,
      description: "Version 2 takes protocol 3 (no following: the client has its own host socket) or 2; version 1 refuses 3 as invalid params.",
      sends: [Welcome, Invalid, Subscribe],
      run(s, m, ctx) {
        if (m.socket <= s.closed) return;
        s.socket = m.socket;
        if (m.protocol === 3 && s.version < 2) return ctx.reply(Invalid, { socket: m.socket });
        s.protocol = m.protocol;
        // Protocol 2's hello reply keeps its exact shape in every version.
        ctx.reply(Welcome, { socket: m.socket, protocol: m.protocol, extra: m.protocol === 2 && s.version === 2 && !frozenWire.on });
        if (m.protocol === 2) ctx.send(ctx.the(HostDO), Subscribe, {});
      },
    },
    subscribed: {
      on: Subscribed,
      description: "Follows the HostDO; the index carries its head.",
      sends: [Head],
      run(s, m, ctx) {
        s.following = true;
        if (s.protocol === 2) ctx.send(ctx.the(Client), Head, { socket: s.socket, head: m.head });
      },
    },
    notify: {
      on: Notify,
      description: "A notice from the HostDO: in protocol 2, the records go to the client.",
      sends: [Noted, Head],
      run(s, m, ctx) {
        if (s.protocol === 2 && s.socket) ctx.send(ctx.the(Client), Head, { socket: s.socket, head: m.head });
        ctx.reply(Noted, {});
      },
    },
    update: {
      on: Update,
      description: "Adopts the code deployed when it next wakes; its socket stays open, its memory goes.",
      run: (s, m) => void (s.version = m.version),
    },
  },
});

export const HostDO = defineActor({
  name: "HostDO",
  description: "The Mac's Durable Object: it commits what axod uploads, notifies its protocol 2 followers, and pushes to protocol 3 host sockets.",
  zone: cloud,
  singleton: true,
  initialState: () => ({
    version: 1,
    head: 0,
    followers: false,
    /** A protocol 3 host socket, by the client's socket id; 0 for none. It survives code updates. */
    hostSocket: 0,
  }),
  display: { icon: "cloud", status: (s) => `version ${s.version}, head ${s.head}${s.hostSocket ? ", a host socket" : ""}` },
  actions: {
    commit: {
      with: [atMost(2)],
      label: "axod uploads a record",
      description: "A record is committed: followers are notified, and in version 2 it is pushed on the host socket.",
      sends: [Notify, Head],
      run(s, _i, ctx) {
        s.head += 1;
        if (s.followers) ctx.send(ctx.the(ClientDO), Notify, { head: s.head });
        // Version 1 has no idea what a host socket is: it writes nothing to one.
        if (s.version === 2 && s.hostSocket) ctx.send(ctx.the(Client), Head, { socket: s.hostSocket, head: s.head });
      },
    },
  },
  transitions: {
    hostHello: {
      on: HostHello,
      description: "Version 2 takes the host socket and answers with the index; version 1 refuses it (403).",
      sends: [HostWelcome, HostRefused],
      run(s, m, ctx) {
        if (s.version < 2) return ctx.reply(HostRefused, { socket: m.socket });
        if (newerConnectionWins.on && m.socket < s.hostSocket) return ctx.reply(HostRefused, { socket: m.socket });
        s.hostSocket = m.socket;
        ctx.reply(HostWelcome, { socket: m.socket, head: s.head });
      },
    },
    subscribe: {
      on: Subscribe,
      description: "Adds the ClientDO as a follower, in either version.",
      sends: [Subscribed],
      run(s, _m, ctx) {
        s.followers = true;
        ctx.reply(Subscribed, { head: s.head });
      },
    },
    noted: { on: Noted, description: "The ClientDO took the notice.", run: () => {} },
    update: {
      on: Update,
      description: "Adopts the code deployed when it next wakes (axod's heartbeat wakes it within seconds). Sockets stay; version 1 closes the client sockets it does not own.",
      sends: [HostRefused],
      run(s, m, ctx) {
        s.version = m.version;
        if (m.version < 2 && s.hostSocket && closeUnknownSockets.on) {
          ctx.send(ctx.the(Client), HostRefused, { socket: s.hostSocket });
          s.hostSocket = 0;
        }
      },
    },
  },
});

const neverBroken = defineProperty("neverBroken", {
  needs: [frozenWire],
  description: "No client ever receives a frame it can't parse, on any mix of versions.",
  always: (w) => !w.the(Client).state.broken,
});
const keepsHearing = defineProperty("keepsHearing", {
  needs: [closeUnknownSockets, fallBackToTwo, newerConnectionWins],
  description: "Through any deploy and rollback, a client that opened the app ends up connected and hearing the newest head.",
  leadsTo: {
    whenever: (w) => w.the(Client).state.socket > 0 && (w.the(Client).state.using === 0 || w.the(Client).state.head < w.the(HostDO).state.head),
    then: (w) => w.the(Client).state.using !== 0 && w.the(Client).state.head === w.the(HostDO).state.head,
  },
});

const deployWhileConnected = defineScenario("Deploying protocol 3", {
  description: "A client that tries protocol 3 before the deploy is refused and uses protocol 2; that connection keeps working on the new code, and moves to protocol 3 the next time it connects.",
  run(s) {
    s.act(s.the(Client), "connect");
    s.settle();
    s.act(s.the(Cloudflare), "deploy");
    s.settle();
    s.act(s.the(HostDO), "commit");
    s.settle({ until: (w) => w.the(Client).state.head === 1 });
  },
});
const rollingBack = defineScenario("Rolling back", {
  description: "After protocol 3 ran, a rollback to the preparatory release closes the host socket when the HostDO wakes on the old code; the client falls back to protocol 2 and keeps getting records.",
  setup(w) {
    w.set(Cloudflare, { latest: 2 });
    w.set(ClientDO, { version: 2 });
    w.set(HostDO, { version: 2 });
  },
  run(s) {
    s.act(s.the(Client), "connect");
    s.settle({ until: (w) => w.the(Client).state.using === 3 });
    s.act(s.the(Cloudflare), "rollback");
    s.settle();
    s.act(s.the(HostDO), "commit");
    s.settle({ until: (w) => w.the(Client).state.head === 1 && w.the(Client).state.using === 2 });
  },
});

const oldTab = defineScenario("A tab on protocol 2", {
  description: "A tab loaded before the update speaks only protocol 2: it keeps working, with the same frames, on the new code.",
  setup(w) {
    w.set(Client, { speaks: 2 });
  },
  run(s) {
    s.act(s.the(Cloudflare), "deploy");
    s.settle();
    s.act(s.the(Client), "connect");
    s.settle();
    s.act(s.the(HostDO), "commit");
    s.settle({ until: (w) => w.the(Client).state.head === 1 });
  },
});

export default defineSpec({
  name: "Push migration",
  description: "How protocol 3 ships and rolls back across Durable Objects that adopt new code at different times, with clients on either protocol, without a client ever going deaf or getting a frame it can't parse.",
  actors: [Cloudflare, Client, ClientDO, HostDO],
  properties: [neverBroken, keepsHearing],
  scenarios: [deployWhileConnected, rollingBack, oldTab],
});
