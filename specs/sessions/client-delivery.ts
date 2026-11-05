import { atMost, budget, defineActor, defineCall, defineLimit, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone, failed, FAULT, listOf, lose, nullable, oneOf, spend } from "@leostera/feynman";

// RFD0018, Delivery: a client holds one socket to its own ClientDO, which reads the Session from
// the SessionDO at the client's pace and hears about new records through notices from the HostDO.
//
// One Session, at most three records, one browser tab. Uploads from axod are stood in for by the
// HostDO's actions (session-sync.ts models them): a record committed, a progress snapshot, a
// truncate after a divergence, the Mac going offline. Batches are one record and the opening window
// is the last two. Records are named by epoch and position ("1.2"), so a record from before a
// truncate can never pass for one after it.
//
// RFD0031: no Durable Object wakes itself. The ClientDO subscribes once, on hello, and stays
// subscribed until the socket closes; a call that fails is retried at once, while the object is
// awake. A WebSocket never loses one frame and carries on: a lost frame is the socket dropping,
// which both ends see, and the tab reconnects. Progress goes only to a ClientDO watching the
// Session. A notice here carries the whole state (head, epoch, progress), so a follower marked
// behind, which gets the whole index in the code, is the same as any other here.
//
// Not modelled: several hosts, Sessions or tabs; the index of Sessions beyond the one head;
// batching of notices (a notice here is sent at once); metadata and status; resending a batch
// outstanding past SYNC.stallMs, which only a socket that drops can cause, and that reconnecting
// heals.

const MAX_RECORDS = 3;
const WINDOW = 2;

type Rec = { cursor: number; line: string };
type Open = { epoch: number; sent: number; acked: number; older: number; outstanding: number } | null;

function line(epoch: number, cursor: number): string {
  return `${epoch}.${cursor}`;
}

/** Faults on one path: lost messages and crashes (RFD0012). `--set faults=2` raises it. */
const faults = budget("faults", 1);

/** RFD0031: nothing renews; a call that fails is made again at once, while the object is awake. */
const retryAtOnce = defineRule("retryAtOnce", { description: "A notice, subscription, watch or read that fails is made again at once by the object that saw it fail." });

const Hello = defineMessage("Hello", {}, { name: "axo.client.hello", over: "websocket" });
const Welcome = defineMessage("Welcome", {}, { name: "hosts and Sessions", over: "websocket", tone: "reply" });
const Open = defineMessage("Open", { have: nullable({ epoch: Number, cursor: Number }) }, { name: "axo.client.session.open", over: "websocket" });
const Opened = defineMessage("Opened", { epoch: Number, records: listOf({ cursor: Number, line: String }), cursor: Number, older: Number, progress: nullable(String) }, { name: "the window", over: "websocket", tone: "reply" });
const Records = defineMessage("Records", { epoch: Number, records: listOf({ cursor: Number, line: String }), cursor: Number }, { name: "axo.client.session.records", over: "websocket", tone: "stream" });
const Ack = defineMessage("Ack", { cursor: Number }, { name: "axo.client.session.ack", over: "websocket" });
const Older = defineMessage("Older", { before: Number }, { name: "axo.client.session.older", over: "websocket" });
const OlderPage = defineMessage("OlderPage", { epoch: Number, records: listOf({ cursor: Number, line: String }), older: Number }, { name: "older records", over: "websocket", tone: "reply" });
const Progress = defineMessage("Progress", { snapshot: nullable(String) }, { name: "axo.client.session.progress", over: "websocket", tone: "stream" });
const Reset = defineMessage("Reset", { epoch: Number, keep: Number }, { name: "axo.client.session.reset", over: "websocket", tone: "stream" });
const Command = defineMessage("Command", {}, { name: "axo.client.command (prompt)", over: "websocket" });
const Accepted = defineMessage("Accepted", {}, { name: "prompt accepted", over: "websocket", tone: "reply" });
const Offline = defineMessage("Offline", {}, { name: "host offline", over: "websocket", tone: "refused" });
const MayHaveRun = defineMessage("MayHaveRun", {}, { name: "may have run; check the transcript", over: "websocket", tone: "refused" });
const Bye = defineMessage("Bye", {}, { name: "socket closed", over: "websocket" });
const Subscribe = defineCall("Subscribe", {}, { name: "HostDO.subscribe", over: "rpc" });
const Subscribed = defineMessage("Subscribed", { head: Number, epoch: Number, progress: nullable(String) }, { name: "the host's index", over: "rpc", tone: "reply" });
const Unsubscribe = defineMessage("Unsubscribe", {}, { name: "HostDO.unsubscribe", over: "rpc" });
const Watch = defineCall("Watch", {}, { name: "HostDO.watch", over: "rpc" });
const Watching = defineMessage("Watching", { progress: nullable(String) }, { name: "the Session's progress", over: "rpc", tone: "reply" });
const Closed = defineMessage("Closed", {}, { name: "the socket dropped", over: "websocket", tone: "refused" });
const Notify = defineCall("Notify", { head: Number, epoch: Number, progress: nullable(String) }, { name: "ClientDO.notify", over: "rpc" });
const Noted = defineMessage("Noted", {}, { name: "noted", over: "rpc", tone: "reply" });
const Read = defineCall("Read", { id: Number, kind: oneOf("open", "live", "older"), after: Number, before: Number, epoch: Number }, { name: "SessionDO.read", over: "rpc" });
const ReadResult = defineMessage("ReadResult", { id: Number, kind: oneOf("open", "live", "older"), epoch: Number, records: listOf({ cursor: Number, line: String }), head: Number }, { name: "records", over: "rpc", tone: "reply" });
const ReadReset = defineMessage("ReadReset", { id: Number, kind: oneOf("open", "live", "older"), epoch: Number, keep: Number }, { name: "the epoch moved", over: "rpc", tone: "refused" });
const Forward = defineCall("Forward", {}, { name: "HostDO.command", over: "rpc" });
const Forwarded = defineMessage("Forwarded", {}, { name: "axod accepted", over: "rpc", tone: "reply" });
const HostOffline = defineMessage("HostOffline", {}, { name: "host offline", over: "rpc", tone: "refused" });
const Commit = defineCall("Commit", { line: String }, { name: "SessionDO.append", over: "rpc" });
const Committed = defineMessage("Committed", { head: Number, epoch: Number }, { name: "committed", over: "rpc", tone: "reply" });
const Head = defineCall("Head", {}, { name: "SessionDO.head", over: "rpc" });
const HeadIs = defineMessage("HeadIs", { head: Number, epoch: Number }, { name: "head", over: "rpc", tone: "reply" });
const Cut = defineCall("Cut", { keep: Number }, { name: "SessionDO.truncate", over: "rpc" });
const CutDone = defineMessage("CutDone", { head: Number, epoch: Number }, { name: "truncated", over: "rpc", tone: "reply" });


const clientZone = defineZone({ name: "Client", description: "a browser tab", place: { column: 0 } });
const edge = defineZone({ name: "Cloudflare", description: "one ClientDO per tab, one HostDO per host, one SessionDO per Session", place: { column: 1, region: true } });

const limit1 = defineLimit({ name: "Records per batch to a client", value: 64, unit: "records" });
const limit2 = defineLimit({ name: "A batch counts as stalled after", value: 30, unit: "seconds" });
const limit4 = defineLimit({ name: "Opening window", value: 20, unit: "records" });

export const Tab = defineActor({
  name: "Browser tab",
  description: "The web app in one tab: one socket to its ClientDO, the records it holds, and a prompt box.",
  zone: clientZone,
  singleton: true,
  initialState: () => ({
    connected: false,
    welcomed: false,
    opened: false,
    epoch: 0,
    /** The records it holds, by cursor. */
    records: [] as Rec[],
    older: 0,
    /** The last cursor it acknowledged. */
    acked: 0,
    /** A batch arrived that it hasn't acknowledged yet (a resent batch is acknowledged again). */
    needsAck: false,
    progress: null as string | null,
    /** A slow or backgrounded tab that stops acknowledging. */
    stalled: false,
    prompt: "none" as "none" | "sending" | "accepted" | "offline" | "unknown",
    /** The network dropped the socket; the web app reconnects by itself. */
    dropped: false,
  }),
  display: {
    icon: "browser",
    status: (s) => (!s.connected ? "closed" : !s.opened ? "connected" : `${s.records.length} record(s)${s.progress ? ", a reply streaming" : ""}${s.stalled ? ", stalled" : ""}`),
    mood: (s) => (!s.connected ? "off" : s.stalled ? "warn" : "ok"),
    rows: (s) => [
      ...s.records.map((r) => ({ label: `${r.cursor}`, detail: r.line })),
      ...(s.progress ? [{ label: "streaming", detail: s.progress, mood: "busy" as const }] : []),
      ...(s.prompt !== "none" ? [{ label: "prompt", detail: s.prompt, mood: s.prompt === "accepted" ? ("ok" as const) : ("warn" as const) }] : []),
    ],
  },
  links: (s) => (s.connected ? [{ to: "ClientDO", kind: "websocket" }] : []),
  actions: {
    connect: {
      with: [atMost(2)],
      label: "Open the web app",
      description: "Opens the tab's one socket and says hello.",
      when: (s) => !s.connected,
      sends: [Hello],
      run(state, _i, ctx) {
        connect(state, ctx);
      },
    },
    open: {
      with: [atMost(2)],
      label: "Open the Session",
      description: "Opens the Session: the last few records, or what follows the ones it already holds.",
      when: (s) => s.welcomed && !s.opened,
      sends: [Open],
      run(state, _i, ctx) {
        const last = state.records.at(-1);
        ctx.send(ctx.the(ClientDO), Open, { have: last ? { epoch: state.epoch, cursor: last.cursor } : null });
      },
    },
    scrollUp: {
      with: [atMost(2)],
      label: "Scroll up",
      description: "Asks for the records before the oldest it holds.",
      when: (s) => s.opened && s.older > 0,
      sends: [Older],
      run(state, _i, ctx) {
        ctx.send(ctx.the(ClientDO), Older, { before: state.records[0]?.cursor ?? state.older + 1 });
      },
    },
    stall: {
      with: [atMost(2)],
      label: "Background the tab",
      description: "The tab stops processing, so it stops acknowledging.",
      when: (s) => s.opened && !s.stalled,
      run: (state) => void (state.stalled = true),
    },
    resume: {
      with: [atMost(2)],
      label: "Bring the tab back",
      description: "The tab processes again.",
      when: (s) => s.stalled,
      run: (state) => void (state.stalled = false),
    },
    prompt: {
      with: [atMost(2)],
      label: "Send a prompt",
      description: "Sends a prompt to the Session's agent on the Mac.",
      when: (s) => s.opened && s.prompt !== "sending",
      sends: [Command],
      starts: ["commandTimeout"],
      run(state, _i, ctx) {
        state.prompt = "sending";
        ctx.send(ctx.the(ClientDO), Command, {});
        ctx.start("commandTimeout");
      },
    },
    close: {
      with: [atMost(2)],
      label: "Close the socket",
      description: "The network drops or the tab closes. What the tab holds stays in memory for the next connect.",
      when: (s) => s.connected,
      sends: [Bye],
      run(state, _i, ctx) {
        state.connected = false;
        state.welcomed = false;
        state.opened = false;
        if (state.prompt === "sending") state.prompt = "unknown";
        ctx.cancel("commandTimeout");
        ctx.send(ctx.the(ClientDO), Bye, {});
      },
    },
  },
  transitions: {
    welcome: { on: Welcome, description: "Sees its hosts and Sessions.", run: (s) => void (s.welcomed = s.connected) },
    opened: {
      on: Opened,
      description: "Shows the window: the records after the ones it held in this epoch, or a fresh window.",
      run(state, msg) {
        if (!state.connected) return;
        if (msg.epoch !== state.epoch) state.records = [];
        state.epoch = msg.epoch;
        for (const r of msg.records) if (!state.records.some((x) => x.cursor === r.cursor)) state.records.push(r);
        state.records.sort((a, b) => a.cursor - b.cursor);
        state.older = state.records.length ? state.records[0]!.cursor - 1 : msg.older;
        state.acked = msg.cursor;
        state.progress = msg.progress;
        state.opened = true;
      },
    },
    records: {
      on: Records,
      description: "Adds new records at the end.",
      run(state, msg) {
        if (!state.opened || msg.epoch !== state.epoch) return;
        for (const r of msg.records) if (!state.records.some((x) => x.cursor === r.cursor)) state.records.push(r);
        state.needsAck = true;
      },
    },
    ack: {
      description: "Acknowledges the records it has processed, unless the tab is stalled.",
      when: (s) => s.connected && s.opened && !s.stalled && s.needsAck && s.records.length > 0,
      sends: [Ack],
      run(state, _, ctx) {
        state.needsAck = false;
        state.acked = state.records.at(-1)!.cursor;
        ctx.send(ctx.the(ClientDO), Ack, { cursor: state.acked });
      },
    },
    olderPage: {
      on: OlderPage,
      description: "Adds older records at the top.",
      run(state, msg) {
        if (!state.opened || msg.epoch !== state.epoch) return;
        for (const r of msg.records) if (!state.records.some((x) => x.cursor === r.cursor)) state.records.unshift(r);
        state.records.sort((a, b) => a.cursor - b.cursor);
        state.older = msg.older;
      },
    },
    progress: { on: Progress, description: "Shows the newest snapshot of the reply being written.", run: (s, msg) => void (s.opened && (s.progress = msg.snapshot)) },
    reset: {
      on: Reset,
      description: "The Session was cut back: drops the records past the common prefix and continues in the new epoch.",
      run(state, msg) {
        if (!state.opened) return;
        state.records = state.records.filter((r) => r.cursor <= msg.keep);
        state.epoch = msg.epoch;
        state.acked = Math.min(state.acked, msg.keep);
        state.older = state.records.length ? state.records[0]!.cursor - 1 : Math.min(state.older, msg.keep);
      },
    },
    accepted: { on: Accepted, description: "The prompt reached the agent; it shows as pending until its record arrives.", run: (s, _m, ctx) => void (s.prompt === "sending" && ((s.prompt = "accepted"), ctx.cancel("commandTimeout"))) },
    offline: { on: Offline, description: "The Mac is offline: the text stays in the box.", run: (s, _m, ctx) => void (s.prompt === "sending" && ((s.prompt = "offline"), ctx.cancel("commandTimeout"))) },
    mayHaveRun: { on: MayHaveRun, description: "The prompt may or may not have reached the Mac; the transcript will say.", run: (s, _m, ctx) => void (s.prompt === "sending" && ((s.prompt = "unknown"), ctx.cancel("commandTimeout"))) },
    commandTimeout: {
      description: "No answer in time: the prompt may or may not have reached the Mac; the transcript will say.",
      after: "10 seconds",
      run: (s) => void (s.prompt === "sending" && (s.prompt = "unknown")),
    },
    closed: {
      on: Closed,
      description: "The socket dropped on the ClientDO's side: the tab sees it close.",
      run: (state, _m, ctx) => dropped(state, ctx, false),
    },
    reconnect: {
      description: "The socket dropped: the web app connects again by itself and says hello.",
      when: (s) => s.dropped && !s.connected,
      sends: [Hello],
      run: (state, _m, ctx) => connect(state, ctx),
    },
    // Faults: a frame lost on its way to the tab is the socket dropping (RFD0031).
    welcomeLost: drops(Welcome),
    openedLost: drops(Opened),
    recordsLost: drops(Records),
    olderPageLost: drops(OlderPage),
    progressLost: drops(Progress),
    resetLost: drops(Reset),
    acceptedLost: drops(Accepted),
    offlineLost: drops(Offline),
    mayHaveRunLost: drops(MayHaveRun),
  },
});

function connect(state: any, ctx: any): void {
  state.connected = true;
  state.welcomed = false;
  state.dropped = false;
  ctx.send(ctx.the(ClientDO), Hello, {});
}
/** The socket closed under the tab: what it holds stays in memory for the reconnect. */
function dropped(state: any, ctx: any, tellClientDO: boolean): void {
  if (!state.connected) return;
  state.connected = false;
  state.welcomed = false;
  state.opened = false;
  state.dropped = true;
  if (state.prompt === "sending") state.prompt = "unknown";
  ctx.cancel("commandTimeout");
  if (tellClientDO) ctx.send(ctx.the(ClientDO), Bye, {});
}
/** A frame to the tab is lost: the socket drops, and both ends see it close. */
function drops(message: any) {
  return {
    on: message,
    fair: false as const,
    tags: [FAULT],
    with: [spend(faults)],
    sends: [Bye],
    description: `${message.name} is lost: the socket drops, and both ends see it close.`,
    run: (state: any, _m: unknown, ctx: any) => dropped(state, ctx, true),
  };
}

export const ClientDO = defineActor({
  name: "ClientDO",
  description: "The tab's Durable Object: it holds the tab's socket, follows the host, and reads the Session at the tab's pace.",
  zone: edge,
  singleton: true,
  initialState: () => ({
    socket: false,
    subscribed: false,
    /** The head and epoch the host last reported. */
    head: 0,
    epoch: 1,
    open: null as Open,
    /** A live read is in flight; at most one at a time. */
    reading: false,
    /** Reads issued so far; only the newest open or live read's answer counts. */
    reads: 0,
    /** The Open request waits for its first read. */
    opening: false,
    /** The host reported a newer epoch than the open Session's: the next read finds out what still stands. */
    stale: false,
    progress: null as string | null,
  }),
  display: {
    icon: "server",
    status: (s) => (!s.socket ? "no socket" : !s.open ? "following the host" : `sent ${s.open.sent}, acked ${s.open.acked} of ${s.head}`),
    mood: (s) => (!s.socket ? "off" : s.open && s.open.sent > s.open.acked ? "busy" : "ok"),
  },
  links: (s) => (s.subscribed ? [{ to: "HostDO", kind: "lease", style: "dotted" }] : []),
  actions: {},
  transitions: {
    hello: {
      on: Hello,
      description: "Takes the socket and subscribes to the host, once: the subscription lasts as long as the socket.",
      sends: [Subscribe, Welcome],
      run(state, _msg, ctx) {
        state.socket = true;
        state.open = null;
        state.opening = false;
        ctx.send(ctx.the(HostDO), Subscribe, {});
        ctx.reply(Welcome, {});
      },
    },
    subscribed: {
      on: Subscribed,
      description: "Learns the host's current head, epoch and progress, and catches the tab up if it is behind.",
      sends: [Read, Reset, Progress],
      run(state, msg, ctx) {
        if (!state.socket) return;
        state.subscribed = true;
        heard(state, msg, ctx);
      },
    },
    subscribeFailed: {
      on: failed(Subscribe),
      description: "The subscription call threw: it is tried again at once, while the ClientDO is awake.",
      sends: [Subscribe],
      run(state, _f, ctx) {
        state.subscribed = false;
        if (retryAtOnce.on && state.socket) ctx.send(ctx.the(HostDO), Subscribe, {});
      },
    },
    watching: {
      on: Watching,
      description: "The host has noted the open Session, and says what it is writing now.",
      sends: [Progress],
      run(state, msg, ctx) {
        if (!state.socket || !state.open) return;
        if (msg.progress !== state.progress) {
          state.progress = msg.progress;
          if (!state.opening) ctx.send(ctx.the(Tab), Progress, { snapshot: msg.progress });
        }
      },
    },
    watchFailed: {
      on: failed(Watch),
      description: "The watch call threw: it is tried again at once.",
      sends: [Watch],
      run: (state, _f, ctx) => void (retryAtOnce.on && state.socket && state.open && ctx.send(ctx.the(HostDO), Watch, {})),
    },
    notify: {
      on: Notify,
      description: "A notice from the host: a new head, a new epoch, or a progress snapshot.",
      sends: [Noted, Read, Reset, Progress],
      run(state, msg, ctx) {
        ctx.reply(Noted, {});
        if (state.socket) heard(state, msg, ctx);
      },
    },
    open: {
      on: Open,
      description: "Opens the Session for the tab: watches it on the host, and reads what follows its cursor in the same epoch, or the last records.",
      sends: [Read, Watch],
      run(state, msg, ctx) {
        if (!state.socket) return;
        const have = msg.have && msg.have.epoch === state.epoch ? msg.have.cursor : null;
        const after = have ?? Math.max(0, state.head - WINDOW);
        state.open = { epoch: state.epoch, sent: after, acked: after, older: have === null ? after : 0, outstanding: 0 };
        state.stale = false;
        state.opening = true;
        state.reading = true;
        state.reads += 1;
        ctx.send(ctx.the(SessionDO), Read, { id: state.reads, kind: "open", after, before: 0, epoch: state.epoch });
        ctx.send(ctx.the(HostDO), Watch, {});
      },
    },
    readResult: {
      on: ReadResult,
      description: "Sends the records to the tab: the opening window, a live batch, or an older page.",
      sends: [Opened, Records, OlderPage, Read],
      run(state, msg, ctx) {
        if (msg.kind !== "older" && msg.id !== state.reads) return;
        if (msg.kind !== "older") state.reading = false;
        const open = state.open;
        if (!state.socket || !open || msg.epoch !== open.epoch) return;
        state.head = Math.max(state.head, msg.head);
        const tab = ctx.the(Tab);
        if (msg.kind === "older") {
          const first = msg.records[0]?.cursor ?? 1;
          return ctx.send(tab, OlderPage, { epoch: msg.epoch, records: msg.records, older: first - 1 });
        }
        const last = msg.records.at(-1)?.cursor ?? open.sent;
        if (msg.kind === "open") {
          state.opening = false;
          open.sent = last;
          open.acked = last;
          ctx.send(tab, Opened, { epoch: msg.epoch, records: msg.records, cursor: last, older: open.older, progress: state.progress });
          return deliver(state, ctx);
        }
        if (!msg.records.length) return deliver(state, ctx);
        open.sent = last;
        open.outstanding += 1;
        ctx.send(tab, Records, { epoch: msg.epoch, records: msg.records, cursor: last });
      },
    },
    readReset: {
      on: ReadReset,
      description: "The Session was cut back while reading: the tab is told to drop what follows the common prefix.",
      sends: [Reset, Read, Opened],
      run(state, msg, ctx) {
        if (msg.kind === "older" || msg.id !== state.reads) return;
        state.reading = false;
        if (!state.socket || !state.open) return;
        reset(state, msg.epoch, msg.keep, ctx);
      },
    },
    readFailed: {
      on: failed(Read),
      description: "A read threw: it is read again at once, while the ClientDO is awake.",
      sends: [Read],
      run(state, f, ctx) {
        if (f.payload.kind === "older" || f.payload.id !== state.reads) return;
        state.reading = false;
        if (!retryAtOnce.on || !state.socket || !state.open) return;
        if (f.payload.kind === "open") {
          state.reading = true;
          state.reads += 1;
          return ctx.send(ctx.the(SessionDO), Read, { ...f.payload, id: state.reads });
        }
        deliver(state, ctx);
      },
    },
    ack: {
      on: Ack,
      description: "The tab has processed records up to here: the next batch may go.",
      sends: [Read],
      run(state, msg, ctx) {
        const open = state.open;
        if (!open || msg.cursor < open.acked || msg.cursor > open.sent) return;
        open.acked = msg.cursor;
        if (open.acked === open.sent) open.outstanding = 0;
        deliver(state, ctx);
      },
    },
    older: {
      on: Older,
      description: "Reads a page of older records for the tab.",
      sends: [Read],
      run(state, msg, ctx) {
        if (!state.open) return;
        ctx.send(ctx.the(SessionDO), Read, { id: 0, kind: "older", after: 0, before: msg.before, epoch: state.open.epoch });
      },
    },
    command: {
      on: Command,
      description: "Forwards the tab's prompt to the host.",
      sends: [Forward],
      run: (_state, _msg, ctx) => ctx.send(ctx.the(HostDO), Forward, {}),
    },
    forwarded: { on: Forwarded, description: "Tells the tab the prompt was accepted.", sends: [Accepted], run: (s, _m, ctx) => void (s.socket && ctx.send(ctx.the(Tab), Accepted, {})) },
    hostOffline: { on: HostOffline, description: "Tells the tab the Mac is offline; nothing was stored.", sends: [Offline], run: (s, _m, ctx) => void (s.socket && ctx.send(ctx.the(Tab), Offline, {})) },
    forwardFailed: { on: failed(Forward), description: "The command call threw after it may have reached the Mac.", sends: [MayHaveRun], run: (s, _f, ctx) => void (s.socket && ctx.send(ctx.the(Tab), MayHaveRun, {})) },
    bye: {
      on: Bye,
      description: "The tab's socket closed: unsubscribe from the host and forget the open Session.",
      sends: [Unsubscribe],
      run(state, _msg, ctx) {
        state.socket = false;
        state.subscribed = false;
        state.open = null;
        state.opening = false;
        ctx.send(ctx.the(HostDO), Unsubscribe, {});
      },
    },
    // Faults: what the network and restarts may do here.
    // A frame from the tab is lost: the socket drops (RFD0031).
    helloLost: closes(Hello),
    openLost: closes(Open),
    ackLost: closes(Ack),
    olderLost: closes(Older),
    commandLost: closes(Command),
    subscribedLost: lose(Subscribed, { fails: Subscribe, spend: faults }),
    watchingLost: lose(Watching, { fails: Watch, spend: faults }),
    notifyLost: lose(Notify, { spend: faults }),
    readResultLost: lose(ReadResult, { fails: Read, spend: faults }),
    readResetLost: lose(ReadReset, { fails: Read, spend: faults }),
    forwardedLost: lose(Forwarded, { spend: faults }),
    hostOfflineLost: lose(HostOffline, { spend: faults }),
    byeLost: lose(Bye, { spend: faults }),
  },
});

/** A frame from the tab is lost: the socket drops; the ClientDO lets go and the tab sees it close. */
function closes(message: any) {
  return {
    on: message,
    fair: false as const,
    tags: [FAULT],
    with: [spend(faults)],
    sends: [Unsubscribe, Closed],
    description: `${message.name} is lost: the socket drops, and both ends see it close.`,
    run(state: any, _m: unknown, ctx: any) {
      if (!state.socket) return;
      state.socket = false;
      state.subscribed = false;
      state.open = null;
      state.opening = false;
      ctx.send(ctx.the(HostDO), Unsubscribe, {});
      ctx.send(ctx.the(Tab), Closed, {});
    },
  };
}

/** Takes in what the host reports: a new epoch resets the tab, progress is passed on, and a new head is read. */
function heard(state: any, msg: { head: number; epoch: number; progress: string | null }, ctx: any): void {
  if (msg.epoch < state.epoch) return;
  if (msg.epoch > state.epoch) {
    // The notice says the epoch moved, not where it was cut: the SessionDO says that, on the next read.
    state.epoch = msg.epoch;
    state.head = msg.head;
    state.stale = true;
  } else state.head = Math.max(state.head, msg.head);
  if (msg.progress !== state.progress) {
    state.progress = msg.progress;
    if (state.open && !state.opening) ctx.send(ctx.the(Tab), Progress, { snapshot: msg.progress });
  }
  deliver(state, ctx);
}
/** Reads the next batch when the tab has acknowledged everything sent and the host has more. */
function deliver(state: any, ctx: any): void {
  const open = state.open;
  if (!state.socket || !open || state.opening || state.reading) return;
  // A stale epoch is read even while a batch is outstanding, to learn the cut.
  if (!(state.stale && open.epoch < state.epoch) && (open.sent !== open.acked || open.sent >= state.head)) return;
  state.reading = true;
  state.reads += 1;
  ctx.send(ctx.the(SessionDO), Read, { id: state.reads, kind: "live", after: open.sent, before: 0, epoch: open.epoch });
}
function reset(state: any, epoch: number, keep: number, ctx: any): void {
  const open = state.open;
  state.stale = false;
  state.epoch = Math.max(state.epoch, epoch);
  open.epoch = epoch;
  open.sent = Math.min(open.sent, keep);
  open.acked = Math.min(open.acked, keep);
  open.older = Math.min(open.older, keep);
  open.outstanding = 0;
  if (state.opening) {
    // The tab hasn't seen anything yet: read the window again in the new epoch.
    state.reading = true;
    state.reads += 1;
    ctx.send(ctx.the(SessionDO), Read, { id: state.reads, kind: "open", after: open.sent, before: 0, epoch });
    return;
  }
  ctx.send(ctx.the(Tab), Reset, { epoch, keep });
  deliver(state, ctx);
}

export const HostDO = defineActor({
  name: "HostDO",
  description: "The host's Durable Object: it commits what axod uploads, keeps the latest progress, and notifies the ClientDOs holding a lease.",
  zone: edge,
  singleton: true,
  initialState: () => ({
    online: true,
    head: 0,
    epoch: 1,
    /** The snapshot of the reply being written, and the record it previews. */
    progress: null as { for: number; text: string } | null,
    subscriber: false,
    /** The subscribed ClientDO has the Session open: only then does progress go to it. */
    watching: false,
    /** A commit or truncate is waiting on the SessionDO. */
    busy: false,
    truncated: false,
  }),
  display: {
    icon: "cloud",
    status: (s) => `${s.online ? "Mac online" : "Mac offline"}, head ${s.head}, epoch ${s.epoch}`,
    mood: (s) => (s.online ? "ok" : "off"),
    rows: (s) => [
      ...(s.subscriber ? [{ label: "subscriber", detail: "the tab's ClientDO" }] : []),
      ...(s.progress ? [{ label: "progress", detail: s.progress.text, mood: "busy" as const }] : []),
    ],
  },
  actions: {
    commit: {
      with: [atMost(2)],
      label: "axod uploads a record",
      description: "A line from the Mac is committed to the SessionDO.",
      when: (s) => s.online && !s.busy && s.head < MAX_RECORDS,
      sends: [Commit],
      run(state, _i, ctx) {
        state.busy = true;
        ctx.send(ctx.the(SessionDO), Commit, { line: line(state.epoch, state.head + 1) });
      },
    },
    stream: {
      with: [atMost(2)],
      label: "axod sends progress",
      description: "A snapshot of the reply being written arrives; the newest replaces the last.",
      when: (s) => s.online && s.head < MAX_RECORDS && s.progress?.text !== "more",
      sends: [Notify],
      run(state, _i, ctx) {
        state.progress = { for: state.head + 1, text: state.progress ? "more" : "partial" };
        // Progress is for the ClientDOs watching the Session, not every follower.
        if (state.watching) notify(state, ctx);
      },
    },
    truncate: {
      with: [atMost(2)],
      label: "The Session diverged",
      description: "The handshake found a divergence; the SessionDO is cut back to its first record.",
      when: (s) => s.online && !s.busy && !s.truncated && s.head >= 2,
      sends: [Cut],
      run(state, _i, ctx) {
        state.busy = true;
        state.truncated = true;
        ctx.send(ctx.the(SessionDO), Cut, { keep: 1 });
      },
    },
    goOffline: {
      with: [atMost(2)],
      label: "The Mac goes offline",
      description: "axod's socket closes.",
      when: (s) => s.online,
      run(state) {
        state.online = false;
        state.progress = null;
      },
    },
    goOnline: { with: [atMost(2)], label: "The Mac comes back", description: "axod reconnects.", when: (s) => !s.online, run: (s) => void (s.online = true) },
  },
  transitions: {
    subscribe: {
      on: Subscribe,
      description: "Adds the ClientDO as a follower, until its socket closes, and answers with the current head and epoch.",
      sends: [Subscribed],
      run(state, _msg, ctx) {
        state.subscriber = true;
        ctx.reply(Subscribed, { head: state.head, epoch: state.epoch, progress: state.watching ? state.progress?.text ?? null : null });
      },
    },
    unsubscribe: {
      on: Unsubscribe,
      description: "The tab's socket closed: the ClientDO is no longer a follower, and watches nothing.",
      run(state) {
        state.subscriber = false;
        state.watching = false;
      },
    },
    watch: {
      on: Watch,
      description: "The ClientDO opened the Session: progress goes to it from now on, starting with the current snapshot.",
      sends: [Watching],
      run(state, _msg, ctx) {
        state.watching = true;
        ctx.reply(Watching, { progress: state.progress?.text ?? null });
      },
    },
    committed: {
      on: Committed,
      description: "The record is committed: the progress it completes is cleared, and subscribers hear the new head.",
      sends: [Notify],
      run(state, msg, ctx) {
        state.busy = false;
        if (msg.epoch !== state.epoch) return;
        state.head = msg.head;
        if (state.progress && state.progress.for <= msg.head) state.progress = null;
        notify(state, ctx);
      },
    },
    commitFailed: {
      on: failed(Commit),
      description: "The commit may or may not have happened: axod syncs again (session-sync.ts), and the handshake reads the SessionDO's head.",
      sends: [Head],
      run: (_state, _f, ctx) => ctx.send(ctx.the(SessionDO), Head, {}),
    },
    headIs: {
      on: HeadIs,
      description: "The index's head is refreshed from the SessionDO, and subscribers hear it.",
      sends: [Notify],
      run(state, msg, ctx) {
        state.busy = false;
        state.head = msg.head;
        state.epoch = msg.epoch;
        if (state.progress && state.progress.for <= msg.head) state.progress = null;
        notify(state, ctx);
      },
    },
    headFailed: {
      on: failed(Head),
      description: "The read threw: the handshake runs again.",
      sends: [Head],
      run: (_state, _f, ctx) => ctx.send(ctx.the(SessionDO), Head, {}),
    },
    cutDone: {
      on: CutDone,
      description: "The Session is cut back in a new epoch: subscribers hear the new epoch and head.",
      sends: [Notify],
      run(state, msg, ctx) {
        state.busy = false;
        state.epoch = msg.epoch;
        state.head = msg.head;
        state.progress = null;
        notify(state, ctx);
      },
    },
    cutFailed: { on: failed(Cut), description: "The truncate may or may not have happened; axod syncs again.", run: (state) => void ((state.busy = false), (state.truncated = false)) },
    noted: { on: Noted, description: "The ClientDO took the notice.", run: () => {} },
    notifyFailed: {
      on: failed(Notify),
      description: "The notice failed: it is sent again at once, with what the host knows now.",
      sends: [Notify],
      run: (state, _f, ctx) => void (retryAtOnce.on && notify(state, ctx)),
    },
    forward: {
      on: Forward,
      description: "Forwards the prompt to axod, or answers at once that the Mac is offline. Nothing is stored.",
      sends: [Forwarded, HostOffline],
      run(state, _msg, ctx) {
        ctx.reply(state.online ? Forwarded : HostOffline, {});
      },
    },
    // Faults: what the network and restarts may do here.
    subscribeLost: lose(Subscribe, { spend: faults }),
    watchLost: lose(Watch, { spend: faults }),
    unsubscribeLost: lose(Unsubscribe, { spend: faults }),
    committedLost: lose(Committed, { fails: Commit, spend: faults }),
    headIsLost: lose(HeadIs, { fails: Head, spend: faults }),
    cutDoneLost: lose(CutDone, { fails: Cut, spend: faults }),
    notedLost: lose(Noted, { fails: Notify, spend: faults }),
    forwardLost: lose(Forward, { spend: faults }),
  },
});

function notify(state: any, ctx: any): void {
  if (state.subscriber) ctx.send(ctx.the(ClientDO), Notify, { head: state.head, epoch: state.epoch, progress: state.watching ? state.progress?.text ?? null : null });
}

export const SessionDO = defineActor({
  name: "SessionDO",
  description: "The Session's Durable Object: its records by cursor, within an epoch.",
  zone: edge,
  singleton: true,
  initialState: () => ({
    epoch: 1,
    records: [] as string[],
    /** Where each truncate cut, by the epoch it started; a reader from an older epoch keeps only up to the lowest cut since. */
    cuts: [] as { epoch: number; keep: number }[],
  }),
  display: {
    icon: "database",
    status: (s) => `${s.records.length} record(s), epoch ${s.epoch}`,
    rows: (s) => s.records.map((l, i) => ({ group: `epoch ${s.epoch}`, label: `${i + 1}`, detail: l })),
  },
  transitions: {
    commit: {
      on: Commit,
      description: "Appends the record.",
      sends: [Committed],
      run(state, msg, ctx) {
        state.records.push(`${state.epoch}.${state.records.length + 1}`);
        void msg;
        ctx.reply(Committed, { head: state.records.length, epoch: state.epoch });
      },
    },
    read: {
      on: Read,
      description: "Returns one record after a cursor, or two before one; a reader from an older epoch is told the new epoch and how much of what it read still stands.",
      sends: [ReadResult, ReadReset],
      run(state, msg, ctx) {
        if (msg.epoch !== state.epoch) {
          const keep = Math.min(...state.cuts.filter((c) => c.epoch > msg.epoch).map((c) => c.keep));
          return ctx.reply(ReadReset, { id: msg.id, kind: msg.kind, epoch: state.epoch, keep });
        }
        const all = state.records.map((l, i) => ({ cursor: i + 1, line: l }));
        const records =
          msg.kind === "older"
            ? all.filter((r) => r.cursor < msg.before).slice(-WINDOW)
            : msg.kind === "open"
              ? all.filter((r) => r.cursor > msg.after)
              : all.filter((r) => r.cursor > msg.after).slice(0, 1);
        ctx.reply(ReadResult, { id: msg.id, kind: msg.kind, epoch: state.epoch, records, head: state.records.length });
      },
    },
    head: {
      on: Head,
      description: "Says how many records it holds, in which epoch.",
      sends: [HeadIs],
      run: (state, _msg, ctx) => ctx.reply(HeadIs, { head: state.records.length, epoch: state.epoch }),
    },
    cut: {
      on: Cut,
      description: "Deletes the records past the prefix and starts a new epoch.",
      sends: [CutDone],
      run(state, msg, ctx) {
        state.records = state.records.slice(0, msg.keep);
        state.epoch += 1;
        state.cuts.push({ epoch: state.epoch, keep: msg.keep });
        ctx.reply(CutDone, { head: state.records.length, epoch: state.epoch });
      },
    },
    // Faults: what the network and restarts may do here.
    commitLost: lose(Commit, { spend: faults }),
    readLost: lose(Read, { spend: faults }),
    headLost: lose(Head, { spend: faults }),
    cutLost: lose(Cut, { spend: faults }),
  },
});

const noGapsNoDuplicates = defineProperty("noGapsNoDuplicates", {
  description: "The records a tab holds are one contiguous run of cursors, with no gaps and no duplicates.",
  always: (w) => w.the(Tab).state.records.every((r, i, all) => i === 0 || r.cursor === all[i - 1]!.cursor + 1),
});
const holdsWhatTheCloudHolds = defineProperty("holdsWhatTheCloudHolds", {
  description: "Every record a tab holds in the Session's current epoch is the record the SessionDO holds at that cursor.",
  always: (w) => {
    const tab = w.the(Tab).state;
    const session = w.the(SessionDO).state;
    return tab.epoch !== session.epoch || tab.records.every((r) => session.records[r.cursor - 1] === r.line);
  },
});
const oneBatchOutstanding = defineProperty("oneBatchOutstanding", {
  description: "A ClientDO never has more than one batch of records waiting for the tab's acknowledgement.",
  always: (w) => (w.the(ClientDO).state.open?.outstanding ?? 0) <= 1,
});
const progressEndsWithItsRecord = defineProperty("progressEndsWithItsRecord", {
  description: "Once the record a snapshot previews is committed, no snapshot of it remains.",
  always: (w) => {
    const progress = w.the(HostDO).state.progress;
    return progress === null || progress.for > w.the(HostDO).state.head;
  },
});
const promptsAreAnswered = defineProperty("promptsAreAnswered", {
  description: "A prompt sent from a connected tab is answered: accepted, offline, or may have run. None waits forever.",
  leadsTo: { whenever: (w) => w.the(Tab).state.prompt === "sending", then: (w) => w.the(Tab).state.prompt !== "sending" },
});
const catchesUp = defineProperty("catchesUp", {
  needs: [retryAtOnce],
  description: "A connected tab that keeps acknowledging ends up holding every record up to the Session's head.",
  leadsTo: {
    whenever: (w) => {
      const tab = w.the(Tab).state;
      return tab.opened && !tab.stalled && (tab.records.at(-1)?.cursor ?? 0) < w.the(SessionDO).state.records.length;
    },
    then: (w) => {
      const tab = w.the(Tab).state;
      return !tab.opened || tab.stalled || (tab.epoch === w.the(SessionDO).state.epoch && (tab.records.at(-1)?.cursor ?? 0) === w.the(SessionDO).state.records.length);
    },
  },
});

const openingTheWebApp = defineScenario("Opening the web app", {
  description: "The tab says hello, opens the Session and gets its last two records; a new record follows once it acknowledges.",
  setup(w) {
    w.set(SessionDO, { records: ["1.1", "1.2"] });
    w.set(HostDO, { head: 2 });
  },
  run(s) {
    s.act(s.the(Tab), "connect");
    s.settle({ until: (w) => w.the(Tab).state.welcomed });
    s.act(s.the(Tab), "open");
    s.settle({ until: (w) => w.the(Tab).state.opened });
    s.act(s.the(HostDO), "commit");
    s.settle({ until: (w) => w.the(Tab).state.records.length === 3 && w.the(ClientDO).state.open?.acked === 3 });
  },
});
const aReplyStreamsIn = defineScenario("A reply streams in", {
  description: "Progress snapshots reach the open tab; when the record lands, it replaces them.",
  setup(w) {
    w.set(SessionDO, { records: ["1.1"] });
    w.set(HostDO, { head: 1 });
  },
  run(s) {
    s.act(s.the(Tab), "connect");
    s.settle({ until: (w) => w.the(Tab).state.welcomed });
    s.act(s.the(Tab), "open");
    s.settle({ until: (w) => w.the(Tab).state.opened });
    s.act(s.the(HostDO), "stream");
    s.act(s.the(HostDO), "stream");
    s.settle({ until: (w) => w.the(Tab).state.progress === "more" });
    s.act(s.the(HostDO), "commit");
    s.settle({ until: (w) => w.the(Tab).state.records.length === 2 && w.the(Tab).state.progress === null });
  },
});
const aBackgroundedTab = defineScenario("A backgrounded tab", {
  description: "The tab stops acknowledging: it gets one batch and no more, keeps its socket, and catches up when it comes back.",
  setup(w) {
    w.set(SessionDO, { records: ["1.1"] });
    w.set(HostDO, { head: 1 });
  },
  run(s) {
    s.act(s.the(Tab), "connect");
    s.settle({ until: (w) => w.the(Tab).state.welcomed });
    s.act(s.the(Tab), "open");
    s.settle({ until: (w) => w.the(Tab).state.opened });
    s.act(s.the(Tab), "stall");
    s.act(s.the(HostDO), "commit");
    s.settle({ until: (w) => w.the(HostDO).state.head === 2 && !w.the(HostDO).state.busy });
    s.act(s.the(HostDO), "commit");
    s.settle({ until: (w) => w.the(HostDO).state.head === 3 && w.the(Tab).state.records.length === 2 });
    s.act(s.the(Tab), "resume");
    s.settle({ until: (w) => w.the(Tab).state.records.length === 3 && w.the(ClientDO).state.open?.acked === 3 });
  },
});
const reconnectingWithRecordsInHand = defineScenario("Reconnecting with records in hand", {
  description: "The socket drops and comes back; the tab says which records it has and receives only the rest.",
  setup(w) {
    w.set(SessionDO, { records: ["1.1", "1.2", "1.3"] });
    w.set(HostDO, { head: 3 });
    w.set(Tab, { records: [{ cursor: 1, line: "1.1" }, { cursor: 2, line: "1.2" }], epoch: 1, acked: 2 });
  },
  run(s) {
    s.act(s.the(Tab), "connect");
    s.settle({ until: (w) => w.the(Tab).state.welcomed });
    s.act(s.the(Tab), "open");
    s.settle({ until: (w) => w.the(Tab).state.records.length === 3 });
  },
});
const theSessionIsCutBack = defineScenario("The Session is cut back", {
  description: "A divergence truncates the Session to its first record in a new epoch; the tab drops the rest and receives the new records.",
  setup(w) {
    w.set(SessionDO, { records: ["1.1", "1.2"] });
    w.set(HostDO, { head: 2 });
  },
  run(s) {
    s.act(s.the(Tab), "connect");
    s.settle({ until: (w) => w.the(Tab).state.welcomed });
    s.act(s.the(Tab), "open");
    s.settle({ until: (w) => w.the(Tab).state.opened });
    s.act(s.the(HostDO), "truncate");
    s.settle({ until: (w) => w.the(Tab).state.epoch === 2 && !w.the(HostDO).state.busy });
    s.act(s.the(HostDO), "commit");
    s.settle({ until: (w) => w.the(Tab).state.records.at(-1)?.line === "2.2" });
  },
});
const aPromptWhileTheMacSleeps = defineScenario("A prompt while the Mac sleeps", {
  description: "The Mac is offline: the prompt fails at once and nothing is stored.",
  setup(w) {
    w.set(SessionDO, { records: ["1.1"] });
    w.set(HostDO, { head: 1, online: false });
  },
  run(s) {
    s.act(s.the(Tab), "connect");
    s.settle({ until: (w) => w.the(Tab).state.welcomed });
    s.act(s.the(Tab), "open");
    s.settle({ until: (w) => w.the(Tab).state.opened });
    s.act(s.the(Tab), "prompt");
    s.settle({ until: (w) => w.the(Tab).state.prompt === "offline" });
  },
});

export default defineSpec({
  name: "Client delivery",
  description:
    "How a client follows a Session through its ClientDO: it opens a window, gets new records only as fast as it acknowledges them, sees replies stream in as snapshots, and resets cleanly when the Session is cut back.",
  actors: [Tab, ClientDO, HostDO, SessionDO],
  limits: [limit1, limit2, limit4],
  properties: [noGapsNoDuplicates, holdsWhatTheCloudHolds, oneBatchOutstanding, progressEndsWithItsRecord, promptsAreAnswered, catchesUp],
  scenarios: [openingTheWebApp, aReplyStreamsIn, aBackgroundedTab, reconnectingWithRecordsInHand, theSessionIsCutBack, aPromptWhileTheMacSleeps],
});
