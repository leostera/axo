import { call, defineSpec, message } from "@leostera/feynman";

// RFD0018, Delivery: a client holds one socket to its own ClientDO, which reads the Session from
// the SessionDO at the client's pace and hears about new records through notices from the HostDO.
//
// One Session, at most three records, one browser tab. Uploads from axod are stood in for by the
// HostDO's actions (session-sync.ts models them): a record committed, a progress snapshot, a
// truncate after a divergence, the Mac going offline. Batches are one record and the opening window
// is the last two. Records are named by epoch and position ("1.2"), so a record from before a
// truncate can never pass for one after it.
//
// Not modelled: several hosts, Sessions or tabs; the index of Sessions beyond the one head;
// batching of notices (a notice here is sent at once); metadata and status.

const MAX_RECORDS = 3;
const WINDOW = 2;

type Rec = { cursor: number; line: string };
type Open = { epoch: number; sent: number; acked: number; older: number; outstanding: number } | null;

function line(epoch: number, cursor: number): string {
  return `${epoch}.${cursor}`;
}

export default defineSpec(
  "Client delivery",
  {
    description:
      "How a client follows a Session through its ClientDO: it opens a window, gets new records only as fast as it acknowledges them, sees replies stream in as snapshots, and resets cleanly when the Session is cut back.",
    messages: {
      Hello: message<{}>({ name: "axo.client.hello", over: "websocket" }),
      Welcome: message<{}>({ name: "hosts and Sessions", over: "websocket", tone: "reply" }),
      Open: message<{ have: { epoch: number; cursor: number } | null }>({ name: "axo.client.session.open", over: "websocket" }),
      Opened: message<{ epoch: number; records: Rec[]; cursor: number; older: number; progress: string | null }>({ name: "the window", over: "websocket", tone: "reply" }),
      Records: message<{ epoch: number; records: Rec[]; cursor: number }>({ name: "axo.client.session.records", over: "websocket", tone: "stream" }),
      Ack: message<{ cursor: number }>({ name: "axo.client.session.ack", over: "websocket" }),
      Older: message<{ before: number }>({ name: "axo.client.session.older", over: "websocket" }),
      OlderPage: message<{ epoch: number; records: Rec[]; older: number }>({ name: "older records", over: "websocket", tone: "reply" }),
      Progress: message<{ snapshot: string | null }>({ name: "axo.client.session.progress", over: "websocket", tone: "stream" }),
      Reset: message<{ epoch: number; keep: number }>({ name: "axo.client.session.reset", over: "websocket", tone: "stream" }),
      Command: message<{}>({ name: "axo.client.command (prompt)", over: "websocket" }),
      Accepted: message<{}>({ name: "prompt accepted", over: "websocket", tone: "reply" }),
      Offline: message<{}>({ name: "host offline", over: "websocket", tone: "refused" }),
      MayHaveRun: message<{}>({ name: "may have run; check the transcript", over: "websocket", tone: "refused" }),
      Bye: message<{}>({ name: "socket closed", over: "websocket" }),

      Subscribe: call<{}>({ name: "HostDO.subscribe", over: "rpc" }),
      Subscribed: message<{ head: number; epoch: number; progress: string | null }>({ name: "the host's index", over: "rpc", tone: "reply" }),
      Unsubscribe: message<{}>({ name: "HostDO.unsubscribe", over: "rpc" }),
      Notify: call<{ head: number; epoch: number; progress: string | null }>({ name: "ClientDO.notify", over: "rpc" }),
      Noted: message<{}>({ name: "noted", over: "rpc", tone: "reply" }),
      Read: call<{ id: number; kind: "open" | "live" | "older"; after: number; before: number; epoch: number }>({ name: "SessionDO.read", over: "rpc" }),
      ReadResult: message<{ id: number; kind: "open" | "live" | "older"; epoch: number; records: Rec[]; head: number }>({ name: "records", over: "rpc", tone: "reply" }),
      ReadReset: message<{ id: number; kind: "open" | "live" | "older"; epoch: number; keep: number }>({ name: "the epoch moved", over: "rpc", tone: "refused" }),
      Forward: call<{}>({ name: "HostDO.command", over: "rpc" }),
      Forwarded: message<{}>({ name: "axod accepted", over: "rpc", tone: "reply" }),
      HostOffline: message<{}>({ name: "host offline", over: "rpc", tone: "refused" }),
      Commit: call<{ line: string }>({ name: "SessionDO.append", over: "rpc" }),
      Committed: message<{ head: number; epoch: number }>({ name: "committed", over: "rpc", tone: "reply" }),
      Head: call<{}>({ name: "SessionDO.head", over: "rpc" }),
      HeadIs: message<{ head: number; epoch: number }>({ name: "head", over: "rpc", tone: "reply" }),
      Cut: call<{ keep: number }>({ name: "SessionDO.truncate", over: "rpc" }),
      CutDone: message<{ head: number; epoch: number }>({ name: "truncated", over: "rpc", tone: "reply" }),
    },
  },
  (spec) => {
    const m = spec.messages;

    const clientZone = spec.defineZone({ name: "Client", description: "a browser tab", place: { column: 0 } });
    const edge = spec.defineZone({ name: "Cloudflare", description: "one ClientDO per tab, one HostDO per host, one SessionDO per Session", place: { column: 1, region: true } });

    spec.defineLimit({ name: "Records per batch to a client", value: 64, unit: "records" });
    spec.defineLimit({ name: "Subscriber lease", value: 60, unit: "seconds" });
    spec.defineLimit({ name: "Lease renewal", value: 30, unit: "seconds" });
    spec.defineLimit({ name: "Opening window", value: 20, unit: "records" });

    const Tab = spec.defineActor({
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
          label: "Open the web app",
          description: "Opens the tab's one socket and says hello.",
          when: (s) => !s.connected,
          sends: [m.Hello],
          run(state, _i, ctx) {
            state.connected = true;
            state.welcomed = false;
            ctx.send(ctx.the(ClientDO), m.Hello, {});
          },
        },
        open: {
          label: "Open the Session",
          description: "Opens the Session: the last few records, or what follows the ones it already holds.",
          when: (s) => s.welcomed && !s.opened,
          sends: [m.Open],
          run(state, _i, ctx) {
            const last = state.records.at(-1);
            ctx.send(ctx.the(ClientDO), m.Open, { have: last ? { epoch: state.epoch, cursor: last.cursor } : null });
          },
        },
        scrollUp: {
          label: "Scroll up",
          description: "Asks for the records before the oldest it holds.",
          when: (s) => s.opened && s.older > 0,
          sends: [m.Older],
          run(state, _i, ctx) {
            ctx.send(ctx.the(ClientDO), m.Older, { before: state.records[0]?.cursor ?? state.older + 1 });
          },
        },
        stall: {
          label: "Background the tab",
          description: "The tab stops processing, so it stops acknowledging.",
          when: (s) => s.opened && !s.stalled,
          run: (state) => void (state.stalled = true),
        },
        resume: {
          label: "Bring the tab back",
          description: "The tab processes again.",
          when: (s) => s.stalled,
          run: (state) => void (state.stalled = false),
        },
        prompt: {
          label: "Send a prompt",
          description: "Sends a prompt to the Session's agent on the Mac.",
          when: (s) => s.opened && s.prompt !== "sending",
          sends: [m.Command],
          starts: ["commandTimeout"],
          run(state, _i, ctx) {
            state.prompt = "sending";
            ctx.send(ctx.the(ClientDO), m.Command, {});
            ctx.start("commandTimeout");
          },
        },
        close: {
          label: "Close the socket",
          description: "The network drops or the tab closes. What the tab holds stays in memory for the next connect.",
          when: (s) => s.connected,
          sends: [m.Bye],
          run(state, _i, ctx) {
            state.connected = false;
            state.welcomed = false;
            state.opened = false;
            if (state.prompt === "sending") state.prompt = "unknown";
            ctx.cancel("commandTimeout");
            ctx.send(ctx.the(ClientDO), m.Bye, {});
          },
        },
      },
      transitions: {
        [m.Welcome]: { description: "Sees its hosts and Sessions.", run: (s) => void (s.welcomed = s.connected) },
        [m.Opened]: {
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
        [m.Records]: {
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
          sends: [m.Ack],
          run(state, ctx) {
            state.needsAck = false;
            state.acked = state.records.at(-1)!.cursor;
            ctx.send(ctx.the(ClientDO), m.Ack, { cursor: state.acked });
          },
        },
        [m.OlderPage]: {
          description: "Adds older records at the top.",
          run(state, msg) {
            if (!state.opened || msg.epoch !== state.epoch) return;
            for (const r of msg.records) if (!state.records.some((x) => x.cursor === r.cursor)) state.records.unshift(r);
            state.records.sort((a, b) => a.cursor - b.cursor);
            state.older = msg.older;
          },
        },
        [m.Progress]: { description: "Shows the newest snapshot of the reply being written.", run: (s, msg) => void (s.opened && (s.progress = msg.snapshot)) },
        [m.Reset]: {
          description: "The Session was cut back: drops the records past the common prefix and continues in the new epoch.",
          run(state, msg) {
            if (!state.opened) return;
            state.records = state.records.filter((r) => r.cursor <= msg.keep);
            state.epoch = msg.epoch;
            state.acked = Math.min(state.acked, msg.keep);
            state.older = state.records.length ? state.records[0]!.cursor - 1 : Math.min(state.older, msg.keep);
          },
        },
        [m.Accepted]: { description: "The prompt reached the agent; it shows as pending until its record arrives.", run: (s, _m, ctx) => void (s.prompt === "sending" && ((s.prompt = "accepted"), ctx.cancel("commandTimeout"))) },
        [m.Offline]: { description: "The Mac is offline: the text stays in the box.", run: (s, _m, ctx) => void (s.prompt === "sending" && ((s.prompt = "offline"), ctx.cancel("commandTimeout"))) },
        [m.MayHaveRun]: { description: "The prompt may or may not have reached the Mac; the transcript will say.", run: (s, _m, ctx) => void (s.prompt === "sending" && ((s.prompt = "unknown"), ctx.cancel("commandTimeout"))) },
        commandTimeout: {
          description: "No answer in time: the prompt may or may not have reached the Mac; the transcript will say.",
          after: "10 seconds",
          run: (s) => void (s.prompt === "sending" && (s.prompt = "unknown")),
        },
      },
    });

    const ClientDO = spec.defineActor({
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
      durable: ["socket", "subscribed", "open"],
      display: {
        icon: "server",
        status: (s) => (!s.socket ? "no socket" : !s.open ? "following the host" : `sent ${s.open.sent}, acked ${s.open.acked} of ${s.head}`),
        mood: (s) => (!s.socket ? "off" : s.open && s.open.sent > s.open.acked ? "busy" : "ok"),
      },
      links: (s) => (s.subscribed ? [{ to: "HostDO", kind: "lease", style: "dotted" }] : []),
      actions: {},
      transitions: {
        [m.Hello]: {
          description: "Takes the socket, subscribes to the host, and starts renewing the lease.",
          sends: [m.Subscribe, m.Welcome],
          starts: ["renew"],
          run(state, _msg, ctx) {
            state.socket = true;
            state.open = null;
            state.opening = false;
            ctx.send(ctx.the(HostDO), m.Subscribe, {});
            ctx.start("renew");
            ctx.reply(m.Welcome, {});
          },
        },
        [m.Subscribed]: {
          description: "Learns the host's current head, epoch and progress, and catches the tab up if it is behind.",
          sends: [m.Read, m.Reset, m.Progress],
          run(state, msg, ctx) {
            if (!state.socket) return;
            state.subscribed = true;
            heard(state, msg, ctx);
          },
        },
        [spec.failed(m.Subscribe)]: {
          description: "The subscription call threw; the next renewal tries again.",
          run: (state) => void (state.subscribed = false),
        },
        renew: {
          description: "Renews the lease on the host while the socket is open; the answer also carries the current head. A batch still unacknowledged is sent again.",
          after: "30 seconds",
          routine: true,
          sends: [m.Subscribe, m.Read],
          starts: ["renew"],
          run(state, ctx) {
            if (!state.socket) return;
            ctx.send(ctx.the(HostDO), m.Subscribe, {});
            ctx.start("renew");
            const open = state.open;
            if (open && open.sent > open.acked && !state.reading) {
              // The tab ignores records it already holds, so a resend is harmless.
              open.sent = open.acked;
              open.outstanding = 0;
              deliver(state, ctx);
            }
          },
        },
        [m.Notify]: {
          description: "A notice from the host: a new head, a new epoch, or a progress snapshot.",
          sends: [m.Noted, m.Read, m.Reset, m.Progress],
          run(state, msg, ctx) {
            ctx.reply(m.Noted, {});
            if (state.socket) heard(state, msg, ctx);
          },
        },
        [m.Open]: {
          description: "Opens the Session for the tab: reads what follows its cursor in the same epoch, or the last records.",
          sends: [m.Read],
          run(state, msg, ctx) {
            if (!state.socket) return;
            const have = msg.have && msg.have.epoch === state.epoch ? msg.have.cursor : null;
            const after = have ?? Math.max(0, state.head - WINDOW);
            state.open = { epoch: state.epoch, sent: after, acked: after, older: have === null ? after : 0, outstanding: 0 };
            state.stale = false;
            state.opening = true;
            state.reading = true;
            state.reads += 1;
            ctx.send(ctx.the(SessionDO), m.Read, { id: state.reads, kind: "open", after, before: 0, epoch: state.epoch });
          },
        },
        [m.ReadResult]: {
          description: "Sends the records to the tab: the opening window, a live batch, or an older page.",
          sends: [m.Opened, m.Records, m.OlderPage, m.Read],
          run(state, msg, ctx) {
            if (msg.kind !== "older" && msg.id !== state.reads) return;
            if (msg.kind !== "older") state.reading = false;
            const open = state.open;
            if (!state.socket || !open || msg.epoch !== open.epoch) return;
            state.head = Math.max(state.head, msg.head);
            const tab = ctx.the(Tab);
            if (msg.kind === "older") {
              const first = msg.records[0]?.cursor ?? 1;
              return ctx.send(tab, m.OlderPage, { epoch: msg.epoch, records: msg.records, older: first - 1 });
            }
            const last = msg.records.at(-1)?.cursor ?? open.sent;
            if (msg.kind === "open") {
              state.opening = false;
              open.sent = last;
              open.acked = last;
              ctx.send(tab, m.Opened, { epoch: msg.epoch, records: msg.records, cursor: last, older: open.older, progress: state.progress });
              return deliver(state, ctx);
            }
            if (!msg.records.length) return deliver(state, ctx);
            open.sent = last;
            open.outstanding += 1;
            ctx.send(tab, m.Records, { epoch: msg.epoch, records: msg.records, cursor: last });
          },
        },
        [m.ReadReset]: {
          description: "The Session was cut back while reading: the tab is told to drop what follows the common prefix.",
          sends: [m.Reset, m.Read, m.Opened],
          run(state, msg, ctx) {
            if (msg.kind === "older" || msg.id !== state.reads) return;
            state.reading = false;
            if (!state.socket || !state.open) return;
            reset(state, msg.epoch, msg.keep, ctx);
          },
        },
        [spec.failed(m.Read)]: {
          description: "A read threw: the next notice, acknowledgement or renewal reads again.",
          sends: [m.Read],
          run(state, f, ctx) {
            if (f.payload.kind === "older" || f.payload.id !== state.reads) return;
            state.reading = false;
            if (f.payload.kind === "open" && state.open) {
              state.reading = true;
              state.reads += 1;
              return ctx.send(ctx.the(SessionDO), m.Read, { ...f.payload, id: state.reads });
            }
          },
        },
        [m.Ack]: {
          description: "The tab has processed records up to here: the next batch may go.",
          sends: [m.Read],
          run(state, msg, ctx) {
            const open = state.open;
            if (!open || msg.cursor < open.acked || msg.cursor > open.sent) return;
            open.acked = msg.cursor;
            if (open.acked === open.sent) open.outstanding = 0;
            deliver(state, ctx);
          },
        },
        [m.Older]: {
          description: "Reads a page of older records for the tab.",
          sends: [m.Read],
          run(state, msg, ctx) {
            if (!state.open) return;
            ctx.send(ctx.the(SessionDO), m.Read, { id: 0, kind: "older", after: 0, before: msg.before, epoch: state.open.epoch });
          },
        },
        [m.Command]: {
          description: "Forwards the tab's prompt to the host.",
          sends: [m.Forward],
          run: (_state, _msg, ctx) => ctx.send(ctx.the(HostDO), m.Forward, {}),
        },
        [m.Forwarded]: { description: "Tells the tab the prompt was accepted.", sends: [m.Accepted], run: (s, _m, ctx) => void (s.socket && ctx.send(ctx.the(Tab), m.Accepted, {})) },
        [m.HostOffline]: { description: "Tells the tab the Mac is offline; nothing was stored.", sends: [m.Offline], run: (s, _m, ctx) => void (s.socket && ctx.send(ctx.the(Tab), m.Offline, {})) },
        [spec.failed(m.Forward)]: { description: "The command call threw after it may have reached the Mac.", sends: [m.MayHaveRun], run: (s, _f, ctx) => void (s.socket && ctx.send(ctx.the(Tab), m.MayHaveRun, {})) },
        [m.Bye]: {
          description: "The tab's socket closed: unsubscribe from the host and forget the open Session.",
          sends: [m.Unsubscribe],
          run(state, _msg, ctx) {
            state.socket = false;
            state.subscribed = false;
            state.open = null;
            state.opening = false;
            ctx.cancel("renew");
            ctx.send(ctx.the(HostDO), m.Unsubscribe, {});
          },
        },
      },
    });

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
        if (state.open && !state.opening) ctx.send(ctx.the(Tab), m.Progress, { snapshot: msg.progress });
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
      ctx.send(ctx.the(SessionDO), m.Read, { id: state.reads, kind: "live", after: open.sent, before: 0, epoch: open.epoch });
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
        ctx.send(ctx.the(SessionDO), m.Read, { id: state.reads, kind: "open", after: open.sent, before: 0, epoch });
        return;
      }
      ctx.send(ctx.the(Tab), m.Reset, { epoch, keep });
      deliver(state, ctx);
    }

    const HostDO = spec.defineActor({
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
        /** A commit or truncate is waiting on the SessionDO. */
        busy: false,
        truncated: false,
      }),
      durable: ["head", "epoch", "subscriber", "truncated"],
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
          label: "axod uploads a record",
          description: "A line from the Mac is committed to the SessionDO.",
          when: (s) => s.online && !s.busy && s.head < MAX_RECORDS,
          sends: [m.Commit],
          run(state, _i, ctx) {
            state.busy = true;
            ctx.send(ctx.the(SessionDO), m.Commit, { line: line(state.epoch, state.head + 1) });
          },
        },
        stream: {
          label: "axod sends progress",
          description: "A snapshot of the reply being written arrives; the newest replaces the last.",
          when: (s) => s.online && s.head < MAX_RECORDS && s.progress?.text !== "more",
          sends: [m.Notify],
          run(state, _i, ctx) {
            state.progress = { for: state.head + 1, text: state.progress ? "more" : "partial" };
            notify(state, ctx);
          },
        },
        truncate: {
          label: "The Session diverged",
          description: "The handshake found a divergence; the SessionDO is cut back to its first record.",
          when: (s) => s.online && !s.busy && !s.truncated && s.head >= 2,
          sends: [m.Cut],
          run(state, _i, ctx) {
            state.busy = true;
            state.truncated = true;
            ctx.send(ctx.the(SessionDO), m.Cut, { keep: 1 });
          },
        },
        goOffline: {
          label: "The Mac goes offline",
          description: "axod's socket closes.",
          when: (s) => s.online,
          run(state) {
            state.online = false;
            state.progress = null;
          },
        },
        goOnline: { label: "The Mac comes back", description: "axod reconnects.", when: (s) => !s.online, run: (s) => void (s.online = true) },
      },
      transitions: {
        [m.Subscribe]: {
          description: "Adds or renews the ClientDO's lease and answers with the current head, epoch and progress.",
          sends: [m.Subscribed],
          starts: ["leaseExpires"],
          run(state, _msg, ctx) {
            state.subscriber = true;
            ctx.start("leaseExpires");
            ctx.reply(m.Subscribed, { head: state.head, epoch: state.epoch, progress: state.progress?.text ?? null });
          },
        },
        [m.Unsubscribe]: {
          description: "The tab's socket closed: the lease ends.",
          run(state, _msg, ctx) {
            state.subscriber = false;
            ctx.cancel("leaseExpires");
          },
        },
        leaseExpires: {
          description: "No renewal in time: the lease ends and no more notices go to that ClientDO.",
          after: "60 seconds",
          routine: true,
          run: (state) => void (state.subscriber = false),
        },
        [m.Committed]: {
          description: "The record is committed: the progress it completes is cleared, and subscribers hear the new head.",
          sends: [m.Notify],
          run(state, msg, ctx) {
            state.busy = false;
            if (msg.epoch !== state.epoch) return;
            state.head = msg.head;
            if (state.progress && state.progress.for <= msg.head) state.progress = null;
            notify(state, ctx);
          },
        },
        [spec.failed(m.Commit)]: {
          description: "The commit may or may not have happened: axod syncs again (session-sync.ts), and the handshake reads the SessionDO's head.",
          sends: [m.Head],
          run: (_state, _f, ctx) => ctx.send(ctx.the(SessionDO), m.Head, {}),
        },
        [m.HeadIs]: {
          description: "The index's head is refreshed from the SessionDO, and subscribers hear it.",
          sends: [m.Notify],
          run(state, msg, ctx) {
            state.busy = false;
            state.head = msg.head;
            state.epoch = msg.epoch;
            if (state.progress && state.progress.for <= msg.head) state.progress = null;
            notify(state, ctx);
          },
        },
        [spec.failed(m.Head)]: {
          description: "The read threw: the handshake runs again.",
          sends: [m.Head],
          run: (_state, _f, ctx) => ctx.send(ctx.the(SessionDO), m.Head, {}),
        },
        [m.CutDone]: {
          description: "The Session is cut back in a new epoch: subscribers hear the new epoch and head.",
          sends: [m.Notify],
          run(state, msg, ctx) {
            state.busy = false;
            state.epoch = msg.epoch;
            state.head = msg.head;
            state.progress = null;
            notify(state, ctx);
          },
        },
        [spec.failed(m.Cut)]: { description: "The truncate may or may not have happened; axod syncs again.", run: (state) => void ((state.busy = false), (state.truncated = false)) },
        [m.Noted]: { description: "The ClientDO took the notice.", run: () => {} },
        [spec.failed(m.Notify)]: {
          description: "The notice failed: that ClientDO is dropped from the leases; its next renewal adds it back.",
          run(state, _f, ctx) {
            state.subscriber = false;
            ctx.cancel("leaseExpires");
          },
          starts: [],
        },
        [m.Forward]: {
          description: "Forwards the prompt to axod, or answers at once that the Mac is offline. Nothing is stored.",
          sends: [m.Forwarded, m.HostOffline],
          run(state, _msg, ctx) {
            ctx.reply(state.online ? m.Forwarded : m.HostOffline, {});
          },
        },
      },
    });

    function notify(state: any, ctx: any): void {
      if (state.subscriber) ctx.send(ctx.the(ClientDO), m.Notify, { head: state.head, epoch: state.epoch, progress: state.progress?.text ?? null });
    }

    const SessionDO = spec.defineActor({
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
      durable: ["epoch", "records", "cuts"],
      display: {
        icon: "database",
        status: (s) => `${s.records.length} record(s), epoch ${s.epoch}`,
        rows: (s) => s.records.map((l, i) => ({ group: `epoch ${s.epoch}`, label: `${i + 1}`, detail: l })),
      },
      transitions: {
        [m.Commit]: {
          description: "Appends the record.",
          sends: [m.Committed],
          run(state, msg, ctx) {
            state.records.push(`${state.epoch}.${state.records.length + 1}`);
            void msg;
            ctx.reply(m.Committed, { head: state.records.length, epoch: state.epoch });
          },
        },
        [m.Read]: {
          description: "Returns one record after a cursor, or two before one; a reader from an older epoch is told the new epoch and how much of what it read still stands.",
          sends: [m.ReadResult, m.ReadReset],
          run(state, msg, ctx) {
            if (msg.epoch !== state.epoch) {
              const keep = Math.min(...state.cuts.filter((c) => c.epoch > msg.epoch).map((c) => c.keep));
              return ctx.reply(m.ReadReset, { id: msg.id, kind: msg.kind, epoch: state.epoch, keep });
            }
            const all = state.records.map((l, i) => ({ cursor: i + 1, line: l }));
            const records =
              msg.kind === "older"
                ? all.filter((r) => r.cursor < msg.before).slice(-WINDOW)
                : msg.kind === "open"
                  ? all.filter((r) => r.cursor > msg.after)
                  : all.filter((r) => r.cursor > msg.after).slice(0, 1);
            ctx.reply(m.ReadResult, { id: msg.id, kind: msg.kind, epoch: state.epoch, records, head: state.records.length });
          },
        },
        [m.Head]: {
          description: "Says how many records it holds, in which epoch.",
          sends: [m.HeadIs],
          run: (state, _msg, ctx) => ctx.reply(m.HeadIs, { head: state.records.length, epoch: state.epoch }),
        },
        [m.Cut]: {
          description: "Deletes the records past the prefix and starts a new epoch.",
          sends: [m.CutDone],
          run(state, msg, ctx) {
            state.records = state.records.slice(0, msg.keep);
            state.epoch += 1;
            state.cuts.push({ epoch: state.epoch, keep: msg.keep });
            ctx.reply(m.CutDone, { head: state.records.length, epoch: state.epoch });
          },
        },
      },
    });

    spec.defineProperties({
      noGapsNoDuplicates: {
        description: "The records a tab holds are one contiguous run of cursors, with no gaps and no duplicates.",
        always: (w) => w.the(Tab).state.records.every((r, i, all) => i === 0 || r.cursor === all[i - 1]!.cursor + 1),
      },
      holdsWhatTheCloudHolds: {
        description: "Every record a tab holds in the Session's current epoch is the record the SessionDO holds at that cursor.",
        always: (w) => {
          const tab = w.the(Tab).state;
          const session = w.the(SessionDO).state;
          return tab.epoch !== session.epoch || tab.records.every((r) => session.records[r.cursor - 1] === r.line);
        },
      },
      oneBatchOutstanding: {
        description: "A ClientDO never has more than one batch of records waiting for the tab's acknowledgement.",
        always: (w) => (w.the(ClientDO).state.open?.outstanding ?? 0) <= 1,
      },
      progressEndsWithItsRecord: {
        description: "Once the record a snapshot previews is committed, no snapshot of it remains.",
        always: (w) => {
          const progress = w.the(HostDO).state.progress;
          return progress === null || progress.for > w.the(HostDO).state.head;
        },
      },
      promptsAreAnswered: {
        description: "A prompt sent from a connected tab is answered: accepted, offline, or may have run. None waits forever.",
        leadsTo: { whenever: (w) => w.the(Tab).state.prompt === "sending", then: (w) => w.the(Tab).state.prompt !== "sending" },
      },
      catchesUp: {
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
      },
    });

    spec.defineScenario({
      name: "Opening the web app",
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
    spec.defineScenario({
      name: "A reply streams in",
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
    spec.defineScenario({
      name: "A backgrounded tab",
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
    spec.defineScenario({
      name: "Reconnecting with records in hand",
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
    spec.defineScenario({
      name: "The Session is cut back",
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
    spec.defineScenario({
      name: "A prompt while the Mac sleeps",
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

    return { Tab, ClientDO, HostDO, SessionDO };
  },
);
