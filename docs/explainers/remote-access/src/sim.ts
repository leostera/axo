// A discrete-event model of Axo remote access: people, phones and browsers, Cloudflare Access,
// the relay (Worker + per-account and per-host state) and Macs running axod.
//
// Nothing here talks to the network. Every message is a packet with a send and an arrival time;
// every wait (retry backoff, timeouts, heartbeats) is a timer. `step` delivers the earliest one
// and records what changed. The rules mirror the real code; see the README for where each lives.

import type { Input } from "./commands";

export type Ms = number;
export type NodeId = "access" | "relay" | `client:${string}` | `mac:${string}`;

// ---------- Tunables (the same values as the real system where one exists) ----------

export const LATENCY = { client: 160, access: 40, mac: 220 };
export const CODE_LIFETIME: Ms = 10 * 60 * 1000;
export const HTTP_TIMEOUT: Ms = 5000;
export const MAC_NOTICES_LOSS: Ms = 1500;
export const RELAY_NOTICES_LOSS: Ms = 6000;
export const FIRST_RETRY: Ms = 1000;
export const MAX_RETRY: Ms = 30_000;
export const PENDING_CODE_CAP = 3;

// ---------- State ----------

export type Person = { id: string; name: string };

export type ConnectionState = "not linked" | "connecting" | "connected" | "disconnected";

export type Mac = {
  id: string;
  name: string;
  hostId: string;
  generation: string;
  /** Wi-Fi: packets to or from an offline Mac are lost. */
  online: boolean;
  /** Whether axod is running; its database and Keychain survive restarts. */
  running: boolean;
  /** axod's `host_link` row (persistent). */
  db: { account: string | null; credential: string | null; pending: string | null };
  /** Credential IDs whose secrets are in this Mac's Keychain (persistent). */
  keychain: string[];
  // In memory only:
  state: ConnectionState;
  lastError: string | null;
  retryDelay: Ms;
  retryTimer: number | null;
  /** The connection attempt or open socket, by packet correlation id. */
  socket: number | null;
  socketOpen: boolean;
  linkRequest: number | null;
  terminal: string[];
};

export type Client = {
  id: string;
  name: string;
  kind: "phone" | "browser";
  owner: string;
  signedInAs: string | null;
  hosts: { hostId: string; label: string; status: HostStatus }[] | null;
  codes: { code: string; expiresAt: Ms }[];
  attached: string | null;
  terminal: string[];
  lastError: string | null;
};

export type HostStatus = "online" | "offline" | "revoked";

export type HostRecord = {
  hostId: string;
  label: string;
  credential: string;
  generation: string;
  revoked: boolean;
  /** Socket id of the attached axod, if any. */
  socket: number | null;
  registered: boolean;
  clients: string[];
};

export type Account = { id: string; person: string; hosts: Record<string, HostRecord> };

export type Code = {
  code: string;
  account: string;
  expiresAt: Ms;
  usedBy: { hostId: string; credential: string } | null;
};

export type Flags = {
  /** Proposed: an Unlink button on the Mac (local: forget the link, delete the secret). */
  unlink: boolean;
  /** Proposed (G6): at most PENDING_CODE_CAP unexpired, unused codes per account. */
  codeCap: boolean;
};

// ---------- Messages ----------

type ClientRequest =
  | { t: "codes.create" }
  | { t: "hosts.list" }
  | { t: "host.open"; hostId: string }
  | { t: "host.leave" }
  | { t: "host.revoke"; hostId: string }
  | { t: "input"; text: string };

export type Body =
  | { t: "login"; person: string }
  | { t: "logout" }
  | { t: "login.ok"; person: string }
  | { t: "logout.ok" }
  | { t: "request"; req: ClientRequest }
  | { t: "forward"; client: string; person: string; req: ClientRequest }
  | { t: "denied"; reason: string }
  | { t: "code"; code: string; expiresAt: Ms }
  | { t: "hosts"; hosts: NonNullable<Client["hosts"]> }
  | { t: "opened"; hostId: string; status: HostStatus }
  | { t: "host.status"; hostId: string; status: HostStatus }
  | { t: "detached"; reason: string }
  | { t: "revoked.ok"; hostId: string }
  | { t: "error"; reason: string }
  | { t: "output"; text: string }
  | { t: "redeem"; req: number; code: string; hostId: string; generation: string; credential: string; label: string }
  | { t: "redeemed"; req: number; account: string }
  | { t: "redeem.failed"; req: number; status: number; reason: string }
  | { t: "connect"; socket: number; account: string; hostId: string; credential: string }
  | { t: "accepted"; socket: number }
  | { t: "refused"; socket: number; status: number; reason: string }
  | { t: "register"; socket: number; account: string; hostId: string; label: string }
  | { t: "host.output"; socket: number; account: string; hostId: string; text: string }
  | { t: "bye"; socket: number; account: string; hostId: string }
  | { t: "relay.input"; text: string; from: string }
  | { t: "close"; socket: number; reason: string };

export type Tone = "request" | "reply" | "refused" | "stream" | "lost";

export type Packet = {
  id: number;
  from: NodeId;
  to: NodeId;
  body: Body;
  label: string;
  tone: Tone;
  sentAt: Ms;
  arriveAt: Ms;
  /** Set when the network loses it; it still "arrives" so you can see where it died. */
  lost: boolean;
};

type TimerBody =
  | { t: "retry" }
  | { t: "connect.timeout"; socket: number }
  | { t: "redeem.timeout"; req: number }
  | { t: "socket.lost"; socket: number }
  | { t: "heartbeat.lost"; account: string; hostId: string; socket: number }
  | { t: "command.done"; text: string; from: string }
  | { t: "code.expired"; code: string };

export type Timer = { id: number; at: Ms; node: NodeId; body: TimerBody; label: string };

export type Change = { key: string; before: string; after: string };

export type LogEntry = {
  id: number;
  at: Ms;
  node: NodeId | "you";
  title: string;
  tone: Tone | "action" | "timer";
  changes: Change[];
};

export type Sim = {
  now: Ms;
  nextId: number;
  people: Person[];
  clients: Client[];
  macs: Mac[];
  access: { sessions: Record<string, string> };
  relay: { accounts: Record<string, Account>; byPerson: Record<string, string>; codes: Code[] };
  packets: Packet[];
  timers: Timer[];
  log: LogEntry[];
  flags: Flags;
  /** What people did to get here, in order; see `perform` and `replay`. */
  inputs: Input[];
};

// ---------- Construction ----------

export function emptySim(): Sim {
  return {
    now: 0,
    nextId: 1,
    people: [],
    clients: [],
    macs: [],
    access: { sessions: {} },
    relay: { accounts: {}, byPerson: {}, codes: [] },
    packets: [],
    timers: [],
    log: [],
    flags: { unlink: false, codeCap: false },
    inputs: [],
  };
}

const hex = (n: number, width = 4) => (n * 2654435761 % 0xffff).toString(16).padStart(width, "0");

export function addPerson(sim: Sim, name: string): Sim {
  return act(sim, `Added ${name}, a person Access can sign in`, (s) => {
    s.people.push({ id: `p${id(s)}`, name });
  });
}

export function addMac(sim: Sim, name: string): Sim {
  return act(sim, `Added the Mac "${name}"; axod starts unlinked`, (s) => {
    const n = id(s);
    s.macs.push({
      id: `m${n}`,
      name,
      hostId: `host-${hex(n)}`,
      generation: `gen-${hex(n + 7, 2)}`,
      online: true,
      running: true,
      db: { account: null, credential: null, pending: null },
      keychain: [],
      state: "not linked",
      lastError: null,
      retryDelay: FIRST_RETRY,
      retryTimer: null,
      socket: null,
      socketOpen: false,
      linkRequest: null,
      terminal: [],
    });
  });
}

export function addClient(sim: Sim, kind: Client["kind"], owner: string, label?: string): Sim {
  const person = sim.people.find((p) => p.id === owner);
  const name = label ?? `${person?.name ?? "Someone"}'s ${kind}`;
  return act(sim, `Added ${name}`, (s) => {
    s.clients.push({
      id: `c${id(s)}`,
      name,
      kind,
      owner,
      signedInAs: null,
      hosts: null,
      codes: [],
      attached: null,
      terminal: [],
      lastError: null,
    });
  });
}

export function setFlag(sim: Sim, flag: keyof Flags, value: boolean): Sim {
  return act(sim, `${value ? "Enabled" : "Disabled"} proposal: ${flag}`, (s) => {
    s.flags[flag] = value;
  });
}

// ---------- User actions ----------

export const clientActions = {
  signIn: (sim: Sim, clientId: string, personId: string) =>
    act(sim, `${clientName(sim, clientId)}: sign in with Cloudflare Access`, (s) => {
      send(s, `client:${clientId}`, "access", { t: "login", person: personId }, `sign in as ${personName(s, personId)}`);
    }),
  signOut: (sim: Sim, clientId: string) =>
    act(sim, `${clientName(sim, clientId)}: sign out`, (s) => {
      const client = clientById(s, clientId);
      if (client.attached) request(s, client, { t: "host.leave" });
      send(s, `client:${clientId}`, "access", { t: "logout" }, "sign out");
    }),
  createCode: (sim: Sim, clientId: string) =>
    act(sim, `${clientName(sim, clientId)}: Pair a host`, (s) =>
      request(s, clientById(s, clientId), { t: "codes.create" })),
  listHosts: (sim: Sim, clientId: string) =>
    act(sim, `${clientName(sim, clientId)}: refresh hosts`, (s) =>
      request(s, clientById(s, clientId), { t: "hosts.list" })),
  open: (sim: Sim, clientId: string, hostId: string) =>
    act(sim, `${clientName(sim, clientId)}: open ${hostId}`, (s) =>
      request(s, clientById(s, clientId), { t: "host.open", hostId })),
  leave: (sim: Sim, clientId: string) =>
    act(sim, `${clientName(sim, clientId)}: close the terminal`, (s) =>
      request(s, clientById(s, clientId), { t: "host.leave" })),
  revoke: (sim: Sim, clientId: string, hostId: string) =>
    act(sim, `${clientName(sim, clientId)}: revoke ${hostId}`, (s) =>
      request(s, clientById(s, clientId), { t: "host.revoke", hostId })),
  type: (sim: Sim, clientId: string, text: string) =>
    act(sim, `${clientName(sim, clientId)}: type "${text}"`, (s) => {
      const client = clientById(s, clientId);
      client.terminal.push(`$ ${text}`);
      request(s, client, { t: "input", text });
    }),
};

export const macActions = {
  link: (sim: Sim, macId: string, code: string) =>
    act(sim, `${macName(sim, macId)}: Settings → Remote Access → Link "${code}"`, (s) => startLink(s, macById(s, macId), code)),
  setNetwork: (sim: Sim, macId: string, online: boolean) =>
    act(sim, `${macName(sim, macId)}: Wi-Fi ${online ? "back" : "off"}`, (s) => {
      const mac = macById(s, macId);
      mac.online = online;
      if (!online && mac.socketOpen && mac.socket !== null) {
        timer(s, `mac:${mac.id}`, MAC_NOTICES_LOSS, { t: "socket.lost", socket: mac.socket }, "axod notices the line is dead");
        heartbeatLoss(s, mac);
      }
      if (online && mac.state === "disconnected" && mac.socket === null) scheduleRetry(s, mac, 0);
    }),
  restart: (sim: Sim, macId: string) =>
    act(sim, `${macName(sim, macId)}: restart axod (memory is lost, database and Keychain stay)`, (s) => {
      const mac = macById(s, macId);
      if (mac.socketOpen) heartbeatLoss(s, mac);
      s.timers = s.timers.filter((t) => t.node !== `mac:${mac.id}`);
      Object.assign(mac, {
        running: true,
        state: mac.db.account ? "disconnected" : "not linked",
        lastError: null,
        retryDelay: FIRST_RETRY,
        retryTimer: null,
        socket: null,
        socketOpen: false,
        linkRequest: null,
      } satisfies Partial<Mac>);
      if (mac.db.account) scheduleRetry(s, mac, 300);
    }),
  retry: (sim: Sim, macId: string) =>
    act(sim, `${macName(sim, macId)}: Retry`, (s) => {
      const mac = macById(s, macId);
      if (mac.db.account && !mac.socketOpen && mac.socket === null) scheduleRetry(s, mac, 0);
    }),
  unlink: (sim: Sim, macId: string) =>
    act(sim, `${macName(sim, macId)}: Unlink (proposed)`, (s) => {
      const mac = macById(s, macId);
      if (mac.socketOpen && mac.socket !== null && mac.db.account) {
        send(s, `mac:${mac.id}`, "relay", { t: "bye", socket: mac.socket, account: mac.db.account, hostId: mac.hostId }, "goodbye");
      }
      mac.keychain = [];
      mac.db = { account: null, credential: null, pending: null };
      Object.assign(mac, { state: "not linked", socket: null, socketOpen: false, lastError: null } satisfies Partial<Mac>);
      cancelRetry(s, mac);
    }),
  type: (sim: Sim, macId: string, text: string) =>
    act(sim, `${macName(sim, macId)}: type "${text}" locally`, (s) => {
      const mac = macById(s, macId);
      mac.terminal.push(`$ ${text}`);
      timer(s, `mac:${mac.id}`, 80, { t: "command.done", text, from: "local" }, "the command finishes");
    }),
};

export function skip(sim: Sim, by: Ms): Sim {
  return act(sim, `Let ${Math.round(by / 60000)} minutes pass`, (s) => {
    // Jump past quiet time; anything due in between still happens, in order.
    const target = s.now + by;
    while (nextEventAt(s) !== null && nextEventAt(s)! <= target) deliverNext(s);
    s.now = target;
  });
}

// ---------- Time ----------

export function nextEventAt(sim: Sim): Ms | null {
  const times = [...sim.packets.map((p) => p.arriveAt), ...sim.timers.map((t) => t.at)];
  return times.length ? Math.min(...times) : null;
}

/** Moves the clock to `to`, delivering everything due on the way. Returns how many events ran. */
export function advance(sim: Sim, to: Ms, limit = Infinity): { sim: Sim; ran: number } {
  const s = structuredClone(sim);
  let ran = 0;
  while (ran < limit) {
    const at = nextEventAt(s);
    if (at === null || at > to) break;
    deliverNext(s);
    ran++;
  }
  if (ran < limit) s.now = Math.max(s.now, to);
  return { sim: s, ran };
}

/** Runs until nothing is in flight or due within `horizon`; used to build presets. */
export function settle(sim: Sim, horizon: Ms = 20_000): Sim {
  let s = sim;
  for (let i = 0; i < 500; i++) {
    const at = nextEventAt(s);
    if (at === null || at > s.now + horizon) break;
    s = advance(s, at).sim;
  }
  return s;
}

function deliverNext(s: Sim) {
  const packet = [...s.packets].sort((a, b) => a.arriveAt - b.arriveAt || a.id - b.id)[0];
  const next = [...s.timers].sort((a, b) => a.at - b.at || a.id - b.id)[0];
  const before = snapshot(s);
  if (packet && (!next || packet.arriveAt <= next.at)) {
    s.now = packet.arriveAt;
    s.packets = s.packets.filter((p) => p.id !== packet.id);
    const title = deliver(s, packet);
    record(s, packet.to, title, packet.lost || !reachable(s, packet) ? "lost" : packet.tone, before);
  } else if (next) {
    s.now = next.at;
    s.timers = s.timers.filter((t) => t.id !== next.id);
    const title = fire(s, next);
    record(s, next.node, title, "timer", before);
  }
}

// ---------- Delivery ----------

function reachable(s: Sim, packet: Packet): boolean {
  const mac = packet.to.startsWith("mac:") ? macById(s, packet.to.slice(4)) : null;
  return !mac || (mac.online && mac.running);
}

function deliver(s: Sim, p: Packet): string {
  if (p.lost || !reachable(s, p)) return `“${p.label}” was lost on the way to ${nodeName(s, p.to)}`;
  if (p.to === "access") return atAccess(s, p);
  if (p.to === "relay") return atRelay(s, p);
  if (p.to.startsWith("client:")) return atClient(s, clientById(s, p.to.slice(7)), p.body);
  return atMac(s, macById(s, p.to.slice(4)), p.body);
}

function atAccess(s: Sim, p: Packet): string {
  const clientId = p.from.slice(7);
  const client = clientById(s, clientId);
  const b = p.body;
  switch (b.t) {
    case "login":
      s.access.sessions[clientId] = b.person;
      send(s, "access", p.from, { t: "login.ok", person: b.person }, "signed in", "reply");
      return `Access signed ${personName(s, b.person)} in on ${client.name}`;
    case "logout":
      delete s.access.sessions[clientId];
      send(s, "access", p.from, { t: "logout.ok" }, "signed out", "reply");
      return `Access ended ${client.name}'s session`;
    case "request": {
      const person = s.access.sessions[clientId];
      if (!person) {
        send(s, "access", p.from, { t: "denied", reason: "Access: sign in first" }, "sign in first", "refused");
        return `Access stopped ${client.name}: not signed in. The relay never saw the request`;
      }
      send(s, "access", "relay", { t: "forward", client: clientId, person, req: b.req }, `${b.req.t} + JWT(${personName(s, person)})`);
      return `Access let ${client.name}'s ${b.req.t} through with a signed JWT for ${personName(s, person)}`;
    }
    default:
      return "Access ignored an unexpected message";
  }
}

function atRelay(s: Sim, p: Packet): string {
  const b = p.body;
  switch (b.t) {
    case "forward":
      return relayApi(s, b.client, b.person, b.req);
    case "redeem":
      return redeem(s, p.from, b);
    case "connect":
      return acceptHost(s, p.from, b);
    case "register": {
      const host = s.relay.accounts[b.account]?.hosts[b.hostId];
      if (!host || host.socket !== b.socket) return "The relay ignored a registration from an old connection";
      host.registered = true;
      host.label = b.label;
      broadcast(s, host, { t: "host.status", hostId: host.hostId, status: "online" }, "Mac online");
      return `${b.label} registered: online in ${accountName(s, b.account)}`;
    }
    case "host.output": {
      const host = s.relay.accounts[b.account]?.hosts[b.hostId];
      if (!host || host.socket !== b.socket) return "The relay dropped output from a closed connection";
      broadcast(s, host, { t: "output", text: b.text }, "output", "stream");
      return host.clients.length
        ? `The relay passed output to ${host.clients.length} viewer(s). It keeps no copy`
        : "Output arrived, nobody is watching; the relay keeps no copy";
    }
    case "bye": {
      const host = s.relay.accounts[b.account]?.hosts[b.hostId];
      if (!host || host.socket !== b.socket) return "The relay ignored a goodbye from an old connection";
      dropHostSocket(s, host);
      return `${host.label} hung up; it shows as offline`;
    }
    default:
      return "The relay ignored an unexpected message";
  }
}

function relayApi(s: Sim, clientId: string, personId: string, req: ClientRequest): string {
  const to: NodeId = `client:${clientId}`;
  const account = accountFor(s, personId);
  const client = clientById(s, clientId);
  switch (req.t) {
    case "codes.create": {
      const live = s.relay.codes.filter((c) => c.account === account.id && !c.usedBy && c.expiresAt > s.now);
      if (s.flags.codeCap && live.length >= PENDING_CODE_CAP) {
        send(s, "relay", to, { t: "error", reason: `429: ${PENDING_CODE_CAP} codes already waiting` }, "429 too many codes", "refused");
        return `Refused a new code: ${accountName(s, account.id)} already has ${live.length} waiting (proposed cap)`;
      }
      const code = newCode(s);
      s.relay.codes.push({ code, account: account.id, expiresAt: s.now + CODE_LIFETIME, usedBy: null });
      timer(s, "relay", CODE_LIFETIME, { t: "code.expired", code }, `${code} expires`);
      send(s, "relay", to, { t: "code", code, expiresAt: s.now + CODE_LIFETIME }, code, "reply");
      return `Made code ${code} for ${accountName(s, account.id)}, valid 10 minutes. Only its HMAC is stored`;
    }
    case "hosts.list":
      send(s, "relay", to, { t: "hosts", hosts: hostSummaries(account) }, `${Object.keys(account.hosts).length} host(s)`, "reply");
      return `Listed ${accountName(s, account.id)}'s hosts for ${client.name}`;
    case "host.open": {
      const host = account.hosts[req.hostId];
      if (!host) {
        send(s, "relay", to, { t: "error", reason: "404: no such host in your account" }, "404", "refused");
        return `${req.hostId} isn't in ${accountName(s, account.id)}: 404, nothing about it is revealed`;
      }
      if (host.revoked) {
        send(s, "relay", to, { t: "error", reason: "403: host revoked" }, "403 revoked", "refused");
        return `Refused: ${host.label} is revoked`;
      }
      detachEverywhere(s, clientId);
      host.clients.push(clientId);
      send(s, "relay", to, { t: "opened", hostId: host.hostId, status: statusOf(host) }, `attached (${statusOf(host)})`, "reply");
      return `${client.name} is now watching ${host.label} (which is ${statusOf(host)})`;
    }
    case "host.leave":
      detachEverywhere(s, clientId);
      send(s, "relay", to, { t: "detached", reason: "closed" }, "detached", "reply");
      return `${client.name} stopped watching`;
    case "host.revoke": {
      const host = account.hosts[req.hostId];
      if (!host) {
        send(s, "relay", to, { t: "error", reason: "404: no such host in your account" }, "404", "refused");
        return `Revoke refused: ${req.hostId} isn't in this account`;
      }
      host.revoked = true;
      if (host.socket !== null) {
        const mac = s.macs.find((m) => m.hostId === host.hostId);
        if (mac) send(s, "relay", `mac:${mac.id}`, { t: "close", socket: host.socket, reason: "revoked" }, "close: revoked", "refused");
      }
      for (const viewer of host.clients) {
        send(s, "relay", `client:${viewer}`, { t: "detached", reason: "host revoked" }, "revoked", "refused");
      }
      host.clients = [];
      host.socket = null;
      host.registered = false;
      send(s, "relay", to, { t: "revoked.ok", hostId: host.hostId }, "204", "reply");
      return `Revoked ${host.label}: its socket and every viewer are closed. Its record stays, marked revoked`;
    }
    case "input": {
      const host = Object.values(account.hosts).find((h) => h.clients.includes(clientId));
      if (!host) {
        send(s, "relay", to, { t: "error", reason: "not attached to a host" }, "not attached", "refused");
        return "Input refused: not watching any host";
      }
      const mac = s.macs.find((m) => m.hostId === host.hostId);
      if (host.socket === null || !mac) {
        send(s, "relay", to, { t: "error", reason: `${host.label} is offline` }, "host offline", "refused");
        return `Input refused: ${host.label} is offline. Nothing is queued`;
      }
      send(s, "relay", `mac:${mac.id}`, { t: "relay.input", text: req.text, from: clientId }, req.text, "stream");
      return `Passed the keystrokes on to ${host.label}`;
    }
  }
}

function redeem(s: Sim, from: NodeId, b: Extract<Body, { t: "redeem" }>): string {
  const fail = (status: number, reason: string) => {
    send(s, "relay", from, { t: "redeem.failed", req: b.req, status, reason }, `${status}`, "refused");
    return `Refused redemption: ${reason}`;
  };
  const code = s.relay.codes.find((c) => c.code === b.code);
  if (!code) return fail(404, "unknown code");
  if (code.usedBy) {
    const same = code.usedBy.hostId === b.hostId && code.usedBy.credential === b.credential;
    if (!same) return fail(409, "code already used");
    send(s, "relay", from, { t: "redeemed", req: b.req, account: code.account }, `linked to ${accountName(s, code.account)}`, "reply");
    return `Same redemption again (same host, same credential): same answer`;
  }
  if (code.expiresAt <= s.now) return fail(410, "code expired");
  const account = s.relay.accounts[code.account]!;
  const existing = account.hosts[b.hostId];
  code.usedBy = { hostId: b.hostId, credential: b.credential };
  if (existing) {
    if (existing.socket !== null) {
      const mac = s.macs.find((m) => m.hostId === b.hostId);
      if (mac) send(s, "relay", from, { t: "close", socket: existing.socket, reason: "credential rotated" }, "close: rotated", "refused");
    }
    Object.assign(existing, { credential: b.credential, generation: b.generation, revoked: false, socket: null, registered: false });
  } else {
    account.hosts[b.hostId] = {
      hostId: b.hostId,
      label: b.label,
      credential: b.credential,
      generation: b.generation,
      revoked: false,
      socket: null,
      registered: false,
      clients: [],
    };
  }
  send(s, "relay", from, { t: "redeemed", req: b.req, account: account.id }, `linked to ${accountName(s, account.id)}`, "reply");
  return existing
    ? `${b.label} re-paired in ${accountName(s, account.id)}: new credential, the old one stops working`
    : `${b.label} joined ${accountName(s, account.id)}. The relay stores a verifier of its secret`;
}

function acceptHost(s: Sim, from: NodeId, b: Extract<Body, { t: "connect" }>): string {
  const host = s.relay.accounts[b.account]?.hosts[b.hostId];
  const refuse = (status: number, reason: string) => {
    send(s, "relay", from, { t: "refused", socket: b.socket, status, reason }, `${status}`, "refused");
    return `Refused a host connection: ${reason} (${status})`;
  };
  if (!host) return refuse(404, "unknown host");
  if (host.revoked) return refuse(403, "host revoked");
  if (host.credential !== b.credential) return refuse(403, "wrong credential");
  if (host.socket !== null) {
    // A newer connection from the same host replaces the old one.
    host.registered = false;
  }
  host.socket = b.socket;
  send(s, "relay", from, { t: "accepted", socket: b.socket }, "101 connected", "reply");
  return `${host.label}'s credential checks out; the relay holds its socket`;
}

function atClient(s: Sim, client: Client, b: Body): string {
  switch (b.t) {
    case "login.ok":
      client.signedInAs = b.person;
      client.lastError = null;
      request(s, client, { t: "hosts.list" });
      return `${client.name} is signed in as ${personName(s, b.person)} and asks for its host list`;
    case "logout.ok":
      Object.assign(client, { signedInAs: null, hosts: null, attached: null, terminal: [] } satisfies Partial<Client>);
      return `${client.name} is signed out`;
    case "denied":
    case "error":
      client.lastError = b.reason;
      return `${client.name} shows an error: ${b.reason}`;
    case "code":
      client.codes.push({ code: b.code, expiresAt: b.expiresAt });
      return `${client.name} shows the code ${b.code}. Type it into a Mac`;
    case "hosts":
      client.hosts = b.hosts;
      client.lastError = null;
      return `${client.name} lists ${b.hosts.length} host(s)`;
    case "opened":
      client.attached = b.hostId;
      client.terminal = [];
      client.lastError = b.status === "online" ? null : `${hostLabel(s, b.hostId)} is ${b.status}`;
      setClientHostStatus(client, b.hostId, b.status);
      return `${client.name} is watching ${hostLabel(s, b.hostId)}`;
    case "host.status":
      setClientHostStatus(client, b.hostId, b.status);
      client.lastError = b.status === "online" ? null : `${hostLabel(s, b.hostId)} is ${b.status}`;
      return `${client.name} sees ${hostLabel(s, b.hostId)} go ${b.status}`;
    case "detached":
      if (b.reason === "host revoked" && client.attached) setClientHostStatus(client, client.attached, "revoked");
      client.attached = null;
      client.lastError = b.reason === "closed" ? null : b.reason;
      return `${client.name} was detached: ${b.reason}`;
    case "revoked.ok":
      setClientHostStatus(client, b.hostId, "revoked");
      return `${client.name} confirms ${hostLabel(s, b.hostId)} is revoked`;
    case "output":
      client.terminal.push(b.text);
      return `${client.name} prints the output`;
    default:
      return `${client.name} ignored an unexpected message`;
  }
}

function atMac(s: Sim, mac: Mac, b: Body): string {
  switch (b.t) {
    case "redeemed": {
      if (mac.linkRequest !== b.req) return `${mac.name} ignored a late answer to an abandoned link attempt`;
      const previous = mac.db.credential;
      const previousAccount = mac.db.account;
      const credential = mac.db.pending!;
      mac.db = { account: b.account, credential, pending: null };
      if (previous && previous !== credential) mac.keychain = mac.keychain.filter((c) => c !== previous);
      mac.linkRequest = null;
      mac.lastError = null;
      cancelTimers(s, mac, (t) => t.body.t === "redeem.timeout");
      if (mac.socketOpen && mac.socket !== null && previousAccount) {
        send(s, `mac:${mac.id}`, "relay", { t: "bye", socket: mac.socket, account: previousAccount, hostId: mac.hostId }, "goodbye (old link)");
      }
      Object.assign(mac, { socket: null, socketOpen: false, state: "disconnected", retryDelay: FIRST_RETRY } satisfies Partial<Mac>);
      scheduleRetry(s, mac, 0);
      return `${mac.name} saved the link (${accountName(s, b.account)}, ${credential})${previous && previous !== credential ? ` and deleted ${previous}` : ""}; it connects now`;
    }
    case "redeem.failed":
      if (mac.linkRequest !== b.req) return `${mac.name} ignored a late refusal`;
      mac.linkRequest = null;
      mac.lastError = `could not link: ${b.reason}`;
      cancelTimers(s, mac, (t) => t.body.t === "redeem.timeout");
      return `${mac.name} couldn't link (${b.reason}). Its current link, if any, is untouched; the pending credential is kept for a retry`;
    case "accepted":
      if (mac.socket !== b.socket) return `${mac.name} ignored an old connection's acceptance`;
      cancelTimers(s, mac, (t) => t.body.t === "connect.timeout");
      Object.assign(mac, { socketOpen: true, state: "connected", lastError: null, retryDelay: FIRST_RETRY } satisfies Partial<Mac>);
      send(s, `mac:${mac.id}`, "relay", { t: "register", socket: b.socket, account: mac.db.account!, hostId: mac.hostId, label: mac.name }, "axo.host.register");
      return `${mac.name} is connected and registers itself`;
    case "refused":
      if (mac.socket !== b.socket) return `${mac.name} ignored an old refusal`;
      cancelTimers(s, mac, (t) => t.body.t === "connect.timeout");
      Object.assign(mac, { socket: null, state: "disconnected", lastError: `HTTP ${b.status}: ${b.reason}` } satisfies Partial<Mac>);
      const wait = mac.retryDelay;
      backoff(s, mac);
      return `${mac.name} was refused (${b.status}); it retries in ${wait / 1000}s, then waits twice as long each time (at most ${MAX_RETRY / 1000}s)`;
    case "close":
      if (mac.socket !== b.socket) return `${mac.name} ignored a close for an old connection`;
      Object.assign(mac, { socket: null, socketOpen: false, state: "disconnected", lastError: `relay closed the connection: ${b.reason}` } satisfies Partial<Mac>);
      scheduleRetry(s, mac, mac.retryDelay);
      return `${mac.name}'s connection was closed (${b.reason}); it will try again`;
    case "relay.input":
      mac.terminal.push(`$ ${b.text}    ← ${clientName(s, b.from)}`);
      timer(s, `mac:${mac.id}`, 80, { t: "command.done", text: b.text, from: b.from }, "the command finishes");
      return `${mac.name}'s shell runs "${b.text}"`;
    default:
      return `${mac.name} ignored an unexpected message`;
  }
}

function fire(s: Sim, t: Timer): string {
  const b = t.body;
  if (b.t === "code.expired") {
    const code = s.relay.codes.find((c) => c.code === b.code);
    return code && !code.usedBy ? `Code ${b.code} expired unused` : `Code ${b.code}'s lifetime ended (already used)`;
  }
  if (b.t === "heartbeat.lost") {
    const host = s.relay.accounts[b.account]?.hosts[b.hostId];
    if (!host || host.socket !== b.socket) return "A stale heartbeat check found nothing to do";
    dropHostSocket(s, host);
    return `The relay stopped hearing from ${host.label}; it shows as offline`;
  }
  const mac = macById(s, t.node.slice(4));
  switch (b.t) {
    case "retry":
      mac.retryTimer = null;
      return connect(s, mac);
    case "connect.timeout":
      if (mac.socket !== b.socket || mac.socketOpen) return "A stale timeout found nothing to do";
      Object.assign(mac, { socket: null, state: "disconnected", lastError: "timed out connecting to the relay" } satisfies Partial<Mac>);
      backoff(s, mac);
      return `${mac.name} gave up on that attempt and backs off`;
    case "redeem.timeout":
      if (mac.linkRequest !== b.req) return "A stale timeout found nothing to do";
      mac.linkRequest = null;
      mac.lastError = "could not link this Mac (no answer)";
      return `${mac.name} got no answer. It can't know if the relay got the code; the pending credential is kept so a retry is the same redemption`;
    case "socket.lost":
      if (mac.socket !== b.socket) return "A stale check found nothing to do";
      Object.assign(mac, { socket: null, socketOpen: false, state: "disconnected", lastError: "network is unreachable" } satisfies Partial<Mac>);
      scheduleRetry(s, mac, FIRST_RETRY);
      return `${mac.name} noticed its connection died. Its terminals keep running`;
    case "command.done": {
      const output = fakeOutput(b.text, mac);
      mac.terminal.push(output);
      if (b.from !== "local" && mac.socketOpen && mac.socket !== null && mac.db.account) {
        send(s, `mac:${mac.id}`, "relay", { t: "host.output", socket: mac.socket, account: mac.db.account, hostId: mac.hostId, text: output }, "output", "stream");
      } else if (mac.socketOpen && mac.socket !== null && mac.db.account) {
        send(s, `mac:${mac.id}`, "relay", { t: "host.output", socket: mac.socket, account: mac.db.account, hostId: mac.hostId, text: `$ ${b.text}\n${output}` }, "output", "stream");
      }
      return `${mac.name}'s shell printed its output`;
    }
  }
}

// ---------- Mac behaviour ----------

const CODE_SHAPE = /^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/;

function startLink(s: Sim, mac: Mac, rawCode: string) {
  const code = rawCode.trim().toUpperCase();
  if (!CODE_SHAPE.test(code)) {
    mac.lastError = "that isn't a pairing code";
    return;
  }
  if (mac.linkRequest !== null) {
    mac.lastError = "already linking; wait for the answer";
    return;
  }
  if (!mac.db.pending) {
    const credential = `cred-${hex(id(s) + 31)}`;
    mac.keychain.push(credential);
    mac.db.pending = credential;
  }
  const req = id(s);
  mac.linkRequest = req;
  send(s, `mac:${mac.id}`, "relay", {
    t: "redeem",
    req,
    code,
    hostId: mac.hostId,
    generation: mac.generation,
    credential: mac.db.pending,
    label: mac.name,
  }, `redeem ${code} + secret`);
  timer(s, `mac:${mac.id}`, HTTP_TIMEOUT, { t: "redeem.timeout", req }, "the link request times out");
}

function connect(s: Sim, mac: Mac): string {
  if (!mac.db.account || !mac.db.credential) {
    mac.state = "not linked";
    return `${mac.name} isn't linked, so it doesn't connect`;
  }
  if (mac.socket !== null) return `${mac.name} is already connecting`;
  const socket = id(s);
  Object.assign(mac, { socket, socketOpen: false, state: "connecting" } satisfies Partial<Mac>);
  send(s, `mac:${mac.id}`, "relay", { t: "connect", socket, account: mac.db.account, hostId: mac.hostId, credential: mac.db.credential }, "connect (Bearer secret)");
  timer(s, `mac:${mac.id}`, HTTP_TIMEOUT, { t: "connect.timeout", socket }, "the connection attempt times out");
  return `${mac.name} dials the relay with its credential`;
}

function scheduleRetry(s: Sim, mac: Mac, delay: Ms) {
  cancelRetry(s, mac);
  mac.retryTimer = timer(s, `mac:${mac.id}`, delay, { t: "retry" }, "axod tries to connect");
}

function backoff(s: Sim, mac: Mac) {
  scheduleRetry(s, mac, mac.retryDelay);
  mac.retryDelay = Math.min(mac.retryDelay * 2, MAX_RETRY);
}

function cancelRetry(s: Sim, mac: Mac) {
  cancelTimers(s, mac, (t) => t.body.t === "retry");
  mac.retryTimer = null;
}

function cancelTimers(s: Sim, mac: Mac, which: (t: Timer) => boolean) {
  s.timers = s.timers.filter((t) => !(t.node === `mac:${mac.id}` && which(t)));
}

function heartbeatLoss(s: Sim, mac: Mac) {
  if (mac.socket === null || !mac.db.account) return;
  timer(s, "relay", RELAY_NOTICES_LOSS, { t: "heartbeat.lost", account: mac.db.account, hostId: mac.hostId, socket: mac.socket }, `relay stops hearing from ${mac.name}`);
}

function fakeOutput(text: string, mac: Mac): string {
  const command = text.trim().split(/\s+/)[0];
  if (command === "ls") return "notes.md  src  todo.txt";
  if (command === "whoami") return "leo";
  if (command === "hostname") return mac.name;
  if (command === "date") return "Sun Oct 25 12:00:00 2026";
  return `${command}: done`;
}

// ---------- Relay helpers ----------

function accountFor(s: Sim, personId: string): Account {
  let accountId = s.relay.byPerson[personId];
  if (!accountId) {
    accountId = `acct-${personName(s, personId).toLowerCase()}`;
    s.relay.byPerson[personId] = accountId;
    s.relay.accounts[accountId] = { id: accountId, person: personId, hosts: {} };
  }
  return s.relay.accounts[accountId]!;
}

function statusOf(host: HostRecord): HostStatus {
  return host.revoked ? "revoked" : host.socket !== null && host.registered ? "online" : "offline";
}

function hostSummaries(account: Account) {
  return Object.values(account.hosts).map((h) => ({ hostId: h.hostId, label: h.label, status: statusOf(h) }));
}

function dropHostSocket(s: Sim, host: HostRecord) {
  host.socket = null;
  host.registered = false;
  broadcast(s, host, { t: "host.status", hostId: host.hostId, status: statusOf(host) }, `Mac ${statusOf(host)}`, "refused");
}

function broadcast(s: Sim, host: HostRecord, body: Body, label: string, tone: Tone = "reply") {
  for (const viewer of host.clients) send(s, "relay", `client:${viewer}`, body, label, tone);
}

function detachEverywhere(s: Sim, clientId: string) {
  for (const account of Object.values(s.relay.accounts)) {
    for (const host of Object.values(account.hosts)) host.clients = host.clients.filter((c) => c !== clientId);
  }
}

function setClientHostStatus(client: Client, hostId: string, status: HostStatus) {
  if (!client.hosts) return;
  client.hosts = client.hosts.map((h) => (h.hostId === hostId ? { ...h, status } : h));
}

function newCode(s: Sim): string {
  const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
  let n = id(s) * 7919 + 104729;
  let out = "";
  for (let i = 0; i < 8; i++) {
    out += alphabet[n % 32];
    n = Math.floor(n / 32) + i * 977 + 13;
    if (i === 3) out += "-";
  }
  return out;
}

// ---------- Plumbing ----------

function id(s: Sim): number {
  return s.nextId++;
}

function latency(node: NodeId): Ms {
  if (node === "access") return LATENCY.access;
  if (node === "relay") return LATENCY.access;
  return node.startsWith("mac:") ? LATENCY.mac : LATENCY.client;
}

function send(s: Sim, from: NodeId, to: NodeId, body: Body, label: string, tone: Tone = "request") {
  const mac = from.startsWith("mac:") ? macById(s, from.slice(4)) : null;
  s.packets.push({
    id: id(s),
    from,
    to,
    body,
    label,
    tone,
    sentAt: s.now,
    arriveAt: s.now + Math.max(latency(from), latency(to)),
    lost: mac ? !mac.online || !mac.running : false,
  });
}

function request(s: Sim, client: Client, req: ClientRequest) {
  const label = req.t === "input" ? req.text : req.t;
  send(s, `client:${client.id}`, "access", { t: "request", req }, label, req.t === "input" ? "stream" : "request");
}

function timer(s: Sim, node: NodeId, delay: Ms, body: TimerBody, label: string): number {
  const timerId = id(s);
  s.timers.push({ id: timerId, at: s.now + delay, node, body, label });
  return timerId;
}

function act(sim: Sim, title: string, change: (s: Sim) => void): Sim {
  const s = structuredClone(sim);
  const before = snapshot(s);
  change(s);
  record(s, "you", title, "action", before);
  return s;
}

function record(s: Sim, node: LogEntry["node"], title: string, tone: LogEntry["tone"], before: Record<string, string>) {
  const after = snapshot(s);
  const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
  const changes: Change[] = [];
  for (const key of keys) {
    if (before[key] !== after[key]) changes.push({ key, before: before[key] ?? "—", after: after[key] ?? "—" });
  }
  s.log.unshift({ id: id(s), at: s.now, node, title, tone, changes });
  if (s.log.length > 300) s.log.length = 300;
}

/** The state worth diffing, flattened to readable keys. */
function snapshot(s: Sim): Record<string, string> {
  const out: Record<string, string> = {};
  for (const m of s.macs) {
    out[`${m.name} · host_link.account`] = m.db.account ?? "—";
    out[`${m.name} · host_link.credential`] = m.db.credential ?? "—";
    out[`${m.name} · host_link.pending`] = m.db.pending ?? "—";
    out[`${m.name} · Keychain`] = m.keychain.join(", ") || "empty";
    out[`${m.name} · status`] = m.state;
    out[`${m.name} · Wi-Fi`] = m.online ? "on" : "off";
    if (m.lastError) out[`${m.name} · last error`] = m.lastError;
  }
  for (const c of s.clients) {
    out[`${c.name} · signed in as`] = c.signedInAs ? personName(s, c.signedInAs) : "—";
    out[`${c.name} · watching`] = c.attached ? hostLabel(s, c.attached) : "—";
  }
  for (const [clientId, person] of Object.entries(s.access.sessions)) {
    out[`Access · session for ${clientName(s, clientId)}`] = personName(s, person);
  }
  for (const account of Object.values(s.relay.accounts)) {
    out[`Relay · ${account.id}`] = "exists";
    for (const h of Object.values(account.hosts)) {
      out[`Relay · ${account.id} · ${h.label}`] = `${statusOf(h)}, verifier(${h.credential})`;
      if (h.clients.length) out[`Relay · ${account.id} · ${h.label} · viewers`] = h.clients.map((c) => clientName(s, c)).join(", ");
    }
  }
  for (const c of s.relay.codes) {
    out[`Relay · code ${c.code}`] = c.usedBy ? "used" : c.expiresAt <= s.now ? "expired" : "valid";
  }
  return out;
}

// ---------- Lookups ----------

export function macById(s: Sim, macId: string): Mac {
  return s.macs.find((m) => m.id === macId)!;
}
export function clientById(s: Sim, clientId: string): Client {
  return s.clients.find((c) => c.id === clientId)!;
}
export function personName(s: Sim, personId: string): string {
  return s.people.find((p) => p.id === personId)?.name ?? personId;
}
export function clientName(s: Sim, clientId: string): string {
  return s.clients.find((c) => c.id === clientId)?.name ?? clientId;
}
export function macName(s: Sim, macId: string): string {
  return s.macs.find((m) => m.id === macId)?.name ?? macId;
}
export function hostLabel(s: Sim, hostId: string): string {
  return s.macs.find((m) => m.hostId === hostId)?.name ?? hostId;
}
export function accountName(s: Sim, accountId: string): string {
  return accountId;
}
export function nodeName(s: Sim, node: NodeId | "you"): string {
  if (node === "you") return "You";
  if (node === "access") return "Cloudflare Access";
  if (node === "relay") return "Axo relay";
  return node.startsWith("mac:") ? macName(s, node.slice(4)) : clientName(s, node.slice(7));
}
export function hostStatus(host: HostRecord): HostStatus {
  return statusOf(host);
}

// ---------- Presets ----------

export type Preset = { id: string; name: string; build: () => Sim };

const person = (s: Sim, name: string) => s.people.find((p) => p.name === name)!.id;
const mac = (s: Sim, name: string) => s.macs.find((m) => m.name === name)!.id;
const client = (s: Sim, name: string) => s.clients.find((c) => c.name === name)!.id;

function linkWith(s: Sim, clientNameValue: string, macNameValue: string): Sim {
  let sim = settle(clientActions.createCode(s, client(s, clientNameValue)));
  const shown = clientById(sim, client(sim, clientNameValue)).codes.at(-1)!;
  sim = settle(macActions.link(sim, mac(sim, macNameValue), shown.code));
  return sim;
}

function quiet(sim: Sim): Sim {
  return { ...sim, log: [] };
}

export const presets: Preset[] = [
  {
    id: "fresh",
    name: "Fresh start",
    build: () => {
      let s = addPerson(emptySim(), "Alice");
      s = addPerson(s, "Bob");
      s = addClient(s, "phone", person(s, "Alice"));
      s = addMac(s, "Studio");
      return quiet(s);
    },
  },
  {
    id: "linked",
    name: "Alice has a linked Mac",
    build: () => {
      let s = addPerson(emptySim(), "Alice");
      s = addPerson(s, "Bob");
      s = addClient(s, "phone", person(s, "Alice"));
      s = addMac(s, "Studio");
      s = settle(clientActions.signIn(s, client(s, "Alice's phone"), person(s, "Alice")));
      s = linkWith(s, "Alice's phone", "Studio");
      return quiet(settle(s));
    },
  },
  {
    id: "family",
    name: "Two people, three Macs",
    build: () => {
      let s = addPerson(emptySim(), "Alice");
      s = addPerson(s, "Bob");
      s = addClient(s, "phone", person(s, "Alice"));
      s = addClient(s, "browser", person(s, "Alice"));
      s = addClient(s, "phone", person(s, "Bob"));
      s = addMac(s, "Studio");
      s = addMac(s, "MacBook");
      s = addMac(s, "Bob's iMac");
      s = settle(clientActions.signIn(s, client(s, "Alice's phone"), person(s, "Alice")));
      s = settle(clientActions.signIn(s, client(s, "Bob's phone"), person(s, "Bob")));
      s = linkWith(s, "Alice's phone", "Studio");
      s = linkWith(s, "Alice's phone", "MacBook");
      s = linkWith(s, "Bob's phone", "Bob's iMac");
      s = settle(clientActions.listHosts(s, client(s, "Alice's phone")));
      s = settle(clientActions.listHosts(s, client(s, "Bob's phone")));
      return quiet(settle(s));
    },
  },
];
