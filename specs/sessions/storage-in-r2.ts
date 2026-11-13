import type { WorldView } from "@leostera/feynman";
import { atMost, budget, defineActor, defineCall, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone, failed, listOf, lose, spend } from "@leostera/feynman";

// RFD0044: a Session's records live in R2 (axo-sessions), as write-once ATXF segments that carry
// each Pi line in `native`. The SessionDO orders appends, keeps each record's hash and chain, and
// holds the lines R2 does not have yet. Once a segment is stored and read back equal, the
// SessionDO drops those lines.
//
// One Session, at most three lines, segments of at most two records, one cut. A line is its own
// hash; its ATXF record is `A(line)`, and the line comes back out of it. A line starting with "x"
// is one the ATXF stream refuses. Time is the order of events: "an hour later" is an alarm that
// may fire at any moment.
//
// `ledger` is not the SessionDO's state: it is what the properties check against, every record
// the SessionDO ever committed, and it survives a wipe. A wipe is the SessionDO losing its storage
// and starting over; the records it had not stored in R2 are lost then, and the ledger marks them.
//
// Not modelled: the HostDO's backfill of Sessions stored before (a scenario's setup stands for
// it), reads by clients (a property checks what they would get), parts, byte budgets, several
// Sessions, and R2 losing an object after it was read back (R2's own durability).

const MAX_LINES = 3;
const SEGMENT_RECORDS = 2;

const faults = budget("faults", 1);

const outbox = defineRule("outbox", {
  description: "The range a segment covers is written down before its PUT, and a retry sends that same range, so a lost answer never leaves two segments that overlap.",
});
const cutKeepsUnstored = defineRule("cutKeepsUnstored", {
  description: "A cut moves every record the SessionDO has not read back from R2 into a side table, in the same transaction; they are stored and read back from there under their old epoch.",
});
const oneAlarm = defineRule("oneAlarm", {
  description: "An object has one alarm. After translating, the alarm handler sets it again for the next segment that is due, not only for translation that remains.",
});
const commitArms = defineRule("commitArms", {
  description: "A commit or a cut that leaves records R2 lacks sets the alarm if none is set.",
});
const generations = defineRule("generations", {
  description: "Object keys carry the generation, a random id the SessionDO takes when its storage is new, so an object that lost its storage and was rebuilt never writes where the old one did.",
});
const readBackBeforeDrop = defineRule("readBackBeforeDrop", {
  description: "Lines are dropped from the SessionDO only after their segment was read back from R2 and every line taken out of it equals the one held.",
});
const checkpoints = defineRule("checkpoints", {
  description: "The ATXF stream's state is saved at the end of every segment, so rebuilding it reads at most one segment, from R2, rather than every line from the start.",
});

const Append = defineCall("Append", { epoch: Number, from: Number, lines: listOf(String) }, { name: "SessionDO.append", over: "rpc" });
const Appended = defineMessage("Appended", { epoch: Number, count: Number }, { name: "committed", over: "rpc", tone: "reply" });
const Truncate = defineCall("Truncate", { keep: Number }, { name: "SessionDO.truncate", over: "rpc" });
const Truncated = defineMessage("Truncated", { epoch: Number }, { name: "truncated", over: "rpc", tone: "reply" });
const Put = defineCall("Put", { id: String, key: String, body: String }, { name: "R2 put, If-None-Match: *", over: "https" });
const Stored = defineMessage("Stored", { id: String, same: Boolean }, { name: "stored", over: "https", tone: "reply" });
const Get = defineCall("Get", { id: String, key: String }, { name: "R2 get", over: "https" });
const Got = defineMessage("Got", { id: String, body: String }, { name: "object", over: "https", tone: "reply" });

const mac = defineZone({ name: "Host Mac", description: "axod uploads the Session's Pi file", place: { column: 0 } });
const cloud = defineZone({ name: "Cloudflare", description: "the Session's Durable Object and the axo-sessions bucket", place: { column: 1, region: true } });

export const Host = defineActor({
  name: "Host",
  description: "axod: appends Pi's new lines to the cloud, cuts it back when its file was rewritten, and starts again from what the cloud says it holds.",
  zone: mac,
  singleton: true,
  initialState: () => ({ file: [] as string[], written: 0, epoch: 1, acked: 0, waiting: false }),
  display: {
    icon: "laptop",
    status: (s) => `${s.file.length} line(s), ${s.acked} acknowledged`,
    rows: (s) => s.file.map((line, i) => ({ group: "file", label: `${i + 1}`, detail: line })),
  },
  actions: {
    write: {
      label: "Pi writes a line",
      description: "Pi appends an entry to the Session's file.",
      when: (s) => s.file.length < MAX_LINES,
      run(s) {
        s.written += 1;
        s.file.push(`l${s.written}`);
      },
    },
    writeRefused: {
      with: [atMost(1)],
      label: "Pi writes a line ATXF refuses",
      description: "An entry the ATXF stream refuses, such as one carrying a transcript.",
      when: (s) => s.file.length < MAX_LINES,
      run(s) {
        s.written += 1;
        s.file.push(`x${s.written}`);
      },
    },
    upload: {
      label: "Upload",
      description: "Appends the lines the cloud lacks, two at most.",
      sources: ["crates/axo-relay/src/sync/uploader.rs#Uploader::upload_next"],
      when: (s) => !s.waiting && s.acked < s.file.length,
      sends: [Append],
      run(s, _i, ctx) {
        s.waiting = true;
        ctx.send(ctx.the(SessionDO), Append, { epoch: s.epoch, from: s.acked + 1, lines: s.file.slice(s.acked, s.acked + 2) });
      },
    },
    rewrite: {
      with: [atMost(1)],
      label: "Rewrite the file",
      description: "The file was rewritten after its first acknowledged line: the host cuts the cloud back to the lines they share.",
      sources: ["crates/axo-relay/src/sync/uploader.rs#Uploader::realign"],
      when: (s) => !s.waiting && s.acked >= 1,
      sends: [Truncate],
      run(s, _i, ctx) {
        const keep = s.acked - 1;
        s.written += 1;
        s.file = [...s.file.slice(0, keep), `b${s.written}`];
        s.acked = keep;
        s.waiting = true;
        ctx.send(ctx.the(SessionDO), Truncate, { keep });
      },
    },
  },
  transitions: {
    appended: {
      on: Appended,
      description: "The cloud holds `count` lines of `epoch`: the host goes on from there (a cloud that lost its storage says 0).",
      run(s, m) {
        s.epoch = m.epoch;
        s.acked = Math.min(m.count, s.file.length);
        s.waiting = false;
      },
    },
    truncated: {
      on: Truncated,
      description: "The cloud cut back; the host appends in the new epoch.",
      run(s, m) {
        s.epoch = m.epoch;
        s.waiting = false;
      },
    },
  },
});

type Epoch = { epoch: number; keep: number; parent: number | null; through: number; dropped: number; headerSaved: boolean };
type Cut = { epoch: number; cursor: number; line: string };
type Segment = { kind: "header"; epoch: number } | { kind: "records"; epoch: number; from: number; to: number };
type Entry = { gen: string; epoch: number; cursor: number; line: string; lost: boolean };
type Store = {
  gen: string;
  /** The current epoch's records; null once R2 holds the line and the SessionDO dropped it. */
  lines: (string | null)[];
  epoch: number;
  epochs: Epoch[];
  cut: Cut[];
  /** The ATXF records made so far (atxf_through), and where the stream in memory is, or null. */
  translated: number;
  stream: number | null;
  /** Translation stopped at a line the stream refused, or at a line it could not read back. */
  stopped: boolean;
  /** Cursors the stream's state was saved at: 0, and the end of each stored segment. */
  saved: number[];
  pending: Segment | null;
  /** The PUT or the read-back this object awaits, by id, or null. In memory only. */
  awaiting: string | null;
  /** The segment stored and not yet read back. */
  storedUnread: Segment | null;
  alarm: boolean;
  /** A segment found different bytes under its key, or read back different: storing stops, and says so. */
  refused: boolean;
  /** Not the SessionDO's state: the current epoch's lines as committed, for the properties. */
  truth: string[];
  ledger: Entry[];
};

const fresh = (gen: string): Omit<Store, "ledger"> => ({
  gen, lines: [], epoch: 1, epochs: [{ epoch: 1, keep: 0, parent: null, through: 0, dropped: 0, headerSaved: false }],
  cut: [], translated: 0, stream: null, stopped: false, saved: [0], pending: null, awaiting: null, storedUnread: null,
  alarm: false, refused: false, truth: [],
});

const atxfOf = (line: string) => `A(${line})`;
const lineOf = (record: string) => record.slice(2, -1);
const refusedLine = (line: string) => line.startsWith("x");

const prefix = (s: { gen: string }, epoch: number) => (generations.on ? `${s.gen}/` : "") + `e${epoch}/`;
const keyOf = (s: Store, seg: Segment) => (seg.kind === "header" ? `${prefix(s, seg.epoch)}header` : `${prefix(s, seg.epoch)}${seg.from}-${seg.to}`);
const epochOf = (s: Store, epoch: number) => s.epochs.find((e) => e.epoch === epoch)!;

/** The line at `cursor` of `epoch` the SessionDO still holds, from the table that holds it now. */
function heldLine(s: Store, epoch: number, cursor: number): string | null | undefined {
  if (epoch === s.epoch) return s.lines[cursor - 1];
  return s.cut.find((c) => c.epoch === epoch && c.cursor === cursor)?.line;
}

/** The last cursor of `epoch` that can go to R2: translated, for the current epoch. */
function lastReady(s: Store, epoch: number): number {
  if (epoch === s.epoch) return Math.min(s.translated, s.lines.length);
  return Math.max(0, ...s.cut.filter((c) => c.epoch === epoch).map((c) => c.cursor));
}

/** The next segment to store, oldest epoch first: its header, then its records in order. */
function nextSegment(s: Store): Segment | null {
  for (const e of s.epochs) {
    const last = lastReady(s, e.epoch);
    // An epoch needs its header once it has something to give back: records, or a kept prefix.
    if (!e.headerSaved && (e.keep > 0 || last > e.through)) return { kind: "header", epoch: e.epoch };
    if (e.through < last) return { kind: "records", epoch: e.epoch, from: e.through + 1, to: Math.min(last, e.through + SEGMENT_RECORDS) };
  }
  return null;
}

function bodyOf(s: Store, seg: Segment): string {
  if (seg.kind === "header") {
    const e = epochOf(s, seg.epoch);
    return `keep=${e.keep} parent=${e.parent ?? "-"}`;
  }
  const records: string[] = [];
  for (let c = seg.from; c <= seg.to; c++) records.push(atxfOf(heldLine(s, seg.epoch, c) ?? "?"));
  return records.join(",");
}

const hasWork = (s: Store) => !s.refused && (nextSegment(s) !== null || s.pending !== null || s.storedUnread !== null);

/** The ATXF stream, rebuilt if this object lost it: from the last saved state at or before `translated`, reading the lines after it. */
function resume(s: Store, objects: () => Record<string, string>): boolean {
  if (s.stream === s.translated) return true;
  const from = checkpoints.on ? Math.max(...s.saved.filter((c) => c <= s.translated)) : 0;
  for (let c = from + 1; c <= s.translated; c++) {
    // A line the SessionDO dropped is read from its segment in R2, one segment at most with checkpoints.
    const held = s.lines[c - 1];
    if (held === null && !checkpoints.on) return false;
    if (held === null && segmentLine(s, objects(), c) === undefined) return false;
  }
  s.stream = s.translated;
  return true;
}

/** Makes the ATXF records of every line it can, in order. */
function translate(s: Store, objects: () => Record<string, string>) {
  if (s.stopped || s.translated >= s.lines.length) return;
  if (!resume(s, objects)) {
    s.stopped = true;
    s.stream = null;
    return;
  }
  while (s.translated < s.lines.length) {
    const line = s.lines[s.translated];
    if (line === null || line === undefined || refusedLine(line)) {
      s.stopped = true;
      s.stream = null;
      return;
    }
    s.translated += 1;
    s.stream = s.translated;
  }
}

export const SessionDO = defineActor({
  name: "SessionDO",
  description: "The Session's Durable Object: orders appends, keeps each record's hash and chain, and holds the lines R2 does not have yet.",
  zone: cloud,
  singleton: true,
  initialState: (): Store => ({ ...fresh("gen-0"), ledger: [] }),
  display: {
    icon: "database",
    status: (s) => `${s.lines.filter((l) => l !== null).length} of ${s.lines.length} line(s) held; ${hasWork(s) ? "R2 behind" : "R2 has the rest"}${s.stopped ? ", ATXF stopped" : ""}${s.alarm ? ", alarm set" : ""}`,
    mood: (s) => (s.refused ? "bad" : s.stopped ? "warn" : hasWork(s) ? "busy" : "ok"),
    rows: (s) => [
      ...s.lines.map((line, i) => ({ group: `epoch ${s.epoch}`, label: `${i + 1}`, detail: line ?? "in R2 only", mood: line === null ? ("off" as const) : undefined })),
      ...s.epochs.map((e) => ({ group: "in R2", label: `epoch ${e.epoch}`, detail: `through ${e.through}, dropped through ${e.dropped}${e.headerSaved ? "" : ", no header yet"}` })),
      ...s.cut.map((c) => ({ group: "cut, not in R2 yet", label: `${c.epoch}:${c.cursor}`, detail: c.line, mood: "warn" as const })),
    ],
  },
  actions: {
    evict: {
      with: [atMost(1)],
      label: "Evict",
      description: "The object leaves memory, and its ATXF stream with it. Storage and the alarm stay.",
      sources: ["packages/axo-api-worker/src/session-store.ts#AxoSessionDO.resume"],
      when: (s) => s.stream !== null && s.awaiting === null,
      run: (s) => void (s.stream = null),
    },
    wipe: {
      with: [spend(faults)],
      label: "Lose storage",
      description: "The object's storage is gone, and it starts over empty with a new generation. What R2 did not have is lost.",
      run(s, _i, ctx) {
        const inR2 = (e: Entry) => {
          const ep = s.epochs.find((x) => x.epoch === e.epoch);
          return ep !== undefined && e.cursor <= ep.through;
        };
        const ledger = s.ledger.map((e) => (e.gen === s.gen && !inR2(e) ? { ...e, lost: true } : e));
        Object.assign(s, fresh(ctx.fresh("gen")), { ledger });
      },
    },
    crash: {
      with: [spend(faults)],
      label: "Restart",
      description: "The object restarts while it awaits R2: the call is forgotten, and the interrupted alarm runs again.",
      when: (s) => s.awaiting !== null,
      run(s) {
        s.awaiting = null;
        s.stream = null;
        s.alarm = true;
      },
    },
  },
  transitions: {
    append: {
      on: Append,
      description: "Commits the lines with their hashes and chain, translates them while the stream is warm, and sets the alarm for R2 an hour from the first line R2 lacks.",
      sources: ["packages/axo-api-worker/src/session-store.ts#AxoSessionDO.append"],
      sends: [Appended],
      run(s, m, ctx) {
        if (m.epoch !== s.epoch || m.from !== s.lines.length + 1) return ctx.reply(Appended, { epoch: s.epoch, count: s.lines.length });
        for (const line of m.lines) {
          s.lines.push(line);
          s.truth.push(line);
          s.ledger.push({ gen: s.gen, epoch: s.epoch, cursor: s.lines.length, line, lost: false });
        }
        if (s.stream === s.translated) translate(s, () => ({}));
        else s.alarm = true; // translation waits: setAlarm(now)
        if (commitArms.on) s.alarm = true;
        ctx.reply(Appended, { epoch: s.epoch, count: s.lines.length });
      },
    },
    truncate: {
      on: Truncate,
      description: "Cuts back to `keep` lines in a new epoch. The records of the old epoch R2 lacks move to the side table first.",
      sources: ["packages/axo-api-worker/src/session-store.ts#AxoSessionDO.truncate"],
      sends: [Truncated, Appended],
      run(s, m, ctx) {
        // The chain at `keep` must be the host's: an object that holds fewer records refuses, and
        // the host starts again from what it holds.
        if (m.keep > s.lines.length) return ctx.reply(Appended, { epoch: s.epoch, count: s.lines.length });
        const current = epochOf(s, s.epoch);
        if (cutKeepsUnstored.on)
          // Every line not yet read back from R2, including those stored and not yet checked.
          for (let c = current.dropped + 1; c <= s.lines.length; c++) s.cut.push({ epoch: s.epoch, cursor: c, line: s.lines[c - 1]! });
        s.lines = s.lines.slice(0, m.keep);
        s.truth = s.truth.slice(0, m.keep);
        s.epoch += 1;
        s.epochs.push({ epoch: s.epoch, keep: m.keep, parent: s.epoch - 1, through: m.keep, dropped: Math.min(m.keep, current.dropped), headerSaved: false });
        // The cut drops the translations past keep, and the stream; a stop is cleared.
        s.translated = Math.min(s.translated, m.keep);
        s.stream = null;
        s.stopped = false;
        s.saved = s.saved.filter((c) => c <= m.keep);
        s.alarm = true; // translation waits: setAlarm(now)
        ctx.reply(Truncated, { epoch: s.epoch });
      },
    },
    alarm: {
      description: "Translates what waits. Then, if a segment is due, writes its range down (the outbox) and PUTs it; otherwise sets the alarm for the next one due.",
      when: (s) => s.alarm && s.awaiting === null,
      fair: "strong",
      sends: [Put, Get],
      run(s, _i, ctx) {
        s.alarm = false;
        if (!s.stopped && s.translated < s.lines.length) {
          // Translating takes this run; the segment was due later.
          translate(s, () => ctx.the(Bucket).state.objects);
          if (oneAlarm.on && hasWork(s)) s.alarm = true;
          return;
        }
        if (s.refused) return;
        if (s.storedUnread) {
          const id = ctx.fresh("get");
          s.awaiting = id;
          return ctx.send(ctx.the(Bucket), Get, { id, key: keyOf(s, s.storedUnread) });
        }
        const seg = s.pending ?? nextSegment(s);
        if (!seg) return;
        if (outbox.on) s.pending = seg;
        const id = ctx.fresh("put");
        s.awaiting = id;
        ctx.send(ctx.the(Bucket), Put, { id, key: keyOf(s, seg), body: bodyOf(s, seg) });
      },
    },
    stored: {
      on: Stored,
      description: "The segment is in R2, made now or by an earlier try with the same bytes: R2 holds the range, and the alarm reads it back.",
      run(s, m) {
        if (s.awaiting !== m.id) return; // an answer for a call a restart forgot
        s.awaiting = null;
        const seg = s.pending ?? nextSegment(s);
        s.pending = null;
        if (!m.same) {
          s.refused = true;
          return;
        }
        if (!seg) return;
        const e = epochOf(s, seg.epoch);
        if (seg.kind === "header") e.headerSaved = true;
        else {
          e.through = Math.max(e.through, seg.to);
          if (checkpoints.on && seg.epoch === s.epoch) s.saved = [...new Set([...s.saved, seg.to])].sort((a, b) => a - b);
          if (readBackBeforeDrop.on) s.storedUnread = seg;
          else dropThrough(s, seg.epoch, seg.to);
        }
        if (hasWork(s)) s.alarm = true;
      },
    },
    got: {
      on: Got,
      description: "The segment read back: if every line taken out of it equals the one held, the SessionDO drops those lines; otherwise storing stops, and says so.",
      run(s, m) {
        if (s.awaiting !== m.id) return;
        s.awaiting = null;
        const seg = s.storedUnread;
        s.storedUnread = null;
        if (!seg || seg.kind !== "records") return;
        const back = m.body.split(",").map(lineOf);
        const equal = back.length === seg.to - seg.from + 1 && back.every((line, i) => {
          const held = heldLine(s, seg.epoch, seg.from + i);
          return held === null || held === undefined || held === line;
        });
        if (!equal) {
          s.refused = true;
          return;
        }
        dropThrough(s, seg.epoch, seg.to);
        if (hasWork(s)) s.alarm = true;
      },
    },
    storedLost: lose(Stored, { fails: Put, spend: faults }),
    callFailed: {
      on: failed(Put),
      description: "The PUT failed: the alarm is set to try again, with the same range.",
      run(s, f) {
        if (s.awaiting !== f.payload.id) return;
        s.awaiting = null;
        s.alarm = true;
      },
    },
    getFailed: {
      on: failed(Get),
      description: "The read-back failed: the alarm is set to read it again.",
      run(s, f) {
        if (s.awaiting !== f.payload.id) return;
        s.awaiting = null;
        s.alarm = true;
      },
    },
  },
});

/**
 * Drops the lines of `epoch` through `to` that R2 holds and gave back: the current epoch's rows
 * keep their hash and chain, without the line, and an old epoch's side-table rows go.
 */
function dropThrough(s: Store, epoch: number, to: number) {
  const e = epochOf(s, epoch);
  e.dropped = Math.max(e.dropped, to);
  s.cut = s.cut.filter((c) => c.epoch !== epoch || c.cursor > to);
  if (epoch === s.epoch) for (let c = 1; c <= Math.min(to, s.lines.length); c++) s.lines[c - 1] = null;
}

export const Bucket = defineActor({
  name: "R2",
  description: "The axo-sessions bucket: write-once ATXF segments under accounts/<account>/hosts/<host>/sessions/<session>/.",
  zone: cloud,
  singleton: true,
  initialState: () => ({ objects: {} as Record<string, string> }),
  display: {
    icon: "storage",
    status: (s) => `${Object.keys(s.objects).length} object(s)`,
    rows: (s) => Object.entries(s.objects).map(([key, body]) => ({ group: "objects", label: key, detail: body })),
  },
  transitions: {
    put: {
      on: Put,
      description: "Stores the object unless one is already there (If-None-Match: *), and says whether what is there has the same bytes.",
      sends: [Stored],
      run(s, m, ctx) {
        const there = s.objects[m.key];
        if (there === undefined) s.objects[m.key] = m.body;
        ctx.reply(Stored, { id: m.id, same: there === undefined || there === m.body });
      },
    },
    putWrong: {
      on: Put,
      fair: false,
      with: [spend(faults)],
      description: "A bug stores the segment with bytes other than those sent, and says it stored them. (R2 losing an object after it was read back is out of scope.)",
      sends: [Stored],
      run(s, m, ctx) {
        const there = s.objects[m.key];
        if (there !== undefined) return ctx.reply(Stored, { id: m.id, same: there === m.body });
        s.objects[m.key] = m.key.endsWith("header") ? m.body : m.body.replace(/A\(([^)]*)\)/, "A(zz)");
        ctx.reply(Stored, { id: m.id, same: true });
      },
    },
    get: {
      on: Get,
      description: "Gives back the object.",
      sends: [Got],
      run: (s, m, ctx) => ctx.reply(Got, { id: m.id, body: s.objects[m.key] ?? "" }),
    },
    putLost: lose(Put, { spend: faults }),
    getLost: lose(Get, { spend: faults }),
  },
});

type Objects = Record<string, string>;

/** What R2 gives back for `epoch` of `gen`: its parent's first `keep` lines, then its own segments in order; null if any is missing or they overlap. */
function restore(objects: Objects, gen: string, epoch: number, depth = 0): string[] | null {
  if (depth > 4) return null;
  const base = (generations.on ? `${gen}/` : "") + `e${epoch}/`;
  const header = objects[`${base}header`];
  if (header === undefined) return null;
  const [, keepText, parentText] = /^keep=(\d+) parent=(.+)$/.exec(header) ?? [];
  const keep = Number(keepText);
  let lines: string[] = [];
  // A cut back to nothing needs nothing from the epoch before.
  if (parentText !== "-" && keep > 0) {
    const parent = restore(objects, gen, Number(parentText), depth + 1);
    if (parent === null || parent.length < keep) return null;
    lines = parent.slice(0, keep);
  }
  const segments = Object.keys(objects)
    .filter((key) => key.startsWith(base) && key !== `${base}header`)
    .map((key) => { const [from, to] = key.slice(base.length).split("-").map(Number); return { from: from!, to: to!, body: objects[key]! }; })
    .sort((a, b) => a.from - b.from);
  for (const segment of segments) {
    if (segment.from !== lines.length + 1) return null;
    lines.push(...segment.body.split(",").map(lineOf));
  }
  return lines;
}

/** Whether the SessionDO, or R2, still gives back `entry`. */
function available(w: WorldView, entry: Entry): boolean {
  const s = w.the(SessionDO).state;
  if (s.gen === entry.gen) {
    if (entry.epoch === s.epoch && s.lines[entry.cursor - 1] === entry.line) return true;
    if (entry.epoch === s.epoch && s.lines[entry.cursor - 1] === null && segmentLine(s, w.the(Bucket).state.objects, entry.cursor) === entry.line) return true;
    if (s.cut.some((c) => c.epoch === entry.epoch && c.cursor === entry.cursor && c.line === entry.line)) return true;
    // A record at or before a later epoch's keep is that epoch's too.
    const later = s.epochs.filter((e) => e.epoch > entry.epoch);
    if (later.length > 0 && later.every((e) => e.keep >= entry.cursor) && s.lines[entry.cursor - 1] === entry.line) return true;
  }
  return restore(w.the(Bucket).state.objects, entry.gen, entry.epoch)?.[entry.cursor - 1] === entry.line;
}

/**
 * The line at `cursor` of the current epoch from the segment that holds it, found from the
 * SessionDO's own index (each record row names its segment): the epoch it was written in is the
 * oldest one in the line of cuts whose keep is below it.
 */
function segmentLine(s: Store, objects: Objects, cursor: number): string | undefined {
  let epoch = epochOf(s, s.epoch);
  while (epoch.parent !== null && cursor <= epoch.keep) epoch = epochOf(s, epoch.parent);
  const base = prefix(s, epoch.epoch);
  for (const [key, body] of Object.entries(objects)) {
    if (!key.startsWith(base) || key.endsWith("header")) continue;
    const [from, to] = key.slice(base.length).split("-").map(Number);
    if (cursor >= from! && cursor <= to!) return lineOf(body.split(",")[cursor - from!]!);
  }
  return undefined;
}

/** What a reader of the current epoch gets at each cursor: the line held, or the one in its segment. */
function readable(w: WorldView): (string | undefined)[] {
  const s = w.the(SessionDO).state;
  const objects = w.the(Bucket).state.objects;
  return s.lines.map((line, i) => line ?? segmentLine(s, objects, i + 1));
}

const noRecordLost = defineProperty("noRecordLost", {
  needs: [cutKeepsUnstored, readBackBeforeDrop],
  description: "Every record the SessionDO committed can still be read, from the object or from R2, unless the object lost its storage before R2 had it.",
  always: (w) => w.the(SessionDO).state.ledger.every((entry) => entry.lost || available(w, entry)),
});

const readsAreFaithful = defineProperty("readsAreFaithful", {
  needs: [readBackBeforeDrop],
  description: "A reader of the Session gets every record of its current epoch as it was committed, whether the SessionDO still holds it or only R2 does.",
  always: (w) => {
    const s = w.the(SessionDO).state;
    const got = readable(w);
    return got.length === s.truth.length && got.every((line, i) => line === s.truth[i]);
  },
});

const segmentsAreFaithful = defineProperty("segmentsAreFaithful", {
  needs: [outbox],
  description: "Once nothing is left to store, R2 gives back every epoch exactly as it was committed.",
  always: (w) => {
    const s = w.the(SessionDO).state;
    if (hasWork(s) || s.awaiting !== null || s.refused || s.stopped || s.translated < s.lines.length) return true;
    const objects = w.the(Bucket).state.objects;
    return s.ledger.filter((e) => e.gen === s.gen).every((e) => restore(objects, e.gen, e.epoch)?.[e.cursor - 1] === e.line);
  },
});

const objectsNeverChange = defineProperty("objectsNeverChange", {
  needs: [generations],
  description: "An object in R2 keeps its bytes, except for a corruption the read-back catches, and no segment is refused for finding different bytes under its key.",
  everyStep: (before, after, e) => {
    if (e.is(Bucket, "putWrong")) return true;
    const was = before.the(Bucket).state.objects;
    const now = after.the(Bucket).state.objects;
    const corrupted = Object.values(now).some((body) => body.includes("A(zz)"));
    return Object.keys(was).every((key) => now[key] === was[key]) && (corrupted || !after.the(SessionDO).state.refused);
  },
});

const neverForgotten = defineProperty("neverForgotten", {
  needs: [oneAlarm, commitArms],
  description: "While records wait for R2, the alarm is set or a call to R2 is on its way.",
  always: (w) => {
    const s = w.the(SessionDO).state;
    return !hasWork(s) || s.alarm || s.awaiting !== null;
  },
});

const translationCatchesUp = defineProperty("translationCatchesUp", {
  needs: [checkpoints],
  description: "Lines waiting for their ATXF records get them, unless ATXF refuses one, even after the SessionDO dropped the lines before them. (Without saved states, rebuilding the stream reads every line back from R2: for a 118 MB Session, more than an alarm can do; the model counts that as failing.)",
  leadsTo: {
    whenever: (w) => {
      const s = w.the(SessionDO).state;
      return s.translated < s.lines.length && !s.lines.some((l) => l !== null && refusedLine(l));
    },
    then: (w) => {
      const s = w.the(SessionDO).state;
      return s.translated === s.lines.length || s.lines.some((l) => l !== null && refusedLine(l));
    },
  },
});

const catchesUp = defineProperty("catchesUp", {
  description: "Records waiting for R2 end up in R2 with their lines dropped from the SessionDO, unless ATXF refuses a line (they wait at it) or a segment was refused.",
  leadsTo: {
    whenever: (w) => {
      const s = w.the(SessionDO).state;
      return hasWork(s) && !s.lines.some((l) => l !== null && refusedLine(l));
    },
    then: (w) => {
      const s = w.the(SessionDO).state;
      return !hasWork(s) || s.refused;
    },
  },
});

const restoredAfterCut = defineProperty("restoredAfterCut", {
  description: "R2 alone gives back both epochs of a Session that was cut, and the SessionDO holds none of their lines.",
  reachable: (w) => {
    const s = w.the(SessionDO).state;
    const objects = w.the(Bucket).state.objects;
    return s.epoch === 2 && !hasWork(s) && s.lines.length > 0 && s.lines.every((l) => l === null) && restore(objects, s.gen, 1) !== null && restore(objects, s.gen, 2) !== null && s.cut.length === 0;
  },
});

const idle = (w: WorldView) => !w.the(Host).state.waiting;
const settled = (w: WorldView) => !hasWork(w.the(SessionDO).state) && w.the(SessionDO).state.awaiting === null;

const live = defineScenario("A Session written live", {
  description: "Two lines commit and are translated in the same call; an hour later one segment goes to R2, is read back, and the SessionDO drops their lines.",
  run(s) {
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "upload");
    s.settle({ until: (w) => idle(w) && settled(w) });
  },
});
const cut = defineScenario("A cut before R2 has them", {
  description: "Two lines commit and the host cuts back to one before R2 has them: both go to R2 under epoch 1 from the side table, then the new line under epoch 2.",
  run(s) {
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "upload");
    s.settle({ until: (w) => idle(w) });
    s.act(s.the(Host), "rewrite");
    s.settle({ until: (w) => idle(w) });
    s.act(s.the(Host), "upload");
    s.settle({ until: (w) => idle(w) && settled(w) });
  },
});
const lostAnswer = defineScenario("R2's answer is lost", {
  description: "The segment was stored but the SessionDO never heard. Its retry sends the same range, finds the same bytes, and moves on.",
  run(s) {
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "upload");
    s.settle({ until: (w) => idle(w) && w.the(SessionDO).state.awaiting === null && w.the(SessionDO).state.alarm && w.the(SessionDO).state.translated === 1 });
    s.step(s.the(SessionDO), "alarm");
    s.deliver(s.the(Bucket), Put);
    s.step(s.the(SessionDO), "storedLost");
    s.settle({ until: (w) => settled(w) });
  },
});
const evicted = defineScenario("Evicted after the lines were dropped", {
  description: "R2 has the first two lines and the SessionDO dropped them. It is evicted, a third line comes, and the stream is rebuilt from the state saved at the end of the segment, reading nothing from R2.",
  run(s) {
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "upload");
    s.settle({ until: (w) => idle(w) && settled(w) });
    s.act(s.the(SessionDO), "evict");
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "upload");
    s.settle({ until: (w) => idle(w) && settled(w) });
  },
});
const before = defineScenario("A Session stored before", {
  description: "Its records are translated but R2 has none; the HostDO's backfill sets the alarm once, and the alarms store it a segment at a time, oldest first.",
  setup(w) {
    w.set(Host, { file: ["l1", "l2", "l3"], written: 3, acked: 3 });
    w.set(SessionDO, {
      gen: "gen-0",
      lines: ["l1", "l2", "l3"],
      truth: ["l1", "l2", "l3"],
      translated: 3,
      ledger: ["l1", "l2", "l3"].map((line, i) => ({ gen: "gen-0", epoch: 1, cursor: i + 1, line, lost: false })),
      alarm: true,
    });
  },
  run(s) {
    s.settle({ until: (w) => settled(w) });
  },
});

export default defineSpec({
  name: "Session storage in R2",
  description: "How a Session's records move from its SessionDO to write-once ATXF segments in R2, across cuts, evictions, lost answers, restarts, a corrupted segment and a lost storage, without leaving a record that can be read from neither.",
  actors: [Host, SessionDO, Bucket],
  properties: [noRecordLost, readsAreFaithful, segmentsAreFaithful, objectsNeverChange, neverForgotten, translationCatchesUp, catchesUp, restoredAfterCut],
  scenarios: [live, cut, lostAnswer, evicted, before],
});
