import { atMost, budget, defineActor, defineCall, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone, failed, FAULT, listOf, lose, nullable, oneOf, spend } from "@leostera/feynman";

// RFD0032, Sync from the index: when axod connects, it sends the HostDO a manifest of every
// Session it has, with the count and chain of each transcript, and the HostDO answers with what
// the cloud holds. Until now the HostDO asked every SessionDO for its head: 300 to 600 billed
// calls per reconnect for a Mac with 307 Sessions, nearly all of them to say nothing changed.
// The HostDO's index already caches each Session's head and chain, so it answers from there when
// the index agrees with the manifest, and asks the SessionDO only when they differ.
//
// The risk is an index that lags the SessionDO: a commit lands, and the HostDO is reset or the
// reply is lost before it updates the index. If the Mac's file then shrinks back to exactly what the
// index says, the index agrees with the manifest while the SessionDO holds more, and nothing would
// ever ask the SessionDO again. Two rules close it:
// - distrustWhileWriting: a row is marked unverified in SQLite before every write to the SessionDO,
//   and only the SessionDO's answer verifies it, so a lost answer or a reset leaves it distrusted;
// - fenceOnVerify: a write sent by a HostDO that was then reset can still land after the new
//   instance read the head. Each head read raises a fence the SessionDO keeps, and it refuses
//   writes with an older one. axod hears such a refusal as the conflict it already handles.
//
// One Session. Records are letters; a chain is the records joined, standing in for the hash chain
// (same chain, same records). Epochs are left out: a truncate here just cuts. The Mac's own file
// changes by its actions: Pi writes a record, or the file is rewritten (it shrinks to one record
// and grows a different one), which is what makes the copies diverge.

/** Faults on one path: lost calls between Durable Objects. */
const faults = budget("faults", 1);

const answerFromIndex = defineRule("answerFromIndex", {
  description: "The handshake answers a Session from the index when the index's count and chain are the manifest's, without asking the SessionDO.",
});
const distrustWhileWriting = defineRule("distrustWhileWriting", {
  description: "Before it sends an append or a truncate to the SessionDO, the HostDO marks the index row unverified, and only the SessionDO's answer verifies it again. A handshake trusts only a verified row, so a lost answer or a reset mid-write never leaves a lagging row trusted.",
});
const fenceOnVerify = defineRule("fenceOnVerify", {
  description: "A handshake that reads a SessionDO's head raises the HostDO's fence (a counter in SQLite) and passes it along; the SessionDO then refuses writes carrying an older fence, so an append from a HostDO that was reset can't land after the head that verified the index.",
});

type Cloud = { count: number; chain: string };

function chainOf(records: readonly string[], count = records.length): string {
  return records.slice(0, count).join("") || "-";
}

const Sync = defineCall("Sync", { upload: nullable({ count: Number, chain: String }) }, { name: "axo.host.sync", over: "websocket" });
const Synced = defineMessage("Synced", { state: oneOf("known", "unknown"), count: Number, chain: String }, { name: "what the cloud holds", over: "websocket", tone: "reply" });
const Append = defineCall("Append", { from: Number, records: listOf(String) }, { name: "axo.host.session.append", over: "websocket" });
const Appended = defineMessage("Appended", { outcome: oneOf("committed", "gap", "conflict"), count: Number, chain: String }, { name: "append outcome", over: "websocket", tone: "reply" });
const Chains = defineCall("Chains", {}, { name: "axo.host.session.chainAt", over: "websocket" });
const ChainsAre = defineMessage("ChainsAre", { chains: listOf(String) }, { name: "chains", over: "websocket", tone: "reply" });
const Truncate = defineCall("Truncate", { keep: Number, expected: String }, { name: "axo.host.session.truncate", over: "websocket" });
const Truncated = defineMessage("Truncated", { outcome: oneOf("truncated", "mismatch"), count: Number, chain: String }, { name: "truncate outcome", over: "websocket", tone: "reply" });

const Failed = defineMessage("Failed", {}, { name: "an error reply", over: "websocket", tone: "refused" });
const Head = defineCall("Head", { inc: Number, fence: Number }, { name: "SessionDO.head", over: "rpc" });
const HeadIs = defineMessage("HeadIs", { inc: Number, count: Number, chain: String }, { name: "head", over: "rpc", tone: "reply" });
const Store = defineCall("Store", { inc: Number, fence: Number, from: Number, records: listOf(String) }, { name: "SessionDO.append", over: "rpc" });
const Stored = defineMessage("Stored", { inc: Number, outcome: oneOf("committed", "gap", "conflict", "fenced"), count: Number, chain: String }, { name: "stored", over: "rpc", tone: "reply" });
const ReadChains = defineCall("ReadChains", { inc: Number }, { name: "SessionDO.chains", over: "rpc" });
const ChainsRead = defineMessage("ChainsRead", { inc: Number, chains: listOf(String) }, { name: "chains", over: "rpc", tone: "reply" });
const Cut = defineCall("Cut", { inc: Number, fence: Number, keep: Number, expected: String }, { name: "SessionDO.truncate", over: "rpc" });
const CutDone = defineMessage("CutDone", { inc: Number, outcome: oneOf("truncated", "mismatch", "fenced"), count: Number, chain: String }, { name: "cut", over: "rpc", tone: "reply" });

const mac = defineZone({ name: "Mac", description: "axod and Pi's transcript", place: { column: 0 } });
const edge = defineZone({ name: "Cloudflare", description: "the Mac's HostDO and the Session's SessionDO", place: { column: 1, region: true } });

export const Axod = defineActor({
  name: "axod",
  description: "The Mac's daemon: it reads Pi's transcript, handshakes with the HostDO, and uploads what the cloud lacks.",
  zone: mac,
  singleton: true,
  initialState: () => ({
    /** Pi's transcript file. */
    file: [] as string[],
    /** What it believes the cloud holds after the last handshake; null until one succeeds. */
    cloud: null as Cloud | null,
    handshakeDue: true,
    /** A call to the HostDO is waiting for its answer. */
    waiting: null as null | "sync" | "append" | "chains" | "truncate",
    /** What the last append sent, to move `cloud` on when it commits. */
    sent: null as string[] | null,
    rewrites: 0,
  }),
  display: {
    icon: "laptop",
    status: (s) => `file ${chainOf(s.file)}, believes the cloud holds ${s.cloud ? s.cloud.chain : "?"}`,
    mood: (s) => (s.cloud && s.cloud.chain === chainOf(s.file) ? "ok" : "busy"),
  },
  actions: {
    write: {
      with: [atMost(2)],
      label: "Pi writes a record",
      description: "A new line lands in the transcript.",
      when: (s) => s.file.length < 3,
      run: (s) => void s.file.push(s.rewrites ? "b" : "a"),
    },
    rewrite: {
      with: [atMost(1)],
      label: "The transcript is rewritten",
      description: "The file shrinks back to its first record; what Pi writes next differs from what the cloud may hold.",
      when: (s) => s.file.length >= 1,
      run(s) {
        s.rewrites += 1;
        s.file = [s.file[0]!];
        // axod notices the file shrank below what it uploaded: only a handshake can tell.
        s.handshakeDue = true;
      },
    },
  },
  transitions: {
    handshake: {
      description: "Sends the manifest: the count and chain of the transcript.",
      sources: ["crates/axo-relay/src/sync/uploader.rs#Uploader::handshake"],
      when: (s) => s.handshakeDue && s.waiting === null,
      sends: [Sync],
      run(s, _m, ctx) {
        s.handshakeDue = false;
        s.waiting = "sync";
        ctx.send(ctx.the(HostDO), Sync, { upload: s.file.length ? { count: s.file.length, chain: chainOf(s.file) } : null });
      },
    },
    synced: {
      on: Synced,
      description: "Learns what the cloud holds: a prefix of the file is uploaded from its end; a divergence is cut back first.",
      sources: ["crates/axo-relay/src/sync/uploader.rs#Uploader::handshake"],
      sends: [Chains],
      run(s, msg, ctx) {
        s.waiting = null;
        if (msg.state === "unknown") return void (s.cloud = { count: 0, chain: "-" });
        if (msg.count <= s.file.length && chainOf(s.file, msg.count) === msg.chain) return void (s.cloud = { count: msg.count, chain: msg.chain });
        s.cloud = null;
        s.waiting = "chains";
        ctx.send(ctx.the(HostDO), Chains, {});
      },
    },
    chainsAre: {
      on: ChainsAre,
      description: "Finds the longest prefix both copies share, and asks the cloud to cut back to it.",
      sources: ["crates/axo-relay/src/sync/uploader.rs#Uploader::realign"],
      sends: [Truncate],
      run(s, msg, ctx) {
        let keep = 0;
        for (let i = 1; i <= Math.min(s.file.length, msg.chains.length - 1); i++) if (msg.chains[i] === chainOf(s.file, i)) keep = i;
        s.waiting = "truncate";
        ctx.send(ctx.the(HostDO), Truncate, { keep, expected: msg.chains[keep] ?? "-" });
      },
    },
    truncated: {
      on: Truncated,
      description: "The cloud is cut back to the shared prefix; a mismatch means it moved, so the handshake runs again.",
      sources: ["crates/axo-relay/src/sync/uploader.rs#Uploader::realign"],
      run(s, msg) {
        s.waiting = null;
        if (msg.outcome === "truncated") s.cloud = { count: msg.count, chain: msg.chain };
        else s.handshakeDue = true;
      },
    },
    upload: {
      description: "Appends the next record the cloud lacks.",
      sources: ["crates/axo-relay/src/sync/uploader.rs#Uploader::upload_next"],
      when: (s) => !s.handshakeDue && s.waiting === null && s.cloud !== null && s.cloud.count < s.file.length,
      sends: [Append],
      run(s, _m, ctx) {
        const from = s.cloud!.count + 1;
        s.sent = s.file.slice(from - 1, from);
        s.waiting = "append";
        ctx.send(ctx.the(HostDO), Append, { from, records: s.sent });
      },
    },
    appended: {
      on: Appended,
      description: "A committed append moves its belief on; a gap or a conflict means the cloud is not what it thought, so it handshakes again.",
      sources: ["crates/axo-relay/src/sync/uploader.rs#Uploader::upload_next"],
      run(s, msg) {
        s.waiting = null;
        if (msg.outcome === "committed") s.cloud = { count: msg.count, chain: msg.chain };
        else {
          s.cloud = null;
          s.handshakeDue = true;
        }
      },
    },
    failed: {
      on: Failed,
      description: "The HostDO answered with an error: the call may have run, so axod handshakes again.",
      run: (s) => void ((s.waiting = null), (s.cloud = null), (s.handshakeDue = true)),
    },
    // A call that fails is the socket dropping: axod reconnects and handshakes again.
    syncFailed: { on: failed(Sync), description: "The socket dropped: it reconnects and handshakes.", run: (s) => void ((s.waiting = null), (s.handshakeDue = true)) },
    appendFailed: { on: failed(Append), description: "The socket dropped mid-append: it reconnects and handshakes.", run: (s) => void ((s.waiting = null), (s.cloud = null), (s.handshakeDue = true)) },
    chainsFailed: { on: failed(Chains), description: "The socket dropped: it reconnects and handshakes.", run: (s) => void ((s.waiting = null), (s.handshakeDue = true)) },
    truncateFailed: { on: failed(Truncate), description: "The socket dropped: it reconnects and handshakes.", run: (s) => void ((s.waiting = null), (s.cloud = null), (s.handshakeDue = true)) },
  },
});

export const HostDO = defineActor({
  name: "HostDO",
  description: "The Mac's Durable Object: it answers the handshake, keeps the index, and routes appends and truncates to the SessionDO.",
  zone: edge,
  singleton: true,
  initialState: () => ({
    /** The index row: the head and chain it last heard from the SessionDO. */
    index: { count: 0, chain: "-", known: false, verified: true } as Cloud & { known: boolean; verified: boolean },
    /** A call to the SessionDO waiting, and the upload it answers for. */
    pending: null as null | "sync" | "append" | "chains" | "truncate",
    /** The fence, in SQLite: raised by each handshake that reads a head. */
    fence: 0,
    /** Which instance this is: a reset starts a new one, and answers to an older one reach no one. */
    inc: 0,
    /** The upload of the handshake being answered. */
    manifest: null as Cloud | null,
  }),
  display: {
    icon: "cloud",
    status: (s) => `index says ${s.index.known ? s.index.chain : "nothing"}`,
    rows: (s) => [{ label: "index", detail: s.index.known ? `${s.index.count} record(s), ${s.index.chain}` : "unknown" }],
  },
  transitions: {
    sync: {
      on: Sync,
      description: "Answers the handshake from the index when it agrees with the manifest, or asks the SessionDO.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.sync"],
      sends: [Synced, Head],
      run(s, msg, ctx) {
        s.manifest = msg.upload;
        const trusted = s.index.verified || !distrustWhileWriting.on;
        const agrees = trusted && (msg.upload ? s.index.known && s.index.count === msg.upload.count && s.index.chain === msg.upload.chain : true);
        if (answerFromIndex.on && agrees) return ctx.reply(Synced, { state: s.index.known ? "known" : "unknown", count: s.index.count, chain: s.index.chain });
        s.pending = "sync";
        if (fenceOnVerify.on) s.fence += 1;
        ctx.send(ctx.the(SessionDO), Head, { inc: s.inc, fence: s.fence });
      },
    },
    headIs: {
      on: HeadIs,
      description: "Refreshes the index from the SessionDO and answers the handshake.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.refreshHead"],
      sends: [Synced],
      run(s, msg, ctx) {
        if (!s.pending || msg.inc !== s.inc) return;
        s.pending = null;
        s.index = { count: msg.count, chain: msg.chain, known: msg.count > 0, verified: true };
        ctx.send(ctx.the(Axod), Synced, { state: msg.count > 0 ? "known" : "unknown", count: msg.count, chain: msg.chain });
      },
    },
    headFailed: {
      on: failed(Head),
      description: "The SessionDO call threw: the handshake fails, and axod reconnects.",
      sends: [Failed],
      run: (s, f, ctx) => void (f.payload.inc === s.inc && s.pending && ((s.pending = null), ctx.send(ctx.the(Axod), Failed, {}))),
    },
    append: {
      on: Append,
      description: "Routes the append to the SessionDO.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.append"],
      sends: [Store],
      run(s, msg, ctx) {
        s.pending = "append";
        if (distrustWhileWriting.on) s.index.verified = false;
        ctx.send(ctx.the(SessionDO), Store, { ...msg, inc: s.inc, fence: s.fence });
      },
    },
    stored: {
      on: Stored,
      description: "Refreshes the index from what the SessionDO says it holds, committed or not, and answers axod.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.append"],
      sends: [Appended],
      run(s, msg, ctx) {
        if (!s.pending || msg.inc !== s.inc) return;
        s.pending = null;
        s.index = { count: msg.count, chain: msg.chain, known: msg.count > 0, verified: true };
        // A fenced write reaches axod as the conflict it already handles: the wire does not change.
        ctx.send(ctx.the(Axod), Appended, { outcome: msg.outcome === "fenced" ? "conflict" : msg.outcome, count: msg.count, chain: msg.chain });
      },
    },
    storeFailed: {
      on: failed(Store),
      description: "The SessionDO call threw, or its answer was lost: the append may have landed, and the index is not updated. axod's socket drops with it.",
      sends: [Failed],
      run: (s, f, ctx) => void (f.payload.inc === s.inc && s.pending && ((s.pending = null), ctx.send(ctx.the(Axod), Failed, {}))),
    },
    chains: {
      on: Chains,
      description: "Reads the SessionDO's chains for axod's search.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.chainAt"],
      sends: [ReadChains],
      run(s, _m, ctx) {
        s.pending = "chains";
        ctx.send(ctx.the(SessionDO), ReadChains, { inc: s.inc });
      },
    },
    chainsRead: {
      on: ChainsRead,
      description: "Passes the chains on.",
      sends: [ChainsAre],
      run(s, msg, ctx) {
        if (!s.pending || msg.inc !== s.inc) return;
        s.pending = null;
        ctx.send(ctx.the(Axod), ChainsAre, { chains: msg.chains });
      },
    },
    chainsFailed: { on: failed(ReadChains), description: "The SessionDO call threw: axod hears an error.", sends: [Failed], run: (s, f, ctx) => void (f.payload.inc === s.inc && s.pending && ((s.pending = null), ctx.send(ctx.the(Axod), Failed, {}))) },
    chainsReadLost: lose(ChainsRead, { fails: ReadChains, spend: faults }),
    truncate: {
      on: Truncate,
      description: "Asks the SessionDO to cut back to the prefix, if it still holds what axod saw.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.truncate"],
      sends: [Cut],
      run(s, msg, ctx) {
        s.pending = "truncate";
        if (distrustWhileWriting.on) s.index.verified = false;
        ctx.send(ctx.the(SessionDO), Cut, { ...msg, inc: s.inc, fence: s.fence });
      },
    },
    cutDone: {
      on: CutDone,
      description: "Refreshes the index from the cut and answers axod.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.truncate"],
      sends: [Truncated],
      run(s, msg, ctx) {
        if (!s.pending || msg.inc !== s.inc) return;
        s.pending = null;
        s.index = { count: msg.count, chain: msg.chain, known: msg.count > 0, verified: true };
        ctx.send(ctx.the(Axod), Truncated, { outcome: msg.outcome === "fenced" ? "mismatch" : msg.outcome, count: msg.count, chain: msg.chain });
      },
    },
    cutFailed: { on: failed(Cut), description: "The SessionDO call threw: the cut may have happened; the index is not updated, and axod hears an error.", sends: [Failed], run: (s, f, ctx) => void (f.payload.inc === s.inc && s.pending && ((s.pending = null), ctx.send(ctx.the(Axod), Failed, {}))) },
    reset: {
      when: (s) => s.pending !== null,
      fair: false,
      tags: [FAULT],
      with: [spend(faults)],
      description: "The HostDO is reset with a call to the SessionDO in flight (a forced code update, an eviction): axod's socket drops, the answer reaches no one, and the index keeps what SQLite had.",
      sends: [Failed],
      run(s, _m, ctx) {
        s.pending = null;
        s.inc += 1;
        ctx.send(ctx.the(Axod), Failed, {});
      },
    },
    // axod's socket drops with a call on it.
    syncLost: lose(Sync, { spend: faults }),
    appendLost: lose(Append, { spend: faults }),
    chainsLost: lose(Chains, { spend: faults }),
    truncateLost: lose(Truncate, { spend: faults }),
    // A lost answer from the SessionDO is the case that leaves the index behind.
    storedLost: lose(Stored, { fails: Store, spend: faults }),
    cutDoneLost: lose(CutDone, { fails: Cut, spend: faults }),
    headIsLost: lose(HeadIs, { fails: Head, spend: faults }),
  },
});

export const SessionDO = defineActor({
  name: "SessionDO",
  description: "The Session's Durable Object: the records, checked against what they follow.",
  zone: edge,
  singleton: true,
  initialState: () => ({ records: [] as string[], /** The highest fence a head read carried. */ fence: 0 }),
  display: {
    icon: "database",
    status: (s) => `${s.records.length} record(s): ${chainOf(s.records)}`,
  },
  transitions: {
    head: {
      on: Head,
      description: "Says how many records it holds and their chain.",
      sources: ["packages/axo-api-worker/src/session-store.ts#AxoSessionDO.head"],
      sends: [HeadIs],
      run(s, msg, ctx) {
        s.fence = Math.max(s.fence, msg.fence);
        ctx.reply(HeadIs, { inc: msg.inc, count: s.records.length, chain: chainOf(s.records) });
      },
    },
    store: {
      on: Store,
      description: "Appends records that follow what it holds; a retry that overlaps must match; past the end is a gap.",
      sources: ["packages/axo-api-worker/src/session-store.ts#AxoSessionDO.append"],
      sends: [Stored],
      run(s, msg, ctx) {
        const answer = (outcome: "committed" | "gap" | "conflict" | "fenced") => ctx.reply(Stored, { inc: msg.inc, outcome, count: s.records.length, chain: chainOf(s.records) });
        if (msg.fence < s.fence) return answer("fenced");
        if (msg.from > s.records.length + 1) return answer("gap");
        for (let i = 0; i < msg.records.length; i++) {
          const at = msg.from - 1 + i;
          if (at < s.records.length) {
            if (s.records[at] !== msg.records[i]) return answer("conflict");
          } else s.records.push(msg.records[i]!);
        }
        answer("committed");
      },
    },
    readChains: {
      on: ReadChains,
      description: "Returns the chain at every position, from nothing to the head.",
      sources: ["packages/axo-api-worker/src/session-store.ts:170-174"],
      sends: [ChainsRead],
      run: (s, msg, ctx) => ctx.reply(ChainsRead, { inc: msg.inc, chains: s.records.map((_r, i) => chainOf(s.records, i)).concat(chainOf(s.records)) }),
    },
    cut: {
      on: Cut,
      description: "Cuts back to `keep` records if its chain there is still the one axod saw.",
      sources: ["packages/axo-api-worker/src/session-store.ts#AxoSessionDO.truncate"],
      sends: [CutDone],
      run(s, msg, ctx) {
        if (msg.fence < s.fence) return ctx.reply(CutDone, { inc: msg.inc, outcome: "fenced", count: s.records.length, chain: chainOf(s.records) });
        if (chainOf(s.records, msg.keep) !== msg.expected || msg.keep > s.records.length) return ctx.reply(CutDone, { inc: msg.inc, outcome: "mismatch", count: s.records.length, chain: chainOf(s.records) });
        s.records = s.records.slice(0, msg.keep);
        ctx.reply(CutDone, { inc: msg.inc, outcome: "truncated", count: s.records.length, chain: chainOf(s.records) });
      },
    },
  },
});

const believesOnlyWhatIsThere = defineProperty("believesOnlyWhatIsThere", {
  description: "What axod believes the cloud holds is always a prefix of what the SessionDO holds: it never uploads past a hole.",
  always: (w) => {
    const cloud = w.the(Axod).state.cloud;
    const records = w.the(SessionDO).state.records;
    return cloud === null || (cloud.count <= records.length && chainOf(records, cloud.count) === cloud.chain);
  },
});
const converges = defineProperty("converges", {
  needs: [distrustWhileWriting, fenceOnVerify],
  description: "Once the transcript stops changing, the SessionDO ends up holding exactly the Mac's transcript.",
  eventuallyAlways: (w) => chainOf(w.the(SessionDO).state.records) === chainOf(w.the(Axod).state.file) && w.the(Axod).state.waiting === null,
});
const quietHandshakesAskNothing = defineProperty("quietHandshakesAskNothing", {
  needs: [answerFromIndex],
  description: "A handshake for a Session the index already agrees with asks the SessionDO nothing.",
  everyStep: (before, after, e) => {
    if (!e.is(HostDO, "sync")) return true;
    const index = before.the(HostDO).state.index;
    const upload = after.the(HostDO).state.manifest;
    const agrees = index.verified && (upload === null || (index.known && index.count === upload.count && index.chain === upload.chain));
    return !agrees || after.the(HostDO).state.pending === null;
  },
});

const aQuietReconnect = defineScenario("A quiet reconnect", {
  description: "axod reconnects with nothing new: the index agrees with its manifest, so the HostDO answers without asking the SessionDO.",
  setup(w) {
    w.set(Axod, { file: ["a", "a"] });
    w.set(HostDO, { index: { count: 2, chain: "aa", known: true, verified: true } });
    w.set(SessionDO, { records: ["a", "a"] });
  },
  run(s) {
    s.settle({ until: (w) => w.the(Axod).state.cloud?.count === 2 });
  },
});
const anIndexLeftBehind = defineScenario("An index left behind", {
  description: "A commit's answer is lost, so the index lags, and the transcript shrinks back to exactly what the index says. The row is unverified, so the handshake asks the SessionDO, finds the divergence and cuts the cloud back.",
  setup(w) {
    w.set(Axod, { file: ["a"] });
    w.set(HostDO, { index: { count: 1, chain: "a", known: true, verified: true } });
    w.set(SessionDO, { records: ["a"] });
  },
  run(s) {
    s.settle({ until: (w) => w.the(Axod).state.cloud?.count === 1 });
    s.act(s.the(Axod), "write");
    s.settle({ until: (w) => w.the(HostDO).state.pending === "append" && w.the(SessionDO).state.records.length === 2 });
    s.step(s.the(HostDO), "storedLost");
    s.act(s.the(Axod), "rewrite");
    s.settle({ until: (w) => chainOf(w.the(SessionDO).state.records) === chainOf(w.the(Axod).state.file) && w.the(Axod).state.waiting === null && !w.the(Axod).state.handshakeDue });
  },
});

export default defineSpec({
  name: "Sync from the index",
  description: "How a HostDO answers axod's handshake from its index instead of asking every SessionDO, and why the index can lag but never mislead it for long.",
  actors: [Axod, HostDO, SessionDO],
  properties: [believesOnlyWhatIsThere, converges, quietHandshakesAskNothing],
  scenarios: [aQuietReconnect, anIndexLeftBehind],
  finalState: {
    description: "The copies agree and axod waits for Pi to write.",
    when: (w) => w.quiet && chainOf(w.the(SessionDO).state.records) === chainOf(w.the(Axod).state.file) && !w.the(Axod).state.handshakeDue,
  },
});
