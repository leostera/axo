import { call, defineSpec, message } from "@leostera/feynman";

// RFD0018, Upload: once paired, axod uploads every Session's Pi transcript to the cloud, line by
// line, and the cloud's copy ends up equal to the host's file.
//
// One Session is modelled, with a file of at most three lines. The hash chain is modelled as the
// prefix itself ("h|l1|l2"): two chains are equal exactly when the prefixes are, which is what the
// real sha256 chain gives us barring collisions. Batches are one line, and at most two appends wait
// for an acknowledgement at once. A socket has an id, which every message carries, so replies on a
// socket that closed are ignored. The Feynman network lets any message overtake another; on the real
// socket messages keep their order, so this checks something stronger than we need.
//
// Not modelled: several Sessions and their upload order, progress (client-delivery.ts), metadata
// beyond "present on the Mac", the content hashes of records (a line is its own hash here).

const MAX_LINES = 3;
const MAX_IN_FLIGHT = 2;

type Phase = "offline" | "handshake" | "searching" | "truncating" | "uploading";
type Cursor = { count: number; chain: string } | null;

/** The hash chain over the first `n` lines, starting from the header. */
function chainOf(lines: readonly string[], n: number): string {
  return ["h", ...lines.slice(0, n)].join("|");
}
function same(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((line, i) => line === b[i]);
}

export default defineSpec(
  "Session sync",
  {
    description:
      "How a paired axod uploads a Session's transcript: a sync handshake on every connect tells it what the cloud holds, appends are acknowledged only once committed, and a diverged copy is cut back to the common prefix.",
    messages: {
      Sync: message<{ socket: number; round: number; present: boolean; version: number; count: number; chain: string }>({ name: "axo.host.sync", over: "websocket" }),
      SyncReply: message<{ socket: number; round: number; exists: boolean; epoch: number; count: number; chain: string }>({ name: "what the cloud holds", over: "websocket", tone: "reply" }),
      Resync: message<{ socket: number }>({ name: "rejected: sync again", over: "websocket", tone: "refused" }),
      Append: message<{ socket: number; epoch: number; from: number; line: string }>({ name: "axo.host.session.append", over: "websocket" }),
      Appended: message<{ socket: number; count: number; chain: string }>({ name: "committed", over: "websocket", tone: "reply" }),
      ChainAt: message<{ socket: number; round: number }>({ name: "axo.host.session.chainAt", over: "websocket" }),
      Chains: message<{ socket: number; round: number; chains: string[] }>({ name: "the cloud's chains", over: "websocket", tone: "reply" }),
      Truncate: message<{ socket: number; round: number; keep: number; expectedChain: string }>({ name: "axo.host.session.truncate", over: "websocket" }),
      Truncated: message<{ socket: number; round: number; epoch: number }>({ name: "truncated", over: "websocket", tone: "reply" }),
      Meta: message<{ socket: number; present: boolean; version: number }>({ name: "axo.host.session.meta", over: "websocket" }),
      MetaStored: message<{ socket: number }>({ name: "metadata stored", over: "websocket", tone: "reply" }),

      Head: call<{ socket: number; round: number }>({ name: "SessionDO.head", over: "rpc" }),
      HeadIs: message<{ socket: number; round: number; exists: boolean; epoch: number; count: number; chain: string }>({ name: "head", over: "rpc", tone: "reply" }),
      Store: call<{ socket: number; epoch: number; from: number; line: string }>({ name: "SessionDO.append", over: "rpc" }),
      Stored: message<{ socket: number; count: number; chain: string }>({ name: "committed", over: "rpc", tone: "reply" }),
      StoreRejected: message<{ socket: number; reason: "gap" | "conflict" | "epoch" }>({ name: "append rejected", over: "rpc", tone: "refused" }),
      ReadChains: call<{ socket: number; round: number }>({ name: "SessionDO.chainAt", over: "rpc" }),
      ChainsAre: message<{ socket: number; round: number; chains: string[] }>({ name: "chains", over: "rpc", tone: "reply" }),
      Cut: call<{ socket: number; round: number; keep: number; expectedChain: string }>({ name: "SessionDO.truncate", over: "rpc" }),
      CutDone: message<{ socket: number; round: number; epoch: number }>({ name: "truncated", over: "rpc", tone: "reply" }),
      CutRejected: message<{ socket: number }>({ name: "truncate rejected", over: "rpc", tone: "refused" }),
    },
  },
  (spec) => {
    const { Sync, SyncReply, Resync, Append, Appended, ChainAt, Chains, Truncate, Truncated, Meta, MetaStored, Head, HeadIs, Store, Stored, StoreRejected, ReadChains, ChainsAre, Cut, CutDone, CutRejected } = spec.messages;

    const mac = spec.defineZone({ name: "Host Mac", description: "Pi writes, axod uploads", place: { column: 0 } });
    const cloud = spec.defineZone({ name: "Cloudflare", description: "one HostDO per host, one SessionDO per Session", place: { column: 1, region: true } });

    spec.defineLimit({ name: "Lines per append batch", value: 64, unit: "records" });
    spec.defineLimit({ name: "Append batches waiting for acknowledgement, per Session", value: 4, unit: "batches" });
    spec.defineLimit({ name: "A request with no answer for this long starts the handshake again", value: 10, unit: "seconds" });

    const Axod = spec.defineActor({
      name: "axod relay",
      description: "The Mac's daemon: it tails the Session's Pi file and uploads it over its one socket to the cloud.",
      zone: mac,
      singleton: true,
      initialState: () => ({
        /** The Pi session file on disk, without its header. */
        lines: [] as string[],
        /** Every (position, line) the file has ever held; the cloud may only hold these. */
        written: new Set<string>(),
        /** The Session still exists on the Mac. */
        present: true,
        /** The last position and chain the cloud acknowledged, kept in axo.db. */
        cursor: null as Cursor,
        /** Sockets opened so far; the newest is the current one. */
        sockets: 0,
        /** Handshakes started so far, across sockets; only the newest one's answers count. */
        round: 0,
        connected: false,
        phase: "offline" as Phase,
        /** The cloud copy's epoch, from the handshake. */
        epoch: 0,
        /** The next position to send. */
        next: 1,
        inFlight: 0,
        /** Where a truncate will cut. */
        keep: 0,
        /** A metadata change waits for the cloud's acknowledgement. */
        metaPending: false,
        /** The Session's metadata version, raised on every change, kept in axo.db. */
        version: 1,
      }),
      durable: ["lines", "written", "present", "cursor", "sockets", "round", "version"],
      display: {
        icon: "laptop",
        status: (s) => (s.connected ? `${s.phase}, ${s.lines.length} line(s), cloud acked ${s.cursor?.count ?? "nothing"}` : "offline"),
        mood: (s) => (!s.connected ? "off" : s.phase === "uploading" ? "ok" : "busy"),
        rows: (s) => [
          { label: "session file", detail: s.present ? s.lines.join(", ") || "empty" : "deleted", mood: s.present ? "info" : "off" },
          { label: "axo.db cursor", detail: s.cursor ? `${s.cursor.count}` : "none" },
        ],
      },
      links: (s) => (s.connected ? [{ to: "HostDO", kind: "websocket" }] : []),
      actions: {
        piWrites: {
          label: "Pi appends a line",
          description: "Pi finishes an entry and appends it to the Session's file.",
          when: (s) => s.present && s.lines.length < MAX_LINES,
          sends: [Append],
          starts: ["requestTimeout"],
          run(state, _i, ctx) {
            const line = `l${state.lines.length + 1}`;
            state.lines.push(line);
            state.written.add(`${state.lines.length}:${line}`);
            pump(state, ctx);
          },
        },
        rewriteFile: {
          label: "The file is rewritten",
          description: "A Pi format migration or a restore from backup rewrites the file's first line.",
          when: (s) => s.present && s.lines.length > 0 && !s.lines[0]!.endsWith("'"),
          sends: [Sync],
          starts: ["requestTimeout"],
          run(state, _i, ctx) {
            state.lines[0] = `${state.lines[0]}'`;
            state.written.add(`1:${state.lines[0]}`);
            // The file watcher sees a change that isn't an append and syncs the Session again.
            if (state.connected) handshake(state, ctx);
          },
        },
        resetDb: {
          label: "axo.db is reset",
          description: "axod loses its stored upload cursors.",
          when: (s) => s.cursor !== null,
          run: (state) => void (state.cursor = null),
        },
        deleteSession: {
          label: "Delete the Session on the Mac",
          description: "The person deletes the Session to save space; it disappears from the next manifest.",
          when: (s) => s.present,
          sends: [Meta],
          starts: ["requestTimeout"],
          run(state, _i, ctx) {
            state.present = false;
            state.version += 1;
            state.next = state.lines.length + 1;
            if (!state.connected) return;
            state.metaPending = true;
            ctx.send(ctx.the(HostDO), Meta, { socket: state.sockets, present: false, version: state.version });
            ctx.start("requestTimeout");
          },
        },
        dropSocket: {
          label: "The socket drops",
          description: "The network goes away; every reply still on its way is lost with the socket.",
          when: (s) => s.connected,
          run(state, _i, ctx) {
            state.connected = false;
            state.phase = "offline";
            state.inFlight = 0;
            state.metaPending = false;
            ctx.cancel("requestTimeout");
          },
        },
      },
      transitions: {
        reconnect: {
          description: "The reconnect loop opens a new socket and starts the sync handshake.",
          when: (s) => !s.connected,
          sends: [Sync],
          starts: ["requestTimeout"],
          run(state, ctx) {
            state.sockets += 1;
            state.connected = true;
            handshake(state, ctx);
          },
        },
        [SyncReply]: {
          description: "Compares what the cloud holds with the file: upload from scratch, continue after the cloud's prefix, or look for where they diverged.",
          sends: [Append, ChainAt],
          starts: ["requestTimeout"],
          say: (s) => `Cloud reply handled: ${s.phase}, next line ${s.next}`,
          run(state, m, ctx) {
            if (m.socket !== state.sockets || m.round !== state.round || state.phase !== "handshake") return;
            if (!m.exists) {
              state.epoch = m.epoch;
              state.next = 1;
              state.phase = "uploading";
              return pump(state, ctx);
            }
            if (m.count <= state.lines.length && chainOf(state.lines, m.count) === m.chain) {
              // The cloud's answer wins over axo.db.
              state.epoch = m.epoch;
              state.cursor = { count: m.count, chain: m.chain };
              state.next = m.count + 1;
              state.phase = "uploading";
              return pump(state, ctx);
            }
            state.phase = "searching";
            ctx.send(ctx.the(HostDO), ChainAt, { socket: state.sockets, round: state.round });
            ctx.start("requestTimeout");
          },
        },
        [Chains]: {
          description: "Finds the longest prefix both copies share and asks the cloud to cut back to it, lowering its own cursor first.",
          sends: [Truncate],
          starts: ["requestTimeout"],
          run(state, m, ctx) {
            if (m.socket !== state.sockets || m.round !== state.round || state.phase !== "searching") return;
            let keep = 0;
            for (let n = 1; n <= Math.min(state.lines.length, m.chains.length - 1); n++) if (m.chains[n] === chainOf(state.lines, n)) keep = n;
            state.keep = keep;
            // Never claim the cloud holds records it is about to delete.
            if (state.cursor && state.cursor.count > keep) state.cursor = { count: keep, chain: chainOf(state.lines, keep) };
            state.phase = "truncating";
            ctx.send(ctx.the(HostDO), Truncate, { socket: state.sockets, round: state.round, keep, expectedChain: chainOf(state.lines, keep) });
            ctx.start("requestTimeout");
          },
        },
        [Truncated]: {
          description: "The cloud copy is back to the common prefix, in a new epoch; upload continues after it.",
          sends: [Append],
          starts: ["requestTimeout"],
          run(state, m, ctx) {
            if (m.socket !== state.sockets || m.round !== state.round || state.phase !== "truncating") return;
            state.epoch = m.epoch;
            state.next = state.keep + 1;
            state.inFlight = 0;
            state.phase = "uploading";
            pump(state, ctx);
          },
        },
        [Appended]: {
          description: "A line is committed: the cursor in axo.db moves, if the line is still the file's, and the next line goes.",
          sends: [Append],
          starts: ["requestTimeout"],
          run(state, m, ctx) {
            if (m.socket !== state.sockets) return;
            state.inFlight = Math.max(0, state.inFlight - 1);
            if (chainOf(state.lines, m.count) === m.chain && (state.cursor?.count ?? 0) < m.count) state.cursor = { count: m.count, chain: m.chain };
            pump(state, ctx);
          },
        },
        [MetaStored]: {
          description: "The cloud has the metadata change.",
          starts: ["requestTimeout"],
          run(state, m, ctx) {
            if (m.socket !== state.sockets) return;
            state.metaPending = false;
            settleTimer(state, ctx);
          },
        },
        requestTimeout: {
          description: "A request got no answer in time (its message or the socket was lost): the handshake runs again, and its answer says what the cloud holds.",
          after: "10 seconds",
          sends: [Sync],
          starts: ["requestTimeout"],
          run(state, ctx) {
            if (state.connected && outstanding(state)) handshake(state, ctx);
          },
        },
        [Resync]: {
          description: "The cloud refused an append or a step of the handshake: start the handshake again.",
          sends: [Sync],
          starts: ["requestTimeout"],
          run(state, m, ctx) {
            if (m.socket !== state.sockets || !state.connected) return;
            handshake(state, ctx);
          },
        },
      },
    });

    function handshake(state: any, ctx: any): void {
      state.round += 1;
      state.phase = "handshake";
      state.inFlight = 0;
      // The manifest carries metadata too, so a pending change rides on it.
      state.metaPending = false;
      ctx.send(ctx.the(HostDO), Sync, { socket: state.sockets, round: state.round, present: state.present, version: state.version, count: state.lines.length, chain: chainOf(state.lines, state.lines.length) });
      ctx.start("requestTimeout");
    }
    /** Something sent on this socket still waits for its answer. */
    function outstanding(state: any): boolean {
      return state.phase === "handshake" || state.phase === "searching" || state.phase === "truncating" || state.inFlight > 0 || state.metaPending;
    }
    /** The request timer runs exactly while something waits for an answer. */
    function settleTimer(state: any, ctx: any): void {
      if (outstanding(state)) ctx.start("requestTimeout");
      else ctx.cancel("requestTimeout");
    }
    /** Sends the next lines while fewer than the limit wait for an acknowledgement. */
    function pump(state: any, ctx: any): void {
      if (!state.connected || state.phase !== "uploading" || !state.present) return settleTimer(state, ctx);
      while (state.inFlight < MAX_IN_FLIGHT && state.next <= state.lines.length) {
        ctx.send(ctx.the(HostDO), Append, { socket: state.sockets, epoch: state.epoch, from: state.next, line: state.lines[state.next - 1] });
        state.next += 1;
        state.inFlight += 1;
      }
      settleTimer(state, ctx);
    }

    const HostDO = spec.defineActor({
      name: "HostDO",
      description: "The host's Durable Object: it owns axod's socket, keeps the host's Session index, and routes uploads to the SessionDO.",
      zone: cloud,
      singleton: true,
      initialState: () => ({
        /** The socket axod opened last; messages on older sockets are ignored. Hibernation keeps it. */
        socket: 0,
        /** The newest handshake round seen; an older manifest never overwrites a newer one. */
        round: 0,
        /** The Session's row in the host's index. */
        known: false,
        archived: false,
        /** The metadata version the row holds; an older change never overwrites a newer one. */
        version: 0,
      }),
      durable: ["socket", "round", "known", "archived", "version"],
      display: {
        icon: "cloud",
        status: (s) => (s.socket ? `socket ${s.socket}` : "no socket"),
        rows: (s) => (s.known ? [{ label: "Session", detail: s.archived ? "archived" : "on the Mac", mood: s.archived ? "off" : "ok" }] : []),
      },
      transitions: {
        [Sync]: {
          description: "Takes the socket, updates the index from the manifest (a Session missing from it is archived, never deleted), and asks the SessionDO what it holds.",
          sends: [Head],
          run(state, m, ctx) {
            if (m.socket < state.socket || m.round <= state.round) return;
            state.socket = m.socket;
            state.round = m.round;
            applyMeta(state, m.present, m.version);
            ctx.send(ctx.the(SessionDO), Head, { socket: m.socket, round: m.round });
          },
        },
        [Meta]: {
          description: "Updates the Session's row: a Session deleted on the Mac is archived, never deleted.",
          sends: [MetaStored],
          run(state, m, ctx) {
            if (m.socket !== state.socket) return;
            applyMeta(state, m.present, m.version);
            ctx.send(ctx.the(Axod), MetaStored, { socket: m.socket });
          },
        },
        [HeadIs]: {
          description: "Answers the handshake with the SessionDO's head.",
          sends: [SyncReply],
          run(state, m, ctx) {
            if (m.socket === state.socket) ctx.send(ctx.the(Axod), SyncReply, m);
          },
        },
        [Append]: {
          description: "Routes the append to the SessionDO; it is acknowledged only after the SessionDO commits.",
          sends: [Store],
          run(state, m, ctx) {
            if (m.socket === state.socket) ctx.send(ctx.the(SessionDO), Store, m);
          },
        },
        [Stored]: {
          description: "Acknowledges the committed line to axod.",
          sends: [Appended],
          run(state, m, ctx) {
            if (m.socket === state.socket) ctx.send(ctx.the(Axod), Appended, m);
          },
        },
        [StoreRejected]: {
          description: "A gap, a conflict or a stale epoch: axod syncs again.",
          sends: [Resync],
          run(state, m, ctx) {
            if (m.socket === state.socket) ctx.send(ctx.the(Axod), Resync, { socket: m.socket });
          },
        },
        [ChainAt]: {
          description: "Reads the SessionDO's chain at each position, for axod's search for the common prefix.",
          sends: [ReadChains],
          run(state, m, ctx) {
            if (m.socket === state.socket) ctx.send(ctx.the(SessionDO), ReadChains, m);
          },
        },
        [ChainsAre]: {
          description: "Returns the chains to axod.",
          sends: [Chains],
          run(state, m, ctx) {
            if (m.socket === state.socket) ctx.send(ctx.the(Axod), Chains, m);
          },
        },
        [Truncate]: {
          description: "Asks the SessionDO to cut back to the common prefix.",
          sends: [Cut],
          run(state, m, ctx) {
            if (m.socket === state.socket) ctx.send(ctx.the(SessionDO), Cut, m);
          },
        },
        [CutDone]: {
          description: "Tells axod the copy is cut back, in a new epoch.",
          sends: [Truncated],
          run(state, m, ctx) {
            if (m.socket === state.socket) ctx.send(ctx.the(Axod), Truncated, m);
          },
        },
        [CutRejected]: {
          description: "The prefix axod asked to keep isn't what the cloud holds any more: sync again.",
          sends: [Resync],
          run(state, m, ctx) {
            if (m.socket === state.socket) ctx.send(ctx.the(Axod), Resync, { socket: m.socket });
          },
        },
        [spec.failed(Head)]: {
          description: "The SessionDO call threw: axod syncs again.",
          sends: [Resync],
          run(state, f, ctx) {
            if (f.payload.socket === state.socket) ctx.send(ctx.the(Axod), Resync, { socket: f.payload.socket });
          },
        },
        [spec.failed(Store)]: {
          description: "The append may or may not have committed: axod syncs again, and the handshake says which.",
          sends: [Resync],
          run(state, f, ctx) {
            if (f.payload.socket === state.socket) ctx.send(ctx.the(Axod), Resync, { socket: f.payload.socket });
          },
        },
        [spec.failed(ReadChains)]: {
          description: "The read threw: axod syncs again.",
          sends: [Resync],
          run(state, f, ctx) {
            if (f.payload.socket === state.socket) ctx.send(ctx.the(Axod), Resync, { socket: f.payload.socket });
          },
        },
        [spec.failed(Cut)]: {
          description: "The truncate may or may not have happened: axod syncs again.",
          sends: [Resync],
          run(state, f, ctx) {
            if (f.payload.socket === state.socket) ctx.send(ctx.the(Axod), Resync, { socket: f.payload.socket });
          },
        },
      },
    });

    /** Applies a metadata row if it is newer: present on the Mac, or archived (never deleted). */
    function applyMeta(state: any, present: boolean, version: number): void {
      if (version <= state.version) return;
      state.version = version;
      if (present) {
        state.known = true;
        state.archived = false;
      } else if (state.known) state.archived = true;
    }

    const SessionDO = spec.defineActor({
      name: "SessionDO",
      description: "The Session's Durable Object: the cloud copy of its transcript, append-only within an epoch.",
      zone: cloud,
      singleton: true,
      initialState: () => ({ exists: false, epoch: 1, records: [] as string[] }),
      durable: ["exists", "epoch", "records"],
      display: {
        icon: "database",
        status: (s) => (s.exists ? `${s.records.length} record(s), epoch ${s.epoch}` : "not created"),
        rows: (s) => s.records.map((line, i) => ({ group: `epoch ${s.epoch}`, label: `${i + 1}`, detail: line })),
      },
      transitions: {
        [Head]: {
          description: "Says whether the copy exists, its epoch, count and chain.",
          sends: [HeadIs],
          run(state, m, ctx) {
            ctx.reply(HeadIs, { socket: m.socket, round: m.round, exists: state.exists, epoch: state.epoch, count: state.records.length, chain: chainOf(state.records, state.records.length) });
          },
        },
        [Store]: {
          description: "Commits a new line, acknowledges a repeat of a committed one, and rejects a gap, a conflict or a stale epoch.",
          sends: [Stored, StoreRejected],
          run(state, m, ctx) {
            if (m.epoch !== state.epoch) return ctx.reply(StoreRejected, { socket: m.socket, reason: "epoch" });
            if (m.from > state.records.length + 1) return ctx.reply(StoreRejected, { socket: m.socket, reason: "gap" });
            if (m.from <= state.records.length) {
              if (state.records[m.from - 1] !== m.line) return ctx.reply(StoreRejected, { socket: m.socket, reason: "conflict" });
              return ctx.reply(Stored, { socket: m.socket, count: m.from, chain: chainOf(state.records, m.from) });
            }
            state.exists = true;
            state.records.push(m.line);
            ctx.reply(Stored, { socket: m.socket, count: m.from, chain: chainOf(state.records, m.from) });
          },
        },
        [ReadChains]: {
          description: "Returns the chain at every position.",
          sends: [ChainsAre],
          run(state, m, ctx) {
            ctx.reply(ChainsAre, { socket: m.socket, round: m.round, chains: Array.from({ length: state.records.length + 1 }, (_c, n) => chainOf(state.records, n)) });
          },
        },
        [Cut]: {
          description: "Deletes every record past the prefix to keep, if the prefix is what axod expects, and starts a new epoch.",
          sends: [CutDone, CutRejected],
          run(state, m, ctx) {
            if (m.keep > state.records.length || chainOf(state.records, m.keep) !== m.expectedChain) return ctx.reply(CutRejected, { socket: m.socket });
            state.records = state.records.slice(0, m.keep);
            state.epoch += 1;
            ctx.reply(CutDone, { socket: m.socket, round: m.round, epoch: state.epoch });
          },
        },
      },
    });

    spec.defineProperties({
      ackedMeansCommitted: {
        description: "axod's cursor never claims a record the cloud doesn't hold: it only moves past committed records.",
        always: (w) => {
          const cursor = w.the(Axod).state.cursor;
          const records = w.the(SessionDO).state.records;
          return cursor === null || (cursor.count <= records.length && chainOf(records, cursor.count) === cursor.chain);
        },
      },
      cloudHoldsOnlyWhatWasWritten: {
        description: "Every record in the cloud is a line the host's file held at that position.",
        always: (w) => w.the(SessionDO).state.records.every((line, i) => w.the(Axod).state.written.has(`${i + 1}:${line}`)),
      },
      prefixRewrittenOnlyByTruncate: {
        description: "The cloud copy only grows, except when a truncate cuts it back and starts a new epoch.",
        everyStep: (before, after) => {
          const a = before.the(SessionDO).state;
          const b = after.the(SessionDO).state;
          return b.epoch > a.epoch || (b.epoch === a.epoch && a.records.every((line, i) => b.records[i] === line));
        },
      },
      neverDeletedForTheHost: {
        description: "Once the cloud knows the Session, it never forgets it, whatever the host does.",
        everyStep: (before, after) => !before.the(HostDO).state.known || after.the(HostDO).state.known,
      },
      missingMeansArchived: {
        description: "Once quiet, a Session deleted on the Mac is archived in the cloud, not removed.",
        always: (w) => !w.quiet || w.the(Axod).state.present || !w.the(HostDO).state.known || !w.the(Axod).state.connected || w.the(HostDO).state.archived,
      },
      syncedOnceQuiet: {
        description: "Once nothing is in flight on a live socket, the cloud copy equals the host's file.",
        always: (w) => {
          const a = w.the(Axod).state;
          if (!w.quiet || !a.connected || !a.present || a.phase !== "uploading") return true;
          return same(w.the(SessionDO).state.records, a.lines);
        },
      },
      uploadCompletes: {
        description: "Whenever the cloud copy differs from the host's file, it ends up equal.",
        leadsTo: {
          whenever: (w) => w.the(Axod).state.present && !same(w.the(SessionDO).state.records, w.the(Axod).state.lines),
          then: (w) => !w.the(Axod).state.present || same(w.the(SessionDO).state.records, w.the(Axod).state.lines),
        },
      },
    });

    spec.defineScenario({
      name: "Pairing a Mac with history",
      description: "The cloud has never seen the Session: the handshake says so, and axod uploads both lines, two at a time, moving its cursor as each commits.",
      setup(w) {
        w.set(Axod, { lines: ["l1", "l2"], written: new Set(["1:l1", "2:l2"]) });
      },
      run(s) {
        s.settle();
      },
    });
    spec.defineScenario({
      name: "Pi writes while backfill runs",
      description: "A new line arrives while the history uploads; it goes in order after the others.",
      setup(w) {
        w.set(Axod, { lines: ["l1", "l2"], written: new Set(["1:l1", "2:l2"]) });
      },
      run(s) {
        s.settle({ until: (w) => w.the(SessionDO).state.records.length === 1 });
        s.act(s.the(Axod), "piWrites");
        s.settle();
      },
    });
    spec.defineScenario({
      name: "An acknowledgement is lost",
      description: "The SessionDO commits a line, but the socket drops before axod hears it. After reconnecting, the handshake reports the line as held and upload continues after it: nothing is sent twice.",
      setup(w) {
        w.set(Axod, { lines: ["l1", "l2"], written: new Set(["1:l1", "2:l2"]) });
      },
      run(s) {
        s.settle({ until: (w) => w.the(SessionDO).state.records.length === 2 });
        s.act(s.the(Axod), "dropSocket");
        s.settle();
      },
    });
    spec.defineScenario({
      name: "axo.db is reset",
      description: "axod forgets its cursors. The handshake tells it the cloud already holds both lines, so it uploads nothing again.",
      setup(w) {
        w.set(Axod, { lines: ["l1", "l2"], written: new Set(["1:l1", "2:l2"]), cursor: { count: 2, chain: "h|l1|l2" } });
        w.set(SessionDO, { exists: true, records: ["l1", "l2"] });
        w.set(HostDO, { known: true });
      },
      run(s) {
        s.act(s.the(Axod), "resetDb");
        s.settle();
      },
    });
    spec.defineScenario({
      name: "The file is rewritten",
      description: "A migration rewrites the first line. The handshake finds no common prefix, axod lowers its cursor and asks the cloud to cut back to nothing, and the new file is uploaded in a new epoch.",
      setup(w) {
        w.set(Axod, { lines: ["l1", "l2"], written: new Set(["1:l1", "2:l2"]), cursor: { count: 2, chain: "h|l1|l2" } });
        w.set(SessionDO, { exists: true, records: ["l1", "l2"] });
        w.set(HostDO, { known: true });
      },
      run(s) {
        s.settle({ until: (w) => w.the(Axod).state.phase === "uploading" });
        s.act(s.the(Axod), "rewriteFile");
        s.settle();
      },
    });
    spec.defineScenario({
      name: "The Session is deleted on the Mac",
      description: "The Session leaves the manifest; the cloud keeps it and marks it archived.",
      setup(w) {
        w.set(Axod, { lines: ["l1"], written: new Set(["1:l1"]), cursor: { count: 1, chain: "h|l1" } });
        w.set(SessionDO, { exists: true, records: ["l1"] });
        w.set(HostDO, { known: true });
      },
      run(s) {
        s.settle({ until: (w) => w.the(Axod).state.phase === "uploading" });
        s.act(s.the(Axod), "deleteSession");
        s.act(s.the(Axod), "dropSocket");
        s.settle();
      },
    });

    return { Axod, HostDO, SessionDO };
  },
);
