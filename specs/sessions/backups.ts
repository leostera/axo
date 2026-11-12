import type { WorldView } from "@leostera/feynman";
import { atMost, budget, defineActor, defineCall, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone, failed, listOf, lose, spend } from "@leostera/feynman";

// RFD0044: each SessionDO copies its committed records to R2, a write-once object per range of
// cursors, about an hour after the first record the copy lacks.
//
// One Session, at most three lines, chunks of at most two records, one cut. A line is its own
// hash. Time is the order of events: "an hour later" is an alarm that may fire at any moment.
// The ATXF translation is one flag, `untranslated`: what matters about it here is that it shares
// the object's one alarm, and sets it to "now".
//
// `ledger` is not the SessionDO's state: it is what the properties check against, every record
// the SessionDO ever committed, and it survives a wipe. A wipe is the SessionDO losing its storage
// and starting over (RFD0044, "Durable Objects do not run forever"); records it had not copied
// then are lost, and the ledger marks them.
//
// Not modelled: the HostDO's backfill of Sessions stored before (a scenario's setup stands for
// it), parts, bytes budgets, several Sessions.

const MAX_LINES = 3;
const CHUNK_RECORDS = 2;

const faults = budget("faults", 1);

const outbox = defineRule("outbox", {
  description: "The range a copy covers is written down before its PUT, and a retry sends that same range, so a lost answer never leaves two objects that overlap.",
});
const cutKeepsUnbacked = defineRule("cutKeepsUnbacked", {
  description: "A cut moves the records the copy lacks into a side table, in the same transaction, and they are copied from there under their old epoch.",
});
const oneAlarm = defineRule("oneAlarm", {
  description: "An object has one alarm. After translating, the alarm handler sets it again for the next backup that is due, not only for translation that remains.",
});
const commitArms = defineRule("commitArms", {
  description: "A commit or a cut that leaves records the copy lacks sets the alarm if none is set.",
});
const generations = defineRule("generations", {
  description: "Object keys carry the generation, a random id the SessionDO takes when its storage is new, so an object that lost its storage and was rebuilt never writes where the old one did.",
});

const Append = defineCall("Append", { epoch: Number, from: Number, lines: listOf(String) }, { name: "SessionDO.append", over: "rpc" });
const Appended = defineMessage("Appended", { epoch: Number, count: Number }, { name: "committed", over: "rpc", tone: "reply" });
const Truncate = defineCall("Truncate", { keep: Number }, { name: "SessionDO.truncate", over: "rpc" });
const Truncated = defineMessage("Truncated", { epoch: Number }, { name: "truncated", over: "rpc", tone: "reply" });
const Put = defineCall("Put", { id: String, key: String, body: String }, { name: "R2 put, If-None-Match: *", over: "https" });
const Stored = defineMessage("Stored", { id: String, created: Boolean, same: Boolean }, { name: "stored", over: "https", tone: "reply" });

const mac = defineZone({ name: "Host Mac", description: "axod uploads the Session's Pi file", place: { column: 0 } });
const cloud = defineZone({ name: "Cloudflare", description: "the Session's Durable Object and the backups bucket", place: { column: 1, region: true } });

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

type Epoch = { epoch: number; keep: number; parent: number | null; through: number; headerSaved: boolean };
type Cut = { epoch: number; cursor: number; line: string };
type Pending = { kind: "header"; epoch: number } | { kind: "chunk"; epoch: number; from: number; to: number };
type Entry = { gen: string; epoch: number; cursor: number; line: string; lost: boolean };
type Store = {
  gen: string;
  lines: string[];
  epoch: number;
  epochs: Epoch[];
  cut: Cut[];
  pending: Pending | null;
  /** The PUT this object awaits, by id, or null. In memory only. */
  putting: string | null;
  alarm: boolean;
  untranslated: boolean;
  /** A copy found different bytes under its key, and stopped. */
  refused: boolean;
  ledger: Entry[];
};

const fresh = (gen: string): Omit<Store, "ledger"> => ({
  gen, lines: [], epoch: 1, epochs: [{ epoch: 1, keep: 0, parent: null, through: 0, headerSaved: false }],
  cut: [], pending: null, putting: null, alarm: false, untranslated: false, refused: false,
});

const prefix = (s: { gen: string }, epoch: number) => (generations.on ? `${s.gen}/` : "") + `e${epoch}/`;
const headerKey = (s: { gen: string }, epoch: number) => `${prefix(s, epoch)}header`;
const chunkKey = (s: { gen: string }, epoch: number, from: number, to: number) => `${prefix(s, epoch)}${from}-${to}`;

/** The record at `cursor` of `epoch`, from the table that holds it now. */
function recordAt(s: Store, epoch: number, cursor: number): string | undefined {
  if (epoch === s.epoch) return s.lines[cursor - 1];
  return s.cut.find((c) => c.epoch === epoch && c.cursor === cursor)?.line;
}

/** The last cursor of `epoch` this object still holds to copy. */
function lastHeld(s: Store, epoch: number): number {
  if (epoch === s.epoch) return s.lines.length;
  return Math.max(0, ...s.cut.filter((c) => c.epoch === epoch).map((c) => c.cursor));
}

/** The next copy to make, oldest epoch first: its header, then its records in order. */
function nextCopy(s: Store): Pending | null {
  for (const e of s.epochs) {
    const last = lastHeld(s, e.epoch);
    // An epoch needs its header once it has something to give back: records, or a kept prefix.
    if (!e.headerSaved && (e.keep > 0 || last > e.through)) return { kind: "header", epoch: e.epoch };
    if (e.through < last) return { kind: "chunk", epoch: e.epoch, from: e.through + 1, to: Math.min(last, e.through + CHUNK_RECORDS) };
  }
  return null;
}

function bodyOf(s: Store, copy: Pending): string {
  if (copy.kind === "header") {
    const e = s.epochs.find((x) => x.epoch === copy.epoch)!;
    return `keep=${e.keep} parent=${e.parent ?? "-"}`;
  }
  const lines: string[] = [];
  for (let c = copy.from; c <= copy.to; c++) lines.push(recordAt(s, copy.epoch, c) ?? "?");
  return lines.join(",");
}

function keyOf(s: Store, copy: Pending): string {
  return copy.kind === "header" ? headerKey(s, copy.epoch) : chunkKey(s, copy.epoch, copy.from, copy.to);
}

const hasWork = (s: Store) => !s.refused && (nextCopy(s) !== null || s.pending !== null);

/** `setAlarm(due)` unless one is set: an object has one alarm. */
function arm(s: Store) {
  s.alarm = true;
}

export const SessionDO = defineActor({
  name: "SessionDO",
  description: "The Session's Durable Object: its Pi lines, and how far each epoch's copy in R2 has got.",
  zone: cloud,
  singleton: true,
  initialState: (): Store => ({ ...fresh("gen-0"), ledger: [] }),
  display: {
    icon: "database",
    status: (s) => `${s.lines.length} line(s) in epoch ${s.epoch}; ${hasWork(s) ? "copy behind" : "copied"}${s.alarm ? ", alarm set" : ""}`,
    mood: (s) => (hasWork(s) ? "busy" : "ok"),
    rows: (s) => [
      ...s.lines.map((line, i) => ({ group: `epoch ${s.epoch}`, label: `${i + 1}`, detail: line })),
      ...s.epochs.map((e) => ({ group: "copies", label: `epoch ${e.epoch}`, detail: `through ${e.through}${e.headerSaved ? "" : ", no header yet"}` })),
      ...s.cut.map((c) => ({ group: "cut, not copied yet", label: `${c.epoch}:${c.cursor}`, detail: c.line, mood: "warn" as const })),
    ],
  },
  actions: {
    wipe: {
      with: [spend(faults)],
      label: "Lose storage",
      description: "The object's storage is gone, and it starts over empty with a new generation. What it had not copied is lost.",
      run(s, _i, ctx) {
        const copied = (e: Entry) => {
          const ep = s.epochs.find((x) => x.epoch === e.epoch);
          return ep !== undefined && e.cursor <= ep.through;
        };
        const ledger = s.ledger.map((e) => (e.gen === s.gen && !copied(e) ? { ...e, lost: true } : e));
        Object.assign(s, fresh(ctx.fresh("gen")), { ledger });
      },
    },
    crash: {
      with: [spend(faults)],
      label: "Restart",
      description: "The object restarts mid-copy: the PUT it awaited is forgotten, and the interrupted alarm runs again.",
      when: (s) => s.putting !== null,
      run(s) {
        s.putting = null;
        s.alarm = true;
      },
    },
  },
  transitions: {
    append: {
      on: Append,
      description: "Commits the lines, sets the alarm to translate them now, and to copy them an hour from the first one the copy lacks.",
      sources: ["packages/axo-api-worker/src/session-store.ts#AxoSessionDO.append"],
      sends: [Appended],
      run(s, m, ctx) {
        if (m.epoch !== s.epoch || m.from !== s.lines.length + 1) return ctx.reply(Appended, { epoch: s.epoch, count: s.lines.length });
        for (const line of m.lines) {
          s.lines.push(line);
          s.ledger.push({ gen: s.gen, epoch: s.epoch, cursor: s.lines.length, line, lost: false });
        }
        s.untranslated = true;
        s.alarm = true; // translation: setAlarm(now)
        if (commitArms.on) arm(s);
        ctx.reply(Appended, { epoch: s.epoch, count: s.lines.length });
      },
    },
    truncate: {
      on: Truncate,
      description: "Cuts back to `keep` lines in a new epoch. The records of the old epoch the copy lacks move to the side table first.",
      sources: ["packages/axo-api-worker/src/session-store.ts#AxoSessionDO.truncate"],
      sends: [Truncated, Appended],
      run(s, m, ctx) {
        // The chain at `keep` must be the host's: an object that holds fewer records refuses, and
        // the host starts again from what it holds.
        if (m.keep > s.lines.length) return ctx.reply(Appended, { epoch: s.epoch, count: s.lines.length });
        const current = s.epochs.find((e) => e.epoch === s.epoch)!;
        if (cutKeepsUnbacked.on)
          for (let c = current.through + 1; c <= s.lines.length; c++) s.cut.push({ epoch: s.epoch, cursor: c, line: s.lines[c - 1]! });
        s.lines = s.lines.slice(0, m.keep);
        s.epoch += 1;
        s.epochs.push({ epoch: s.epoch, keep: m.keep, parent: s.epoch - 1, through: m.keep, headerSaved: false });
        if (commitArms.on) arm(s);
        ctx.reply(Truncated, { epoch: s.epoch });
      },
    },
    alarm: {
      description: "Translates what waits. Then, if a copy is due, writes down its range (the outbox) and PUTs it; otherwise sets the alarm for the next one due.",
      when: (s) => s.alarm && s.putting === null,
      fair: "strong",
      sends: [Put],
      run(s, _i, ctx) {
        s.alarm = false;
        if (s.untranslated) {
          // Translating takes this run; the copy was due later.
          s.untranslated = false;
          if (oneAlarm.on && hasWork(s)) s.alarm = true;
          return;
        }
        const copy = s.pending ?? nextCopy(s);
        if (!copy) return;
        if (outbox.on) s.pending = copy;
        const id = ctx.fresh("put");
        s.putting = id;
        ctx.send(ctx.the(Bucket), Put, { id, key: keyOf(s, copy), body: bodyOf(s, copy) });
      },
    },
    stored: {
      on: Stored,
      description: "The object is there, made now or by an earlier try with the same bytes: the copy moves past it, and the alarm is set for what remains.",
      run(s, m) {
        if (s.putting !== m.id) return; // an answer for a PUT a restart forgot
        s.putting = null;
        const copy = s.pending ?? null;
        s.pending = null;
        if (!m.same) {
          // A different object under the key: the copy stops there, and says so.
          s.refused = true;
          return;
        }
        if (copy) {
          const e = s.epochs.find((x) => x.epoch === copy.epoch)!;
          if (copy.kind === "header") e.headerSaved = true;
          else e.through = Math.max(e.through, copy.to);
        } else {
          // Without the outbox, the object only knows it sent the next copy: it moves as if that was it.
          const next = nextCopy(s);
          if (next) {
            const e = s.epochs.find((x) => x.epoch === next.epoch)!;
            if (next.kind === "header") e.headerSaved = true;
            else e.through = Math.max(e.through, next.to);
          }
        }
        s.cut = s.cut.filter((c) => c.cursor > (s.epochs.find((e) => e.epoch === c.epoch)?.through ?? 0));
        if (hasWork(s)) arm(s);
      },
    },
    storedLost: lose(Stored, { fails: Put, spend: faults }),
    putFailed: {
      on: failed(Put),
      description: "The PUT failed: the alarm is set to try again, with the same range.",
      run(s, f) {
        if (s.putting !== f.payload.id) return;
        s.putting = null;
        s.alarm = true;
      },
    },
  },
});

export const Bucket = defineActor({
  name: "R2",
  description: "The axo-session-backups bucket: write-once objects under accounts/<account>/hosts/<host>/sessions/<session>/.",
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
        if (there === undefined) {
          s.objects[m.key] = m.body;
          return ctx.reply(Stored, { id: m.id, created: true, same: true });
        }
        ctx.reply(Stored, { id: m.id, created: false, same: there === m.body });
      },
    },
    putLost: lose(Put, { spend: faults }),
  },
});

type Objects = Record<string, string>;

/** What R2 gives back for `epoch` of `gen`: its parent's first `keep` records, then its own chunks in order; null if any is missing or they overlap. */
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
  const chunks = Object.keys(objects)
    .filter((key) => key.startsWith(base) && key !== `${base}header`)
    .map((key) => { const [from, to] = key.slice(base.length).split("-").map(Number); return { from: from!, to: to!, body: objects[key]! }; })
    .sort((a, b) => a.from - b.from);
  for (const chunk of chunks) {
    if (chunk.from !== lines.length + 1) return null;
    lines.push(...chunk.body.split(","));
  }
  return lines;
}


/** Whether the SessionDO, or R2, still gives back `entry`. */
function available(w: WorldView, entry: Entry): boolean {
  const s = w.the(SessionDO).state;
  if (s.gen === entry.gen) {
    if (entry.epoch === s.epoch && s.lines[entry.cursor - 1] === entry.line) return true;
    if (s.cut.some((c) => c.epoch === entry.epoch && c.cursor === entry.cursor && c.line === entry.line)) return true;
    // A record at or before a later epoch's keep is that epoch's too.
    const later = s.epochs.filter((e) => e.epoch > entry.epoch);
    if (later.length > 0 && later.every((e) => e.keep >= entry.cursor) && s.lines[entry.cursor - 1] === entry.line) return true;
  }
  return restore(w.the(Bucket).state.objects, entry.gen, entry.epoch)?.[entry.cursor - 1] === entry.line;
}

const noRecordLost = defineProperty("noRecordLost", {
  needs: [cutKeepsUnbacked],
  description: "Every record the SessionDO committed can still be read, from the object or from R2, unless the object lost its storage before copying it.",
  always: (w) => w.the(SessionDO).state.ledger.every((entry) => entry.lost || available(w, entry)),
});

const copiesAreFaithful = defineProperty("copiesAreFaithful", {
  needs: [outbox],
  description: "Once nothing is left to copy, R2 gives back every epoch exactly as it was committed.",
  always: (w) => {
    const s = w.the(SessionDO).state;
    if (hasWork(s) || s.putting !== null) return true;
    const objects = w.the(Bucket).state.objects;
    return s.ledger.filter((e) => e.gen === s.gen).every((e) => restore(objects, e.gen, e.epoch)?.[e.cursor - 1] === e.line);
  },
});

const objectsNeverChange = defineProperty("objectsNeverChange", {
  needs: [generations],
  description: "An object in R2, once written, keeps its bytes, and no copy is refused for finding different bytes under its key.",
  everyStep: (before, after) => {
    const was = before.the(Bucket).state.objects;
    const now = after.the(Bucket).state.objects;
    return Object.keys(was).every((key) => now[key] === was[key]) && !after.the(SessionDO).state.refused;
  },
});

const neverForgotten = defineProperty("neverForgotten", {
  needs: [oneAlarm, commitArms],
  description: "While records wait to be copied, the alarm is set or a PUT is on its way.",
  always: (w) => {
    const s = w.the(SessionDO).state;
    return !hasWork(s) || s.alarm || s.putting !== null;
  },
});

const catchesUp = defineProperty("catchesUp", {
  description: "Records waiting to be copied end up copied.",
  leadsTo: {
    whenever: (w) => hasWork(w.the(SessionDO).state),
    then: (w) => !hasWork(w.the(SessionDO).state),
  },
});

const restoredAfterCut = defineProperty("restoredAfterCut", {
  description: "R2 can give back both epochs of a Session that was cut.",
  reachable: (w) => {
    const s = w.the(SessionDO).state;
    const objects = w.the(Bucket).state.objects;
    return s.epoch === 2 && !hasWork(s) && restore(objects, s.gen, 1) !== null && restore(objects, s.gen, 2) !== null && s.cut.length === 0;
  },
});

const idle = (w: WorldView) => !w.the(Host).state.waiting;
const copied = (w: WorldView) => !hasWork(w.the(SessionDO).state) && w.the(SessionDO).state.putting === null;

const live = defineScenario("A Session written live", {
  description: "Two lines commit; the alarm first translates them, then copies them in one object an hour later.",
  run(s) {
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "upload");
    s.settle({ until: (w) => idle(w) && copied(w) });
  },
});
const cut = defineScenario("A cut before the copy", {
  description: "Two lines commit and the host cuts back to one before they are copied: both are copied under epoch 1 from the side table, then the new line under epoch 2.",
  run(s) {
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "upload");
    s.settle({ until: (w) => idle(w) });
    s.act(s.the(Host), "rewrite");
    s.settle({ until: (w) => idle(w) });
    s.act(s.the(Host), "upload");
    s.settle({ until: (w) => idle(w) && copied(w) });
  },
});
const lostAnswer = defineScenario("R2's answer is lost", {
  description: "The object was stored but the SessionDO never heard. Its retry sends the same range, finds the object with the same bytes, and moves on.",
  run(s) {
    s.act(s.the(Host), "write");
    s.act(s.the(Host), "upload");
    s.settle({ until: (w) => idle(w) && !w.the(SessionDO).state.untranslated && w.the(SessionDO).state.putting === null && w.the(SessionDO).state.alarm });
    s.step(s.the(SessionDO), "alarm");
    s.deliver(s.the(Bucket), Put);
    s.step(s.the(SessionDO), "storedLost");
    s.settle({ until: (w) => copied(w) });
  },
});
const before = defineScenario("A Session stored before backups", {
  description: "Its records have no copy; the HostDO's backfill sets the alarm once, and the alarms copy it, oldest first, a chunk at a time.",
  setup(w) {
    w.set(Host, { file: ["l1", "l2", "l3"], written: 3, acked: 3 });
    w.set(SessionDO, {
      gen: "gen-0",
      lines: ["l1", "l2", "l3"],
      ledger: ["l1", "l2", "l3"].map((line, i) => ({ gen: "gen-0", epoch: 1, cursor: i + 1, line, lost: false })),
      alarm: true,
    });
  },
  run(s) {
    s.settle({ until: (w) => copied(w) });
  },
});

export default defineSpec({
  name: "Session backups",
  description: "How each SessionDO copies its committed records to R2 as write-once objects, across cuts, lost answers, restarts and a lost storage, without leaving a record that can be read from neither.",
  actors: [Host, SessionDO, Bucket],
  properties: [noRecordLost, copiesAreFaithful, objectsNeverChange, neverForgotten, catchesUp, restoredAfterCut],
  scenarios: [live, cut, lostAnswer, before],
});
