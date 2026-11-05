import { atMost, budget, defineActor, defineCall, defineLimit, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone, failed, FAULT, listOf, lose, nullable, spend } from "@leostera/feynman";

// RFD0032, Push delivery: a client holds a socket on each Mac's HostDO (protocol 3), and the HostDO
// pushes it the records it commits, from the append it has in hand. Frames a Durable Object sends
// on its own sockets are free; a call to another Durable Object is a billed request. So the only
// billed work left per record is the SessionDO append, and a read happens only when the HostDO
// does not hold what the client is missing: after it lost its memory, or for a client that is
// behind.
//
// One Session, at most three records, one browser tab with one host socket. Uploads from axod are
// stood in for by the HostDO's actions (session-sync.ts models them). Batches are one record.
// Records are named by epoch and position ("1.2"), so a record from before a truncate can never
// pass for one after it.
//
// What the HostDO keeps where:
// - In SQLite: the index (head, epoch) and one row per open Session per socket (`client_opens`:
//   epoch, sent, acked), keyed by the socket's id, so it survives hibernation and code updates.
// - In memory: the records it committed recently, the progress snapshots, and reads in flight.
//   Hibernating loses them; a pending call keeps the object in memory, so it hibernates only when
//   nothing is in flight.
// - The socket itself survives hibernation and deferred code updates. A forced reset (a code update
//   past its delay, or an eviction) closes it; its row stays behind until the next hello sweeps it.
//
// A WebSocket delivers its frames in order, which the checker does not assume of messages: so each
// frame names its socket and carries a sequence number, and the tab applies them in order.
//
// Not modelled: several tabs, Sessions or Macs (each tab-Session pair is independent); the index of
// Sessions beyond the one head; scrolling back, which reads the SessionDO as before; the account
// socket (push-migration.ts); prompts, which go to axod on the host socket and are answered as in
// RFD0024, with nothing stored.

const MAX_RECORDS = 3;
const WINDOW = 2;

type Rec = { cursor: number; line: string };
type Row = { socket: number; epoch: number; sent: number; acked: number; outstanding: number };

function line(epoch: number, cursor: number): string {
  return `${epoch}.${cursor}`;
}

/** Faults on one path: lost calls, dropped sockets, forced resets. `--set faults=2` raises it. */
const faults = budget("faults", 1);

const pushFromAppend = defineRule("pushFromAppend", {
  description: "The HostDO sends a client the records it just committed, from the append it has in hand, instead of reading them back from the SessionDO.",
});
const openAtHead = defineRule("openAtHead", {
  description: "Opening a Session the client already holds up to the index's head answers from the index, without a read.",
});
const retryAtOnce = defineRule("retryAtOnce", { description: "A read that fails is made again at once, while the HostDO is awake." });
const staleReadsAreRedone = defineRule("staleReadsAreRedone", {
  description: "A read answered in an epoch older than the index's (a truncate landed while it was in flight) is thrown away and made again in the new epoch.",
});
const learnTheCut = defineRule("learnTheCut", {
  description: "A socket whose row is in an older epoch than the index is read once in that epoch, and the SessionDO's answer says where the Session was cut; the HostDO does not always know, since a truncate's answer may be lost.",
});
const fenceOnVerify = defineRule("fenceOnVerify", {
  description: "Every head read raises the HostDO's fence (kept in SQLite) and the SessionDO keeps the highest it saw; it refuses a write with an older fence, so an append sent by an instance a reset ended can't land after the head that replaced it.",
});
const sweepStaleRows = defineRule("sweepStaleRows", {
  description: "A hello deletes the open-Session rows of sockets that no longer exist, so a row left by a forced reset never stands in for a live socket.",
});
const tabDropsRecordedProgress = defineRule("tabDropsRecordedProgress", {
  description: "The client hides a progress snapshot once it holds the record the snapshot previews (the web app's recordedReplies), since a HostDO that hibernated forgets to clear it.",
});

const Hello = defineMessage("Hello", { socket: Number }, { name: "axo.client.hello (protocol 3)", over: "websocket" });
const Welcome = defineMessage("Welcome", { socket: Number, seq: Number, head: Number, epoch: Number }, { name: "the host's index", over: "websocket", tone: "reply" });
const Open = defineMessage("Open", { socket: Number, have: nullable({ epoch: Number, cursor: Number }) }, { name: "axo.client.session.open", over: "websocket" });
const Opened = defineMessage("Opened", { socket: Number, seq: Number, epoch: Number, keep: nullable(Number), records: listOf({ cursor: Number, line: String }), cursor: Number, progress: nullable({ for: Number, text: String }) }, { name: "the window", over: "websocket", tone: "reply" });
const Records = defineMessage("Records", { socket: Number, seq: Number, epoch: Number, records: listOf({ cursor: Number, line: String }), cursor: Number }, { name: "axo.client.session.records", over: "websocket", tone: "stream" });
const Ack = defineMessage("Ack", { socket: Number, cursor: Number }, { name: "axo.client.session.ack", over: "websocket" });
const Progress = defineMessage("Progress", { socket: Number, seq: Number, snapshot: nullable({ for: Number, text: String }) }, { name: "axo.client.session.progress", over: "websocket", tone: "stream" });
const Reset = defineMessage("Reset", { socket: Number, seq: Number, epoch: Number, keep: Number }, { name: "axo.client.session.reset", over: "websocket", tone: "stream" });
const Bye = defineMessage("Bye", { socket: Number }, { name: "socket closed", over: "websocket" });
const Closed = defineMessage("Closed", { socket: Number }, { name: "the socket dropped", over: "websocket", tone: "refused" });
const ReadOpen = defineCall("ReadOpen", { id: Number, after: Number, epoch: Number }, { name: "SessionDO.read (open)", over: "rpc" });
const ReadGap = defineCall("ReadGap", { id: Number, after: Number, epoch: Number }, { name: "SessionDO.read (missing records)", over: "rpc" });
const ReadResult = defineMessage("ReadResult", { id: Number, open: Boolean, epoch: Number, records: listOf({ cursor: Number, line: String }), head: Number }, { name: "records", over: "rpc", tone: "reply" });
const ReadReset = defineMessage("ReadReset", { id: Number, open: Boolean, epoch: Number, keep: Number }, { name: "the epoch moved", over: "rpc", tone: "refused" });
const Commit = defineCall("Commit", { line: String, fence: Number }, { name: "SessionDO.append", over: "rpc" });
const Committed = defineMessage("Committed", { head: Number, epoch: Number }, { name: "committed", over: "rpc", tone: "reply" });
const Head = defineCall("Head", { fence: Number }, { name: "SessionDO.head", over: "rpc" });
const HeadIs = defineMessage("HeadIs", { head: Number, epoch: Number }, { name: "head", over: "rpc", tone: "reply" });
const Cut = defineCall("Cut", { keep: Number, fence: Number }, { name: "SessionDO.truncate", over: "rpc" });
const CutDone = defineMessage("CutDone", { head: Number, epoch: Number, keep: Number }, { name: "truncated", over: "rpc", tone: "reply" });

const clientZone = defineZone({ name: "Client", description: "a browser tab", place: { column: 0 } });
const edge = defineZone({ name: "Cloudflare", description: "one HostDO per Mac, one SessionDO per Session", place: { column: 1, region: true } });

const limit1 = defineLimit({ name: "Records per batch to a client", value: 64, unit: "records" });
const limit2 = defineLimit({ name: "Recent records a HostDO keeps in memory per Session", value: 64, unit: "records" });
const limit3 = defineLimit({ name: "Deferred code update, before a forced reset", value: 300, unit: "seconds" });

export const Tab = defineActor({
  name: "Browser tab",
  description: "The web app in one tab: a socket on the Mac's HostDO and the records it holds.",
  zone: clientZone,
  singleton: true,
  initialState: () => ({
    connected: false,
    welcomed: false,
    opened: false,
    epoch: 0,
    records: [] as Rec[],
    /** How far its copy reaches: the last record it holds, or the cursor its window or a cut left it at. */
    at: 0,
    needsAck: false,
    /** The snapshot shown, and the record it previews. */
    progress: null as { for: number; text: string } | null,
    stalled: false,
    dropped: false,
    /** An open is waiting for its window. */
    opening: false,
    /** The socket it holds now (each connect is a new one), the next frame it expects on it, and frames that came early. */
    socket: 0,
    next: 1,
    early: [] as { kind: string; seq: number; msg: any }[],
  }),
  display: {
    icon: "browser",
    status: (s) => (!s.connected ? "closed" : !s.opened ? "connected" : `${s.records.length} record(s)${s.progress ? ", a reply streaming" : ""}${s.stalled ? ", stalled" : ""}`),
    mood: (s) => (!s.connected ? "off" : s.stalled ? "warn" : "ok"),
    rows: (s) => [
      ...s.records.map((r) => ({ label: `${r.cursor}`, detail: r.line })),
      ...(s.progress ? [{ label: "streaming", detail: s.progress.text, mood: "busy" as const }] : []),
    ],
  },
  links: (s) => (s.connected ? [{ to: "HostDO", kind: "websocket" }] : []),
  actions: {
    connect: {
      with: [atMost(2)],
      label: "Open the web app",
      description: "Opens a socket on the Mac's HostDO and says hello.",
      when: (s) => !s.connected,
      sends: [Hello],
      run: (state, _i, ctx) => connect(state, ctx),
    },
    open: {
      with: [atMost(2)],
      label: "Open the Session",
      description: "Opens the Session: the last few records, or what follows the ones it already holds.",
      when: (s) => s.welcomed && !s.opened && !s.opening,
      sends: [Open],
      run(state, _i, ctx) {
        state.opening = true;
        const last = state.records.at(-1);
        ctx.send(ctx.the(HostDO), Open, { socket: state.socket, have: last ? { epoch: state.epoch, cursor: last.cursor } : null });
      },
    },
    stall: {
      with: [atMost(1)],
      label: "Background the tab",
      description: "The tab stops processing, so it stops acknowledging.",
      when: (s) => s.opened && !s.stalled,
      run: (state) => void (state.stalled = true),
    },
    resume: {
      with: [atMost(1)],
      label: "Bring the tab back",
      description: "The tab processes again.",
      when: (s) => s.stalled,
      run: (state) => void (state.stalled = false),
    },
    close: {
      with: [atMost(1)],
      label: "Close the socket",
      description: "The tab closes its socket. What it holds stays in memory for the next connect.",
      when: (s) => s.connected,
      sends: [Bye],
      run: (state, _i, ctx) => dropped(state, ctx, true),
    },
  },
  transitions: {
    welcome: { on: Welcome, description: "Sees the Mac's Sessions and their heads.", run: (s, m, ctx) => receive(s, "welcome", m, ctx) },
    opened: { on: Opened, description: "Shows the window: the records after the ones it held, cut back first if the Session was cut since, or a fresh window.", run: (s, m, ctx) => receive(s, "opened", m, ctx) },
    records: { on: Records, description: "Adds new records at the end; a snapshot of a record it now holds goes.", run: (s, m, ctx) => receive(s, "records", m, ctx) },
    ack: {
      description: "Acknowledges the records it has processed, unless the tab is stalled.",
      when: (s) => s.connected && s.opened && !s.stalled && s.needsAck && s.records.length > 0,
      sends: [Ack],
      run(state, _, ctx) {
        state.needsAck = false;
        ctx.send(ctx.the(HostDO), Ack, { socket: state.socket, cursor: state.records.at(-1)!.cursor });
      },
    },
    progress: { on: Progress, description: "Shows the newest snapshot of the reply being written.", run: (s, m, ctx) => receive(s, "progress", m, ctx) },
    reset: { on: Reset, description: "The Session was cut back: drops the records past the common prefix and continues in the new epoch.", run: (s, m, ctx) => receive(s, "reset", m, ctx) },
    closed: { on: Closed, description: "The socket dropped on the HostDO's side: the tab sees it close.", run: (state, m, ctx) => void (m.socket === state.socket && dropped(state, ctx, false)) },
    reconnect: {
      description: "The socket dropped: the web app connects again by itself, after a backoff, and says hello.",
      when: (s) => s.dropped && !s.connected,
      sends: [Hello],
      run: (state, _m, ctx) => connect(state, ctx),
    },
    // A frame lost on its way to the tab is the socket dropping: both ends see it close.
    welcomeLost: drops(Welcome),
    openedLost: drops(Opened),
    recordsLost: drops(Records),
    progressLost: drops(Progress),
    resetLost: drops(Reset),
  },
});

type TabState = any;

function connect(state: TabState, ctx: any): void {
  state.connected = true;
  state.welcomed = false;
  state.dropped = false;
  state.socket += 1;
  state.next = 1;
  state.early = [];
  ctx.send(ctx.the(HostDO), Hello, { socket: state.socket });
}

/** Takes one frame of the socket it holds, in order: an early one waits for those before it. */
function receive(state: TabState, kind: string, msg: any, ctx: any): void {
  if (!state.connected || msg.socket !== state.socket) return;
  if (msg.seq !== state.next) {
    // Kept sorted, so the order frames came early in doesn't make states differ.
    state.early.push({ kind, seq: msg.seq, msg });
    state.early.sort((a: { seq: number }, b: { seq: number }) => a.seq - b.seq);
    return;
  }
  apply(state, kind, msg, ctx);
  state.next += 1;
  for (;;) {
    const i = state.early.findIndex((f: { seq: number }) => f.seq === state.next);
    if (i < 0 || !state.connected) return;
    const [f] = state.early.splice(i, 1);
    apply(state, f.kind, f.msg, ctx);
    state.next += 1;
  }
}

function apply(state: TabState, kind: string, msg: any, ctx: any): void {
  switch (kind) {
    case "welcome":
      state.welcomed = true;
      return;
    case "opened":
      // The cut travels in the window itself.
      if (msg.keep !== null) state.records = state.records.filter((r: Rec) => r.cursor <= msg.keep);
      else if (msg.epoch !== state.epoch) state.records = [];
      state.epoch = msg.epoch;
      for (const r of msg.records) if (!state.records.some((x: Rec) => x.cursor === r.cursor)) state.records.push(r);
      state.records.sort((a: Rec, b: Rec) => a.cursor - b.cursor);
      state.at = msg.cursor;
      state.progress = msg.progress;
      dropRecordedProgress(state);
      state.opened = true;
      state.opening = false;
      return;
    case "records":
      if (!state.opened || msg.epoch !== state.epoch) return;
      for (const r of msg.records) if (!state.records.some((x: Rec) => x.cursor === r.cursor)) state.records.push(r);
      state.at = Math.max(state.at, msg.cursor);
      state.needsAck = true;
      dropRecordedProgress(state);
      return;
    case "progress":
      if (!state.opened) return;
      state.progress = msg.snapshot;
      dropRecordedProgress(state);
      return;
    case "reset":
      if (!state.opened) return;
      state.records = state.records.filter((r: Rec) => r.cursor <= msg.keep);
      state.at = Math.min(state.at, msg.keep);
      state.epoch = msg.epoch;
      state.progress = null;
      return;
  }
}
function dropped(state: TabState, ctx: any, tellHost: boolean): void {
  if (!state.connected) return;
  state.connected = false;
  state.welcomed = false;
  state.opened = false;
  state.opening = false;
  state.dropped = true;
  state.early = [];
  if (tellHost) ctx.send(ctx.the(HostDO), Bye, { socket: state.socket });
}
function drops(message: any) {
  return {
    on: message,
    fair: false as const,
    tags: [FAULT],
    with: [spend(faults)],
    sends: [Bye],
    description: `${message.name} is lost: the socket drops, and both ends see it close.`,
    run: (state: TabState, m: any, ctx: any) => void (m.socket === state.socket && dropped(state, ctx, true)),
  };
}
function dropRecordedProgress(state: TabState): void {
  if (tabDropsRecordedProgress.on && state.progress && state.records.some((r: Rec) => r.cursor === state.progress.for && r.line.startsWith(`${state.epoch}.`)))
    state.progress = null;
}

export const HostDO = defineActor({
  name: "HostDO",
  description: "The Mac's Durable Object: it commits what axod uploads, holds the clients' host sockets, and pushes each one what it commits.",
  zone: edge,
  singleton: true,
  initialState: () => ({
    // In SQLite.
    head: 0,
    epoch: 1,
    /** `client_opens`: the open Session of a socket, by the socket's id. */
    rows: [] as Row[],
    // The sockets: they survive hibernation, not a forced reset.
    socket: 0,
    /** The last frame sent on the socket. */
    out: 0,
    // In memory: lost when it hibernates or is reset.
    /** Records committed in the current epoch since it last woke, by cursor. */
    recent: [] as Rec[],
    /** In SQLite, so it survives a reset: raised by every head read, carried by every write. */
    fence: 0,
    progress: null as { for: number; text: string } | null,
    /** A commit or truncate waiting on the SessionDO, with the line it carries. */
    busy: false,
    inHand: null as string | null,
    truncated: false,
    /** axod's socket closed with the reset: it reconnects and handshakes, which reads the head back. */
    resync: false,
    /** The read in flight for the socket, by id; a reply to an older one is ignored. */
    reading: 0,
    reads: 0,
    /** The open read is answering an Open: the reply is the window. */
    opening: false,
    /** Where the Session was cut since the epoch the opening tab holds, for the window to carry. */
    openKeep: null as number | null,
  }),
  display: {
    icon: "cloud",
    status: (s) => `head ${s.head}, epoch ${s.epoch}`,
    mood: () => "ok",
    rows: (s) => [
      ...s.rows.map((r) => ({ group: "client_opens", label: `socket ${r.socket}${r.socket === s.socket ? "" : " (gone)"}`, detail: `sent ${r.sent}, acked ${r.acked}` })),
      ...s.recent.map((r) => ({ group: "in memory", label: `${r.cursor}`, detail: r.line })),
      ...(s.progress ? [{ group: "in memory", label: "progress", detail: s.progress.text, mood: "busy" as const }] : []),
    ],
  },
  actions: {
    commit: {
      with: [atMost(2)],
      label: "axod uploads a record",
      description: "A line from the Mac is appended to the SessionDO; the HostDO keeps it in hand until the SessionDO answers.",
      when: (s) => !s.busy && s.head < MAX_RECORDS,
      sends: [Commit],
      run(state, _i, ctx) {
        state.busy = true;
        state.inHand = line(state.epoch, state.head + 1);
        ctx.send(ctx.the(SessionDO), Commit, { line: state.inHand, fence: state.fence });
      },
    },
    stream: {
      with: [atMost(1)],
      label: "axod sends progress",
      description: "A snapshot of the reply being written arrives and goes to every socket with the Session open.",
      when: (s) => s.head < MAX_RECORDS && s.progress?.text !== "more",
      sends: [Progress],
      run(state, _i, ctx) {
        state.progress = { for: state.head + 1, text: state.progress ? "more" : "partial" };
        if (openRow(state)) frame(state, ctx, Progress, { snapshot: state.progress });
      },
    },
    truncate: {
      with: [atMost(1)],
      label: "The Session diverged",
      description: "The handshake found a divergence; the SessionDO is cut back to its first record.",
      when: (s) => !s.busy && !s.truncated && s.head >= 2,
      sends: [Cut],
      run(state, _i, ctx) {
        state.busy = true;
        state.truncated = true;
        ctx.send(ctx.the(SessionDO), Cut, { keep: 1, fence: state.fence });
      },
    },
    hibernate: {
      with: [atMost(1)],
      label: "The HostDO hibernates",
      description: "Nothing is in flight, so it leaves memory: the sockets and SQLite stay, the recent records and progress go. A deferred code update adopts new code here.",
      when: (s) => !s.busy && s.reading === 0,
      run(state) {
        state.recent = [];
        state.progress = null;
      },
    },
  },
  transitions: {
    hello: {
      on: Hello,
      description: "Takes the socket, replacing an older one of the same client, sweeps the rows of sockets that are gone, and answers with the index.",
      sends: [Welcome, Closed],
      run(state, msg, ctx) {
        // One socket per client per Mac: a newer connection replaces the one before (code 4000).
        if (state.socket && state.socket !== msg.socket) ctx.send(ctx.the(Tab), Closed, { socket: state.socket });
        state.socket = msg.socket;
        state.out = 0;
        state.reading = 0;
        state.opening = false;
        if (sweepStaleRows.on) state.rows = state.rows.filter((r) => r.socket === state.socket);
        frame(state, ctx, Welcome, { head: state.head, epoch: state.epoch });
      },
    },
    open: {
      on: Open,
      description: "Opens the Session for the socket: from the index when the tab already holds everything, else with a read.",
      sends: [Opened, ReadOpen],
      run(state, msg, ctx) {
        if (!state.socket || msg.socket !== state.socket) return;
        state.rows = state.rows.filter((r) => r.socket !== state.socket);
        const have = msg.have;
        if (openAtHead.on && have && have.epoch === state.epoch && have.cursor === state.head) {
          state.rows.push({ socket: state.socket, epoch: state.epoch, sent: state.head, acked: state.head, outstanding: 0 });
          return frame(state, ctx, Opened, { epoch: state.epoch, keep: null, records: [], cursor: state.head, progress: state.progress });
        }
        // A pending row: the open read answers it.
        state.rows.push({ socket: state.socket, epoch: have?.epoch ?? state.epoch, sent: have?.cursor ?? 0, acked: have?.cursor ?? 0, outstanding: 0 });
        state.opening = true;
        state.openKeep = null;
        state.reads += 1;
        state.reading = state.reads;
        ctx.send(ctx.the(SessionDO), ReadOpen, { id: state.reading, after: have ? have.cursor : Math.max(0, state.head - WINDOW), epoch: have?.epoch ?? state.epoch });
      },
    },
    ack: {
      on: Ack,
      description: "The tab took the batch: the next one goes, from memory if the HostDO has it.",
      sends: [Records, ReadGap],
      run(state, msg, ctx) {
        const row = openRow(state);
        if (!row || msg.socket !== state.socket || msg.cursor !== row.sent) return;
        row.acked = msg.cursor;
        row.outstanding = 0;
        deliver(state, ctx);
      },
    },
    bye: {
      on: Bye,
      description: "The tab's socket closed: its row goes with it.",
      run(state, msg) {
        if (msg.socket !== state.socket) return;
        state.rows = state.rows.filter((r) => r.socket !== state.socket);
        state.socket = 0;
        state.reading = 0;
        state.opening = false;
        state.openKeep = null;
      },
    },
    committed: {
      on: Committed,
      description: "The record is committed: the HostDO keeps it in memory, clears the progress it completes, and pushes it to the tab.",
      sends: [Records, ReadGap, Progress],
      run(state, msg, ctx) {
        // A reply to the instance a reset ended reaches no one.
        if (!state.busy) return;
        state.busy = false;
        const inHand = state.inHand;
        state.inHand = null;
        if (msg.epoch !== state.epoch) return;
        state.head = msg.head;
        if (pushFromAppend.on && inHand) state.recent.push({ cursor: msg.head, line: inHand });
        if (state.progress && state.progress.for <= msg.head) {
          state.progress = null;
          if (openRow(state)) frame(state, ctx, Progress, { snapshot: null });
        }
        deliver(state, ctx);
      },
    },
    commitFailed: {
      on: failed(Commit),
      description: "The commit may or may not have happened: the head is read back from the SessionDO. The line in hand can't be trusted.",
      sends: [Head],
      run(state, _f, ctx) {
        state.inHand = null;
        readHead(state, ctx);
      },
    },
    headIs: {
      on: HeadIs,
      description: "The index's head is refreshed from the SessionDO; the tab is sent what it misses.",
      sends: [Records, ReadGap, Progress],
      run(state, msg, ctx) {
        if (!state.busy) return;
        state.busy = false;
        // The Session was cut where this instance did not see it: what it holds in memory is from the old epoch.
        if (msg.epoch !== state.epoch) Object.assign(state, { recent: [], progress: null });
        state.head = msg.head;
        state.epoch = msg.epoch;
        if (state.progress && state.progress.for <= msg.head) {
          state.progress = null;
          if (openRow(state)) frame(state, ctx, Progress, { snapshot: null });
        }
        deliver(state, ctx);
      },
    },
    headFailed: { on: failed(Head), description: "The read threw: it is made again.", sends: [Head], run: (s, _f, ctx) => void (s.busy && readHead(s, ctx)) },
    cutDone: {
      on: CutDone,
      description: "The Session is cut back in a new epoch. The HostDO made the cut, so it tells the tab where, with no read.",
      sends: [Reset, Records, ReadGap],
      run(state, msg, ctx) {
        if (!state.busy) return;
        state.busy = false;
        state.epoch = msg.epoch;
        state.head = msg.head;
        state.recent = [];
        state.progress = null;
        const row = openRow(state);
        if (row && row.epoch < msg.epoch) {
          row.epoch = msg.epoch;
          row.sent = Math.min(row.sent, msg.keep);
          row.acked = Math.min(row.acked, msg.keep);
          row.outstanding = 0;
          if (state.opening) state.openKeep = Math.min(state.openKeep ?? msg.keep, msg.keep);
          else frame(state, ctx, Reset, { epoch: msg.epoch, keep: msg.keep });
        }
        deliver(state, ctx);
      },
    },
    cutFailed: { on: failed(Cut), description: "The truncate may or may not have happened; axod handshakes again, which reads the head back.", run: (state) => void ((state.busy = false), (state.truncated = false), (state.resync = true)) },
    readResult: {
      on: ReadResult,
      description: "Records read for the socket: the window for an open, or what the HostDO didn't hold in memory.",
      sends: [Opened, Records, ReadGap, ReadOpen],
      run(state, msg, ctx) {
        if (msg.id !== state.reading) return;
        state.reading = 0;
        const row = openRow(state);
        if (!row) return;
        if (msg.open) {
          if (staleReadsAreRedone.on && msg.epoch !== state.epoch) {
            state.reads += 1;
            state.reading = state.reads;
            return ctx.send(ctx.the(SessionDO), ReadOpen, { id: state.reading, after: row.acked, epoch: state.epoch });
          }
          state.opening = false;
          const cursor = msg.records.at(-1)?.cursor ?? Math.min(row.acked, msg.head);
          Object.assign(row, { epoch: msg.epoch, sent: cursor, acked: cursor, outstanding: 0 });
          frame(state, ctx, Opened, { epoch: msg.epoch, keep: state.openKeep, records: msg.records, cursor, progress: state.progress });
          state.openKeep = null;
          return deliver(state, ctx);
        }
        if (msg.epoch !== row.epoch || msg.records.length === 0 || row.sent !== row.acked) return deliver(state, ctx);
        const cursor = msg.records.at(-1)!.cursor;
        row.sent = cursor;
        row.outstanding = 1;
        frame(state, ctx, Records, { epoch: msg.epoch, records: msg.records, cursor });
      },
    },
    readReset: {
      on: ReadReset,
      description: "The tab's copy is from an older epoch: it is told where the Session was cut, and the window is read again from there.",
      sends: [Reset, ReadOpen, Records, ReadGap],
      run(state, msg, ctx) {
        if (msg.id !== state.reading) return;
        state.reading = 0;
        const row = openRow(state);
        if (!row) return;
        Object.assign(row, { epoch: msg.epoch, sent: Math.min(row.sent, msg.keep), acked: Math.min(row.acked, msg.keep), outstanding: 0 });
        if (msg.open) {
          state.openKeep = Math.min(state.openKeep ?? msg.keep, msg.keep);
          state.reads += 1;
          state.reading = state.reads;
          return ctx.send(ctx.the(SessionDO), ReadOpen, { id: state.reading, after: row.acked, epoch: msg.epoch });
        }
        frame(state, ctx, Reset, { epoch: msg.epoch, keep: msg.keep });
        deliver(state, ctx);
      },
    },
    readOpenFailed: {
      on: failed(ReadOpen),
      description: "The open read threw: it is made again at once.",
      sends: [ReadOpen],
      run(state, f, ctx) {
        if (f.payload.id !== state.reading) return;
        state.reading = 0;
        if (!retryAtOnce.on || !openRow(state)) return;
        state.reads += 1;
        state.reading = state.reads;
        ctx.send(ctx.the(SessionDO), ReadOpen, { ...f.payload, id: state.reading });
      },
    },
    readGapFailed: {
      on: failed(ReadGap),
      description: "The read threw: it is made again at once.",
      sends: [Records, ReadGap],
      run(state, f, ctx) {
        if (f.payload.id !== state.reading) return;
        state.reading = 0;
        if (retryAtOnce.on) deliver(state, ctx);
      },
    },
    forcedReset: {
      when: (s) => s.socket > 0 || s.busy || s.reading > 0,
      fair: false,
      tags: [FAULT],
      with: [spend(faults)],
      description: "A code update past its delay, or an eviction: memory and every socket go, axod's too, SQLite stays, and replies to the old instance are lost.",
      sends: [Closed],
      run(state, _m, ctx) {
        if (state.socket) ctx.send(ctx.the(Tab), Closed, { socket: state.socket });
        Object.assign(state, { socket: 0, recent: [], progress: null, busy: false, inHand: null, reading: 0, opening: false, openKeep: null, resync: true });
      },
    },
    handshake: {
      description: "axod reconnects after the reset and handshakes: the HostDO reads the head back, and axod retries what it was uploading.",
      when: (s) => s.resync && !s.busy,
      sends: [Head],
      run(state, _m, ctx) {
        state.resync = false;
        state.busy = true;
        readHead(state, ctx);
      },
    },
    // Faults on the calls to the SessionDO.
    committedLost: lose(Committed, { fails: Commit, spend: faults }),
    headIsLost: lose(HeadIs, { fails: Head, spend: faults }),
    cutDoneLost: lose(CutDone, { fails: Cut, spend: faults }),
    readResultLost: lose(ReadResult, { fails: ReadGap, spend: faults }),
  },
});

type HostState = any;

/** Reads the head back, raising the fence first so a write sent before it can't land after it. */
function readHead(state: HostState, ctx: any): void {
  if (fenceOnVerify.on) state.fence += 1;
  ctx.send(ctx.the(SessionDO), Head, { fence: state.fence });
}

/** Sends a frame on the tab's socket, numbered in the order it is sent. */
function frame(state: HostState, ctx: any, message: any, payload: any): void {
  if (!state.socket) return;
  state.out += 1;
  ctx.send(ctx.the(Tab), message, { ...payload, socket: state.socket, seq: state.out });
}

function openRow(state: HostState): Row | undefined {
  return state.socket ? state.rows.find((r: Row) => r.socket === state.socket) : undefined;
}

/**
 * Sends the tab the next batch when it has acknowledged everything sent and the Session has more:
 * from memory when the HostDO holds the next record, else with a read.
 */
function deliver(state: HostState, ctx: any): void {
  const row = openRow(state);
  if (!row || state.opening || state.reading) return;
  if (row.epoch !== state.epoch) {
    // The Session was cut where the HostDO did not see it (a truncate's answer was lost): a read in
    // the tab's epoch is answered with where the cut was.
    if (!learnTheCut.on) return;
    state.reads += 1;
    state.reading = state.reads;
    return ctx.send(ctx.the(SessionDO), ReadGap, { id: state.reading, after: row.sent, epoch: row.epoch });
  }
  if (row.sent !== row.acked || row.sent >= state.head) return;
  const next = state.recent.find((r: Rec) => r.cursor === row.sent + 1);
  if (next) {
    row.sent = next.cursor;
    row.outstanding = 1;
    return frame(state, ctx, Records, { epoch: state.epoch, records: [next], cursor: next.cursor });
  }
  state.reads += 1;
  state.reading = state.reads;
  ctx.send(ctx.the(SessionDO), ReadGap, { id: state.reading, after: row.sent, epoch: row.epoch });
}

export const SessionDO = defineActor({
  name: "SessionDO",
  description: "The Session's Durable Object: its records by cursor, within an epoch.",
  zone: edge,
  singleton: true,
  initialState: () => ({
    epoch: 1,
    records: [] as string[],
    cuts: [] as { epoch: number; keep: number }[],
    /** The highest fence a head read carried. */
    fence: 0,
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
      sources: ["packages/axo-api-worker/src/session-store.ts#AxoSessionDO.append"],
      sends: [Committed],
      run(state, msg, ctx) {
        // The line carries the epoch and position the HostDO expects; the store checks the chain.
        if (msg.fence < state.fence || msg.line !== line(state.epoch, state.records.length + 1)) return ctx.reply(Committed, { head: state.records.length, epoch: state.epoch });
        state.records.push(msg.line);
        ctx.reply(Committed, { head: state.records.length, epoch: state.epoch });
      },
    },
    readOpen: {
      on: ReadOpen,
      description: "Returns the records after a cursor; a reader from an older epoch is told the new epoch and how much still stands.",
      sources: ["packages/axo-api-worker/src/session-store.ts#AxoSessionDO.read"],
      sends: [ReadResult, ReadReset],
      run: (state, msg, ctx) => read(state, msg, true, ctx),
    },
    readGap: {
      on: ReadGap,
      description: "Returns the next record after a cursor.",
      sources: ["packages/axo-api-worker/src/session-store.ts#AxoSessionDO.read"],
      sends: [ReadResult, ReadReset],
      run: (state, msg, ctx) => read(state, msg, false, ctx),
    },
    head: {
      on: Head,
      description: "Says how many records it holds, in which epoch.",
      sources: ["packages/axo-api-worker/src/session-store.ts#AxoSessionDO.head"],
      sends: [HeadIs],
      run(state, msg, ctx) {
        state.fence = Math.max(state.fence, msg.fence);
        ctx.reply(HeadIs, { head: state.records.length, epoch: state.epoch });
      },
    },
    cut: {
      on: Cut,
      description: "Deletes the records past the prefix and starts a new epoch.",
      sources: ["packages/axo-api-worker/src/session-store.ts#AxoSessionDO.truncate"],
      sends: [CutDone],
      run(state, msg, ctx) {
        // A truncate fenced off answers with what stands; it reaches no one but the instance a reset ended.
        if (msg.fence < state.fence) return ctx.reply(CutDone, { head: state.records.length, epoch: state.epoch, keep: state.records.length });
        state.records = state.records.slice(0, msg.keep);
        state.epoch += 1;
        state.cuts.push({ epoch: state.epoch, keep: msg.keep });
        ctx.reply(CutDone, { head: state.records.length, epoch: state.epoch, keep: msg.keep });
      },
    },
    commitLost: lose(Commit, { spend: faults }),
    readOpenLost: lose(ReadOpen, { spend: faults }),
    readGapLost: lose(ReadGap, { spend: faults }),
    headLost: lose(Head, { spend: faults }),
    cutLost: lose(Cut, { spend: faults }),
  },
});

function read(state: any, msg: { id: number; after: number; epoch: number }, open: boolean, ctx: any): void {
  if (msg.epoch !== state.epoch) {
    const keep = Math.min(...state.cuts.filter((c: { epoch: number }) => c.epoch > msg.epoch).map((c: { keep: number }) => c.keep));
    return ctx.reply(ReadReset, { id: msg.id, open, epoch: state.epoch, keep });
  }
  const after = state.records.map((l: string, i: number) => ({ cursor: i + 1, line: l })).filter((r: Rec) => r.cursor > msg.after);
  ctx.reply(ReadResult, { id: msg.id, open, epoch: state.epoch, records: open ? after : after.slice(0, 1), head: state.records.length });
}

const noGapsNoDuplicates = defineProperty("noGapsNoDuplicates", {
  needs: [staleReadsAreRedone],
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
  description: "A socket never has more than one batch of records waiting for the tab's acknowledgement.",
  always: (w) => w.the(HostDO).state.rows.every((r) => r.outstanding <= 1 && r.sent - r.acked <= 1),
});
const progressEndsWithItsRecord = defineProperty("progressEndsWithItsRecord", {
  needs: [tabDropsRecordedProgress],
  description: "Once a quiet tab holds the record a snapshot previews, it shows no snapshot of it, even if the HostDO hibernated in between.",
  always: (w) => {
    const tab = w.the(Tab).state;
    return !w.quiet || !tab.progress || !tab.records.some((r) => r.cursor === tab.progress!.for && r.line.startsWith(`${tab.epoch}.`));
  },
});
const catchesUp = defineProperty("catchesUp", {
  needs: [retryAtOnce, sweepStaleRows, learnTheCut, fenceOnVerify],
  description: "A connected tab that keeps acknowledging ends up with its copy reaching the Session's head, in the Session's epoch.",
  leadsTo: {
    whenever: (w) => {
      const tab = w.the(Tab).state;
      return tab.opened && !tab.stalled && (tab.epoch !== w.the(SessionDO).state.epoch || tab.at !== w.the(SessionDO).state.records.length);
    },
    then: (w) => {
      const tab = w.the(Tab).state;
      return !tab.opened || tab.stalled || (tab.epoch === w.the(SessionDO).state.epoch && tab.at === w.the(SessionDO).state.records.length);
    },
  },
});
/** The point of the design: a record costs one billed call, the append, and no read. */
const readsOnlyAfterForgetting = defineProperty("readsOnlyAfterForgetting", {
  needs: [pushFromAppend],
  description: "A tab that keeps its socket gets every new record with no read from the SessionDO, unless the HostDO forgot it: it hibernated, was reset, or lost a commit's answer.",
  never: (t) =>
    t.some((e) => e.sent(ReadGap)) &&
    !t.some((e) => e.is(HostDO, "hibernate") || e.is(HostDO, "forcedReset") || e.is(HostDO, "commitFailed") || e.is(HostDO, "cutFailed") || e.is(HostDO, "readGapFailed") || e.is(HostDO, "readResult") || e.is(HostDO, "cutDone")),
});
const opensAtHeadReadNothing = defineProperty("opensAtHeadReadNothing", {
  needs: [openAtHead],
  description: "Opening a Session the tab already holds up to the index's head reads nothing: a Mac's copy of another Mac's Sessions costs nothing to reopen.",
  everyStep: (before, after, e) => {
    if (!e.is(HostDO, "open")) return true;
    const tab = before.the(Tab).state;
    const host = before.the(HostDO).state;
    const holdsHead = tab.epoch === host.epoch && host.head > 0 && (tab.records.at(-1)?.cursor ?? 0) === host.head;
    return !holdsHead || !after.the(HostDO).state.opening;
  },
});

const openingTheWebApp = defineScenario("Opening the web app", {
  description: "The tab says hello on the host socket, opens the Session and gets its last two records; a new record is pushed from the append, with no read.",
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
    s.settle({ until: (w) => w.the(Tab).state.records.length === 3 && w.the(HostDO).state.rows[0]?.acked === 3 });
  },
});
const aReplyStreamsIn = defineScenario("A reply streams in", {
  description: "Progress snapshots reach the open tab; when the record lands, it is pushed and the snapshot clears.",
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
    s.settle({ until: (w) => w.the(Tab).state.progress?.text === "more" });
    s.act(s.the(HostDO), "commit");
    s.settle({ until: (w) => w.the(Tab).state.records.length === 2 && w.the(Tab).state.progress === null });
  },
});
const theHostDOHibernatesMidReply = defineScenario("The HostDO hibernates mid-reply", {
  description: "The HostDO hibernates while the tab is backgrounded and forgets the records it held: the tab's next acknowledgement reads the missing record, once.",
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
    s.settle({ until: (w) => w.the(HostDO).state.head === 3 && !w.the(HostDO).state.busy });
    s.act(s.the(HostDO), "hibernate");
    s.act(s.the(Tab), "resume");
    s.settle({ until: (w) => w.the(Tab).state.records.length === 3 && w.the(HostDO).state.rows[0]?.acked === 3 });
  },
});
const reconnectingWithEverything = defineScenario("Reconnecting with everything in hand", {
  description: "The socket drops and comes back; the tab already holds the head, so the open is answered from the index with no read.",
  setup(w) {
    w.set(SessionDO, { records: ["1.1", "1.2"] });
    w.set(HostDO, { head: 2 });
    w.set(Tab, { records: [{ cursor: 1, line: "1.1" }, { cursor: 2, line: "1.2" }], epoch: 1 });
  },
  run(s) {
    s.act(s.the(Tab), "connect");
    s.settle({ until: (w) => w.the(Tab).state.welcomed });
    s.act(s.the(Tab), "open");
    s.settle({ until: (w) => w.the(Tab).state.opened });
  },
});
const aForcedResetMidRead = defineScenario("A forced reset", {
  description: "A code update is forced while the tab is open: its socket closes, the tab reconnects, and the row the old socket left is swept.",
  setup(w) {
    w.set(SessionDO, { records: ["1.1"] });
    w.set(HostDO, { head: 1 });
  },
  run(s) {
    s.act(s.the(Tab), "connect");
    s.settle({ until: (w) => w.the(Tab).state.welcomed });
    s.act(s.the(Tab), "open");
    s.settle({ until: (w) => w.the(Tab).state.opened });
    s.step(s.the(HostDO), "forcedReset");
    s.settle({ until: (w) => w.the(Tab).state.welcomed && w.the(HostDO).state.socket === 2 && !w.the(HostDO).state.busy });
    s.act(s.the(Tab), "open");
    s.settle({ until: (w) => w.the(Tab).state.opened });
    s.act(s.the(HostDO), "commit");
    s.settle({ until: (w) => w.the(Tab).state.records.length === 2 && w.the(HostDO).state.rows.length === 1 });
  },
});
const theSessionIsCutBack = defineScenario("The Session is cut back", {
  description: "A divergence truncates the Session to its first record in a new epoch; the HostDO tells the tab where, and pushes the new records.",
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

export default defineSpec({
  name: "Push delivery",
  description:
    "How a client follows a Session on a socket held by the Mac's HostDO (protocol 3): records are pushed from the append in hand, a read happens only when the HostDO forgot them, and a client that reopens what it holds reads nothing.",
  actors: [Tab, HostDO, SessionDO],
  limits: [limit1, limit2, limit3],
  properties: [noGapsNoDuplicates, holdsWhatTheCloudHolds, oneBatchOutstanding, progressEndsWithItsRecord, catchesUp, readsOnlyAfterForgetting, opensAtHeadReadNothing],
  scenarios: [openingTheWebApp, aReplyStreamsIn, theHostDOHibernatesMidReply, reconnectingWithEverything, aForcedResetMidRead, theSessionIsCutBack],
});
