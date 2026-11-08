import { atMost, budget, defineActor, defineCall, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone, listOf, spend } from "@leostera/feynman";

// RFD0035: the SessionDO keeps each Pi line's ATXF record beside it, translated in cursor order
// after the line commits, and never changes the line.
//
// One Session, at most three lines, a translation slice of one record so alarms interleave with
// everything else. A line's ATXF record depends on every line before it (a tree, ids taken so
// far), so it is modelled as the prefix itself: record i is "l1.l2…li". A stream that had read a
// branch a cut removed would write a record with the old prefix in it, which the properties catch.
// A line starting with "x" is one the stream refuses (a line carrying a transcript).
//
// Not modelled: hashes (a record is its own hash), parts, the bytes budget, several Sessions.
//
// catchesUp needs paths longer than the default depth: check this spec with --depth 22.

const MAX_LINES = 3;

/** The ATXF record for the line at `index`: it depends on every line up to it. */
const recordOf = (lines: readonly string[], index: number) => lines.slice(0, index + 1).join(".");
const refused = (line: string) => line.startsWith("x");

/** Losing what is in memory: Durable Objects are evicted when idle, and restart on a deploy. */
const evictions = budget("evictions", 2);

const readBack = defineRule("readBack", {
  description: "A stream lives in memory only. One that is missing, or read a different number of records, is rebuilt by reading records 1..atxf_through back, each of which must give its stored translation.",
});
const cutsRestart = defineRule("cutsRestart", {
  description: "A cut deletes the rows past keep with their translations, lowers atxf_through to at most keep, and drops the stream.",
});
const behindSetsAlarm = defineRule("behindSetsAlarm", {
  description: "Whatever leaves records untranslated (an append that could not translate inline, a slice that did not finish, a read of a Session stored before) sets an alarm.",
});

const Append = defineCall("Append", { epoch: Number, from: Number, lines: listOf(String) }, { name: "SessionDO.append", over: "rpc" });
const Appended = defineMessage("Appended", { count: Number }, { name: "committed", over: "rpc", tone: "reply" });
const Truncate = defineCall("Truncate", { keep: Number }, { name: "SessionDO.truncate", over: "rpc" });
const Truncated = defineMessage("Truncated", { epoch: Number }, { name: "truncated", over: "rpc", tone: "reply" });

const mac = defineZone({ name: "Host Mac", description: "axod uploads the Session's Pi file", place: { column: 0 } });
const cloud = defineZone({ name: "Cloudflare", description: "the Session's Durable Object", place: { column: 1, region: true } });

export const Host = defineActor({
  name: "Host",
  description: "axod: appends Pi's new lines to the cloud, and cuts it back when its file was rewritten (RFD0018).",
  zone: mac,
  singleton: true,
  initialState: () => ({
    file: [] as string[],
    written: 0,
    epoch: 1,
    /** Lines the cloud committed, as far as the host knows. */
    acked: 0,
    /** What the host knows the cloud holds: its committed lines, less any it cut. */
    held: [] as string[],
    waiting: false,
  }),
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
      description: "An entry the stream refuses, such as one carrying a transcript.",
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
        s.held = s.held.slice(0, keep);
        s.acked = keep;
        s.waiting = true;
        ctx.send(ctx.the(SessionDO), Truncate, { keep });
      },
    },
  },
  transitions: {
    appended: {
      on: Appended,
      description: "The cloud committed the lines up to `count`.",
      run(s, m) {
        s.acked = m.count;
        s.held = s.file.slice(0, m.count);
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

type Store = {
  lines: string[];
  epoch: number;
  atxf: string[];
  through: number;
  /** The lines the stream in memory has read, or null when the object has none. */
  stream: string[] | null;
  error: boolean;
  alarm: boolean;
  /** Stored before RFD0035 and not used since: nothing has asked for its translation yet. */
  untouched: boolean;
};

/** Translates up to `max` records after `through`. Returns whether more remain. */
function translate(s: Store, max: number): boolean {
  if (s.error || s.through >= s.lines.length) return false;
  if (s.stream === null || s.stream.length !== s.through) {
    // Without reading back, a new stream would start at `through` knowing none of the records before.
    if (!readBack.on) s.stream = [];
    else {
      for (let i = 0; i < s.through; i++) if (s.atxf[i] !== recordOf(s.lines, i)) {
        s.error = true;
        s.stream = null;
        return false;
      }
      s.stream = s.lines.slice(0, s.through);
    }
  }
  for (let n = 0; n < max && s.through < s.lines.length; n++) {
    const line = s.lines[s.through]!;
    if (refused(line)) {
      s.error = true;
      s.stream = null;
      return false;
    }
    s.stream = [...s.stream!, line];
    s.atxf.push(recordOf(s.stream, s.stream.length - 1));
    s.through += 1;
  }
  return s.through < s.lines.length;
}

/** `setAlarm(now)`: one alarm per object; setting it again while it is set changes nothing. */
function setAlarm(s: Store, ctx: { start(name: "alarm"): void }) {
  if (s.alarm) return;
  s.alarm = true;
  ctx.start("alarm");
}

export const SessionDO = defineActor({
  name: "SessionDO",
  description: "The Session's Durable Object: its Pi lines, and their ATXF records so far.",
  zone: cloud,
  singleton: true,
  initialState: (): Store => ({ lines: [], epoch: 1, atxf: [], through: 0, stream: null, error: false, alarm: false, untouched: false }),
  display: {
    icon: "database",
    status: (s) => `${s.lines.length} line(s), ${s.through} in ATXF${s.error ? ", stopped" : ""}${s.alarm ? ", alarm set" : ""}`,
    mood: (s) => (s.error ? "bad" : s.through < s.lines.length ? "busy" : "ok"),
    rows: (s) => s.lines.map((line, i) => ({ group: `epoch ${s.epoch}`, label: `${i + 1}`, detail: `${line} → ${s.atxf[i] ?? "…"}` })),
  },
  actions: {
    evict: {
      with: [spend(evictions)],
      label: "Evict",
      description: "The object leaves memory, and its stream with it. Storage and alarms stay.",
      sources: ["packages/axo-api-worker/src/session-store.ts#AxoSessionDO.resume"],
      when: (s) => s.stream !== null,
      run(s) {
        s.stream = null;
      },
    },
    read: {
      label: "A client reads",
      description: "Reading the Session (or its head) sets an alarm if records wait to be translated.",
      sources: ["packages/axo-api-worker/src/session-store.ts#AxoSessionDO.catchUp"],
      when: (s) => !s.alarm && !s.error && s.through < s.lines.length,
      starts: ["alarm"],
      run(s, _i, ctx) {
        s.untouched = false;
        setAlarm(s, ctx);
      },
    },
  },
  transitions: {
    alarm: {
      after: "at once",
      description: "Translates the next slice, and sets the alarm again if records remain.",
      sources: ["packages/axo-api-worker/src/session-store.ts#AxoSessionDO.alarm", "packages/axo-api-worker/src/session-store.ts#AxoSessionDO.translate", "packages/axo-api-worker/src/session-store.ts#AxoSessionDO.resume"],
      starts: ["alarm"],
      run(s, _i, ctx) {
        s.alarm = false;
        if (translate(s, 1)) setAlarm(s, ctx);
      },
    },
    append: {
      on: Append,
      description: "Commits the lines, then translates them in the same call if the stream is in memory and caught up; otherwise sets an alarm.",
      sources: ["packages/axo-api-worker/src/session-store.ts#AxoSessionDO.append", "packages/axo-api-worker/src/session-store.ts#AxoSessionDO.translateAfterAppend"],
      sends: [Appended],
      starts: ["alarm"],
      run(s, m, ctx) {
        if (m.epoch !== s.epoch || m.from !== s.lines.length + 1) return ctx.reply(Appended, { count: s.lines.length });
        const before = s.lines.length;
        s.lines.push(...m.lines);
        s.untouched = false;
        ctx.reply(Appended, { count: s.lines.length });
        if (s.error) return;
        const warm = s.stream !== null && s.stream.length === before;
        if (s.through === before && (warm || before === 0) && !translate(s, 64)) return;
        if (behindSetsAlarm.on) setAlarm(s, ctx);
      },
    },
    truncate: {
      on: Truncate,
      description: "Cuts back to `keep` lines in a new epoch, with their translations, and drops the stream. A stop is cleared, since the line that caused it may be gone, and an alarm is set if records wait.",
      sources: ["packages/axo-api-worker/src/session-store.ts#AxoSessionDO.truncate"],
      sends: [Truncated],
      starts: ["alarm"],
      run(s, m, ctx) {
        s.lines = s.lines.slice(0, m.keep);
        if (cutsRestart.on) {
          s.through = Math.min(s.through, m.keep);
          s.atxf = s.atxf.slice(0, s.through);
          s.stream = null;
        }
        s.error = false;
        s.epoch += 1;
        ctx.reply(Truncated, { epoch: s.epoch });
        if (behindSetsAlarm.on && s.through < s.lines.length) setAlarm(s, ctx);
      },
    },
  },
});

const faithful = defineProperty("faithful", {
  needs: [readBack, cutsRestart],
  description: "Every stored ATXF record is the translation of the lines stored before and at it: none was made by a stream that read a cut branch, or a line out of order.",
  always: (w) => {
    const s = w.the(SessionDO).state;
    return s.through <= s.lines.length && s.atxf.length === s.through && s.atxf.every((record, i) => record === recordOf(s.lines, i));
  },
});
const noRecordLost = defineProperty("noRecordLost", {
  description: "Every line the cloud acknowledged is still there, unchanged, unless the host cut it.",
  always: (w) => {
    const held = w.the(Host).state.held;
    const lines = w.the(SessionDO).state.lines;
    return held.every((line, i) => lines[i] === line);
  },
});
const catchesUp = defineProperty("catchesUp", {
  needs: [behindSetsAlarm],
  description: "Records waiting for translation end up translated, unless a line stops it. A Session stored before RFD0035 waits until something uses it (RFD0035, Unresolved questions).",
  leadsTo: {
    whenever: (w) => {
      const s = w.the(SessionDO).state;
      return !s.error && !s.untouched && s.through < s.lines.length;
    },
    then: (w) => {
      const s = w.the(SessionDO).state;
      return s.error || s.through === s.lines.length;
    },
  },
});

const idle = (w: { the(actor: typeof Host): { state: { waiting: boolean } } }) => !w.the(Host).state.waiting;

const live = defineScenario("A Session written live", {
  description: "Each batch is translated in the call that commits it.",
  run(s) {
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "upload");
    s.settle({ until: (w) => idle(w) && w.the(SessionDO).state.through === 2 });
  },
});
const evicted = defineScenario("Evicted between batches", {
  description: "The next batch finds no stream: an alarm reads the first record back, then translates the new one.",
  run(s) {
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "upload");
    s.settle({ until: (w) => idle(w) && w.the(SessionDO).state.through === 1 });
    s.act(s.the(SessionDO), "evict");
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "upload");
    s.settle({ until: (w) => idle(w) && w.the(SessionDO).state.through === 2 });
  },
});
const cut = defineScenario("A cut", {
  description: "The host rewrote its file; the cloud cuts back, and the new line is translated after the kept one, not the cut one.",
  run(s) {
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "upload");
    s.settle({ until: (w) => idle(w) && w.the(SessionDO).state.through === 2 });
    s.act(s.the(Host), "rewrite");
    s.settle({ until: (w) => idle(w) && w.the(Host).state.epoch === 2 });
    s.act(s.the(Host), "upload");
    s.settle({ until: (w) => idle(w) && w.the(SessionDO).state.through === 2 });
  },
});
const before = defineScenario("A Session stored before RFD0035", {
  description: "Its lines have no translations; the first read sets an alarm, and alarms translate it oldest first, a slice at a time.",
  setup(w) {
    w.set(Host, { file: ["l1", "l2", "l3"], written: 3, acked: 3, held: ["l1", "l2", "l3"] });
    w.set(SessionDO, { lines: ["l1", "l2", "l3"], untouched: true });
  },
  run(s) {
    s.act(s.the(SessionDO), "read");
    s.settle({ until: (w) => w.the(SessionDO).state.through === 3 });
  },
});
const stopped = defineScenario("A line the stream refuses", {
  description: "Translation stops at that line; the lines keep committing.",
  run(s) {
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "writeRefused");
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "upload");
    s.settle({ until: (w) => idle(w) && w.the(SessionDO).state.error });
    s.act(s.the(Host), "upload");
    s.settle({ until: (w) => idle(w) && w.the(SessionDO).state.lines.length === 3 });
  },
});

export default defineSpec({
  name: "Session records in ATXF",
  description: "How the SessionDO translates a Session's Pi lines into ATXF as they commit, across evictions, alarms and cuts, without losing or changing a line and without storing a record a stale stream wrote.",
  actors: [Host, SessionDO],
  properties: [faithful, noRecordLost, catchesUp],
  scenarios: [live, evicted, cut, before, stopped],
});
