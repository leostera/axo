import { atMost, budget, crash, defineActor, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone, listOf, lose } from "@leostera/feynman";

// RFD0027: an archived Session's transcript is deleted from the Mac once the cloud holds it whole,
// and reopening the Session fetches it back before Pi starts.
//
// One Session on one Mac is modelled, with at most two lines. The uploader (RFD0018, modelled in
// full in session-sync.ts) is cut down to what eviction depends on: it learns what the cloud holds
// from a handshake, appends one line at a time, and stores the cloud's acknowledged count in
// axo.db. Lines are their own chains: a copy is checked by comparing the lines.
//
// Not modelled: divergence and truncation (session-sync.ts), metadata, other Macs' copies.

const MAX_LINES = 2;

/** Faults on one path: lost messages and crashes. `--set faults=2` raises it. */
const faults = budget("faults", 1);

const confirmedWhole = defineRule("confirmedWhole", {
  description: "A transcript is deleted only once the cloud acknowledged every line of the file, as axo.db records.",
});
const recordBeforeDelete = defineRule("recordBeforeDelete", {
  description: "axo.db records that the transcript is in the cloud before the file is deleted.",
});

const keepWhileReopening = defineRule("keepWhileReopening", {
  description: "A Session being reopened keeps its transcript, even one the reopen found on disk before it took the catalog lock.",
});

const Sync = defineMessage("Sync", { round: Number }, { name: "axo.host.sync", over: "websocket" });
const SyncReply = defineMessage("SyncReply", { round: Number, count: Number }, { name: "what the cloud holds", over: "websocket", tone: "reply" });
const Append = defineMessage("Append", { round: Number, from: Number, line: String }, { name: "axo.host.session.append", over: "websocket" });
const Appended = defineMessage("Appended", { round: Number, count: Number }, { name: "committed", over: "websocket", tone: "reply" });
const Fetch = defineMessage("Fetch", { attempt: Number }, { name: "axo.client.session.open", over: "websocket" });
const Fetched = defineMessage("Fetched", { attempt: Number, lines: listOf(String) }, { name: "the records", over: "websocket", tone: "reply" });

const mac = defineZone({ name: "Mac", description: "axod and Pi", place: { column: 0 } });
const cloud = defineZone({ name: "Cloudflare", description: "the Session's SessionDO", place: { column: 1, region: true } });

type Reopen = "no" | "fetching" | "ready";

function same(a: readonly string[] | null, b: readonly string[]): boolean {
  return a !== null && a.length === b.length && a.every((line, i) => line === b[i]);
}

export const Axod = defineActor({
  name: "axod",
  description: "The Mac's daemon: it uploads the Session's transcript, deletes it once archived and held by the cloud, and restores it on reopen.",
  zone: mac,
  singleton: true,
  initialState: () => ({
    /** The transcript on disk; null once deleted. */
    file: ["l1"] as string[] | null,
    /** Every line Pi ever wrote, in order (not on disk: what must never be lost). */
    history: ["l1"] as string[],
    archived: false,
    pi: true,
    /** axo.db: the cloud's acknowledged count, and whether the transcript is in the cloud only. */
    cursor: 0,
    inCloud: false,
    /** The uploader, in memory: what the last handshake or acknowledgement said the cloud holds. */
    known: null as number | null,
    round: 0,
    appending: false,
    syncing: false,
    /** An eviction between its two steps. */
    evicting: false,
    reopen: "no" as Reopen,
    attempt: 0,
    /** Reopens refused after the transcript was fetched back: undone by a second eviction. */
    undone: 0,
  }),
  display: {
    icon: "laptop",
    status: (s) => (s.pi ? "open, Pi running" : s.archived ? (s.file ? "archived" : "archived, in the cloud") : "open"),
    mood: (s) => (s.pi ? "ok" : s.file ? "info" : "off"),
    rows: (s) => [
      { label: "transcript", detail: s.file ? s.file.join(", ") || "empty" : "deleted", mood: s.file ? "info" : "off" },
      { label: "axo.db", detail: `cursor ${s.cursor}${s.inCloud ? ", in the cloud" : ""}` },
    ],
  },
  links: () => [{ to: "SessionDO", kind: "websocket" }],
  actions: {
    piWrites: {
      with: [atMost(1)],
      label: "Pi appends a line",
      description: "Pi finishes an entry and appends it to the transcript.",
      when: (s) => s.pi && s.file !== null && s.file.length < MAX_LINES,
      run(state) {
        const line = `l${state.history.length + 1}`;
        state.file!.push(line);
        state.history.push(line);
      },
    },
    archive: {
      with: [atMost(2)],
      label: "Archive the Session",
      description: "The person closes the Session: Pi stops, and the Session is archived.",
      when: (s) => s.pi,
      sources: ["crates/axo-server/src/session/lifecycle.rs#SessionManager::close_session_and_publish"],
      run(state) {
        state.pi = false;
        state.archived = true;
      },
    },
    reopen: {
      with: [atMost(2)],
      label: "Reopen the Session",
      description: "The person reopens it: a transcript in the cloud only is fetched back first.",
      // Eviction holds the catalog lock from recording to deleting: a reopen waits for it.
      when: (s) => s.archived && s.reopen === "no" && !s.evicting,
      sources: ["crates/axo-server/src/session/cloud_transcripts.rs#Reopening::begin", "crates/axo-server/src/session/cloud_transcripts.rs#SessionManager::restore_transcript"],
      sends: [Fetch],
      starts: ["fetchTimeout"],
      run(state, _i, ctx) {
        // Already back, or never deleted (a crash between recording and deleting).
        if (!state.inCloud || same(state.file, state.history.slice(0, state.cursor))) {
          state.reopen = "ready";
          return;
        }
        state.reopen = "fetching";
        state.attempt += 1;
        ctx.send(ctx.the(SessionDO), Fetch, { attempt: state.attempt });
        ctx.start("fetchTimeout");
      },
    },
  },
  transitions: {
    handshake: {
      description: "The uploader asks what the cloud holds.",
      when: (s) => s.known === null && !s.syncing,
      sources: ["crates/axo-relay/src/sync/uploader.rs#Uploader::handshake"],
      sends: [Sync],
      starts: ["requestTimeout"],
      run(state, _, ctx) {
        state.round += 1;
        state.syncing = true;
        state.appending = false;
        ctx.send(ctx.the(SessionDO), Sync, { round: state.round });
        ctx.start("requestTimeout");
      },
    },
    syncReply: {
      on: SyncReply,
      description: "The cloud's count is known; with the file read, axo.db's cursor follows it.",
      sources: ["crates/axo-relay/src/sync/uploader.rs#Uploader::handshake"],
      run(state, m, ctx) {
        if (m.round !== state.round) return;
        state.syncing = false;
        state.known = m.count;
        if (readable(state) && m.count <= state.file!.length) state.cursor = m.count;
        ctx.cancel("requestTimeout");
      },
    },
    upload: {
      description: "Appends the next line the cloud is missing.",
      when: (s) => s.known !== null && !s.appending && readable(s) && s.known < s.file!.length,
      sources: ["crates/axo-relay/src/sync/uploader.rs#Uploader::upload_next"],
      sends: [Append],
      starts: ["requestTimeout"],
      run(state, _, ctx) {
        state.appending = true;
        ctx.send(ctx.the(SessionDO), Append, { round: state.round, from: state.known! + 1, line: state.file![state.known!]! });
        ctx.start("requestTimeout");
      },
    },
    appended: {
      on: Appended,
      description: "The cloud committed the line: axo.db's cursor moves.",
      sources: ["crates/axo-relay/src/sync/uploader.rs#Uploader::upload_next"],
      run(state, m, ctx) {
        if (m.round !== state.round) return;
        state.appending = false;
        state.known = m.count;
        state.cursor = m.count;
        ctx.cancel("requestTimeout");
      },
    },
    requestTimeout: {
      with: [atMost(2)],
      description: "No answer in time: the handshake runs again.",
      after: "10 seconds",
      sources: ["crates/axo-relay/src/sync/uploader.rs#Uploader::turn"],
      run(state) {
        state.known = null;
        state.syncing = false;
        state.appending = false;
      },
    },
    evict: {
      description: "An archived Session the cloud acknowledged whole: axo.db records it is in the cloud.",
      when: (s) => s.archived && !s.pi && !s.evicting && !(keepWhileReopening.on && s.reopen !== "no") && readable(s) && s.file!.length > 0 && (!confirmedWhole.on || (s.cursor === s.file!.length && s.known === s.file!.length)),
      sources: ["crates/axo-relay/src/sync/uploader.rs#Uploader::evict_next", "crates/axo-store/src/sync.rs#mark_transcript_in_cloud"],
      run(state) {
        state.evicting = true;
        if (recordBeforeDelete.on) state.inCloud = true;
        else state.file = null;
      },
    },
    evicted: {
      description: "The file is deleted, and the uploader forgets it.",
      when: (s) => s.evicting,
      sources: ["crates/axo-server/src/session/cloud_transcripts.rs#SessionManager::evict_transcript"],
      run(state) {
        state.evicting = false;
        if (recordBeforeDelete.on) state.file = null;
        else state.inCloud = true;
      },
    },
    fetch: {
      on: Fetched,
      description: "The records came back into the restore folder: checked against axo.db, then moved into place.",
      sources: ["crates/axo-relay/src/peers/follower.rs#Follower::restored", "crates/axo-server/src/session/cloud_transcripts.rs#SessionManager::restore_transcript"],
      run(state, m, ctx) {
        if (state.reopen !== "fetching" || m.attempt !== state.attempt) return;
        ctx.cancel("fetchTimeout");
        if (state.inCloud && same(m.lines, state.history.slice(0, state.cursor))) {
          state.file = [...m.lines];
          state.reopen = "ready";
        } else {
          state.reopen = "no";
        }
      },
    },
    fetchTimeout: {
      description: "The cloud did not answer in time: the reopen fails, and nothing changes.",
      after: "60 seconds",
      sources: ["crates/axo-relay/src/peers/live.rs#PeerLive::restore"],
      run(state) {
        if (state.reopen === "fetching") state.reopen = "no";
      },
    },
    reopened: {
      description: "Under the catalog lock: the transcript must be back; axo.db forgets it was in the cloud, and Pi starts on it.",
      when: (s) => s.reopen === "ready" && !s.evicting,
      sources: ["crates/axo-server/src/session/cloud_transcripts.rs#reopened_with_transcript", "crates/axo-server/src/session/pi_recovery.rs#SessionManager::reopen_archived"],
      run(state) {
        state.reopen = "no";
        if (state.inCloud && !same(state.file, state.history.slice(0, state.cursor))) {
          state.undone += 1;
          return;
        }
        state.inCloud = false;
        state.archived = false;
        // Pi refuses a transcript that is missing (restart_unavailable_pi).
        state.pi = state.file !== null;
      },
    },
    syncReplyLost: lose(SyncReply, { spend: faults }),
    appendedLost: lose(Appended, { spend: faults }),
    fetchedLost: lose(Fetched, { spend: faults }),
    crash: crash({ keeps: ["file", "history", "archived", "pi", "cursor", "inCloud", "round", "attempt", "undone"], spend: faults }),
  },
});

/**
 * The uploader reads the file: it is there, and not one axo.db says is in the cloud. (Not a rule:
 * with staging and keepWhileReopening nothing here depends on it; it keeps the uploader off a
 * file that only a reopen may vouch for.)
 */
function readable(s: { file: string[] | null; inCloud: boolean }): boolean {
  return s.file !== null && !s.inCloud;
}

export const SessionDO = defineActor({
  name: "SessionDO",
  description: "The cloud's copy of the Session's transcript.",
  zone: cloud,
  singleton: true,
  initialState: () => ({ lines: [] as string[] }),
  display: {
    icon: "database",
    status: (s) => `${s.lines.length} line(s)`,
    rows: (s) => [{ label: "records", detail: s.lines.join(", ") || "none" }],
  },
  transitions: {
    sync: {
      on: Sync,
      description: "Answers with how many records it holds.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.sync"],
      sends: [SyncReply],
      run: (state, m, ctx) => ctx.reply(SyncReply, { round: m.round, count: state.lines.length }),
    },
    append: {
      on: Append,
      description: "Commits the next line; one it already has is acknowledged again.",
      sources: ["packages/axo-api-worker/src/session-store.ts#AxoSessionDO.append"],
      sends: [Appended],
      run(state, m, ctx) {
        if (m.from === state.lines.length + 1) state.lines.push(m.line);
        ctx.reply(Appended, { round: m.round, count: state.lines.length });
      },
    },
    open: {
      on: Fetch,
      description: "A Mac reads back its own Session, every record of it.",
      sources: ["packages/axo-api-worker/src/client-do.ts#AxoClientDO.openSession"],
      sends: [Fetched],
      run: (state, m, ctx) => ctx.reply(Fetched, { attempt: m.attempt, lines: [...state.lines] }),
    },
  },
});

const nothingLost = defineProperty("nothingLost", {
  description: "Every line Pi wrote is in the file or in the cloud.",
  always: (w) => {
    const axod = w.the(Axod).state;
    const cloudLines = w.the(SessionDO).state.lines;
    return axod.history.every((line, i) => axod.file?.[i] === line || cloudLines[i] === line);
  },
  needs: [confirmedWhole],
});

const piHasItsTranscript = defineProperty("piHasItsTranscript", {
  description: "Pi runs only on the whole transcript.",
  always: (w) => {
    const axod = w.the(Axod).state;
    return !axod.pi || same(axod.file, axod.history);
  },
});

const deletedIsRecorded = defineProperty("deletedIsRecorded", {
  description: "A transcript missing from the Mac is one axo.db says is in the cloud, so reopening fetches it.",
  always: (w) => {
    const axod = w.the(Axod).state;
    return axod.file !== null || axod.inCloud;
  },
  needs: [recordBeforeDelete],
});

const reopenNotUndone = defineProperty("reopenNotUndone", {
  description: "A transcript fetched back for a reopen is not deleted again before the Session opens.",
  always: (w) => w.the(Axod).state.undone === 0,
  needs: [keepWhileReopening],
});

const reopenOpens = defineProperty("reopenOpens", {
  description: "Reopening an archived Session ends: it opens, or the reopen fails and it stays archived.",
  leadsTo: { whenever: (w) => w.the(Axod).state.reopen !== "no", then: (w) => w.the(Axod).state.reopen === "no" },
});

const archiveAndReopen = defineScenario("Archive, then reopen", {
  description: "The transcript is uploaded; archived, it is deleted; reopened, it comes back as it was and Pi goes on.",
  run(s) {
    const axod = s.the(Axod);
    s.settle();
    s.act(axod, "piWrites");
    s.settle();
    s.act(axod, "archive");
    s.settle();
    s.act(axod, "reopen");
    s.settle();
  },
});

const crashBetween = defineScenario("A crash between recording and deleting", {
  description: "axo.db says the transcript is in the cloud, but the file is still there: reopening uses it without fetching.",
  run(s) {
    const axod = s.the(Axod);
    s.settle();
    s.act(axod, "archive");
    s.settle({ until: (w) => w.the(Axod).state.evicting });
    s.step(axod, "crash");
    s.act(axod, "reopen");
    s.settle();
  },
});

const cloudUnreachable = defineScenario("The cloud does not answer", {
  description: "The records never come back: the reopen fails, and the Session stays archived, in the cloud.",
  run(s) {
    const axod = s.the(Axod);
    s.settle();
    s.act(axod, "archive");
    s.settle();
    s.act(axod, "reopen");
    s.deliver(s.the(SessionDO), Fetch);
    s.step(axod, "fetchedLost");
    s.fire(axod, "fetchTimeout");
    s.settle();
  },
});

export default defineSpec({
  name: "Archived Sessions in the cloud",
  description: "An archived Session's transcript is deleted from the Mac once the cloud holds it whole, and fetched back when it reopens.",
  actors: [Axod, SessionDO],
  rules: [confirmedWhole, recordBeforeDelete, keepWhileReopening],
  properties: [nothingLost, piHasItsTranscript, deletedIsRecorded, reopenNotUndone, reopenOpens],
  scenarios: [archiveAndReopen, crashBetween, cloudUnreachable],
  finalState: {
    description: "Nothing is under way: the Session is open or archived, with nothing to upload, delete or fetch.",
    when: (w) => w.the(Axod).state.reopen === "no" && !w.the(Axod).state.evicting,
  },
});
