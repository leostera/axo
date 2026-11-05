import { atMost, budget, defineActor, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone, input, lose, oneOf } from "@leostera/feynman";

// RFD0030, the quota: an account holds at most QUOTA assets. Uploads run in parallel, from
// several devices, and an upload may be abandoned between storing its bytes and committing them
// (the Worker crashes, the client goes away). Reads, deletes and the cache are in specs/assets/assets.ts.
//
// Not built yet: no step has sources.

const faults = budget("faults", 1);

/** Assets the account may hold at once (10 GiB and 10,000 assets in the RFD; 2 here). */
const QUOTA = 2;

type Hash = "h1" | "h2" | "h3";
const HashKind = oneOf("h1", "h2", "h3");
const Answer = oneOf("reserved", "exists", "quota");

const Put = defineMessage("Put", { hash: HashKind }, { name: "PUT /assets/<hash>", over: "https" });
const PutDone = defineMessage("PutDone", { hash: HashKind, ok: Boolean }, { name: "PUT result", over: "https", tone: "reply" });
const Reserve = defineMessage("Reserve", { hash: HashKind }, { name: "reserve", over: "rpc" });
const Reserved = defineMessage("Reserved", { hash: HashKind, answer: Answer }, { name: "reserve result", over: "rpc", tone: "reply" });
const Commit = defineMessage("Commit", { hash: HashKind }, { name: "commit", over: "rpc" });
const Committed = defineMessage("Committed", { hash: HashKind, ok: Boolean }, { name: "commit result", over: "rpc", tone: "reply" });

const devices = defineZone({ name: "Leo's devices" });
const cloud = defineZone({ name: "Cloudflare", place: { column: 1, region: true } });

const reserveFirst = defineRule("reserveFirst", { description: "AxoAssetsDO counts an upload against the quota when it reserves it, not when it commits." });
const releaseAbandoned = defineRule("releaseAbandoned", { description: "A reservation not committed within 10 minutes is released by an alarm." });

export const Devices = defineActor({
  name: "Leo's phone and laptop",
  description: "Upload photos at the same time, three different ones.",
  zone: devices,
  singleton: true,
  initialState: () => ({ done: [] as string[], kept: [] as Hash[] }),
  display: { icon: "phone", status: (s) => s.done.join(", ") || "nothing yet" },
  actions: {
    upload: {
      with: [atMost(3)],
      label: "Upload",
      description: "A device uploads a photo.",
      inputs: { hash: input(HashKind, { examples: ["h1", "h2", "h3"] as const }) },
      sends: [Put],
      run: (_s, { hash }, ctx) => ctx.send(ctx.the(Worker), Put, { hash }),
    },
  },
  transitions: {
    done: {
      on: PutDone,
      description: "Uploaded, or refused.",
      run(s, m) {
        s.done.push(`${m.hash} ${m.ok ? "ok" : "refused"}`);
        if (m.ok) s.kept.push(m.hash);
      },
    },
  },
});

export const Worker = defineActor({
  name: "Worker",
  description: "Reserves, stores the bytes in R2 (always succeeds here), then commits.",
  zone: cloud,
  singleton: true,
  initialState: () => ({}),
  display: { icon: "server", status: () => "uploads" },
  transitions: {
    put: { on: Put, description: "Asks AxoAssetsDO to reserve.", sources: ["packages/axo-api-worker/src/http/assets.ts#upload"], sends: [Reserve], run: (_s, m, ctx) => ctx.send(ctx.the(AssetsDO), Reserve, m) },
    reserved: {
      on: Reserved,
      description: "Stores the bytes and commits, or answers at once.",
      sources: ["packages/axo-api-worker/src/http/assets.ts#upload"],
      sends: [Commit, PutDone],
      run(_s, m, ctx) {
        if (m.answer === "reserved") return ctx.send(ctx.the(AssetsDO), Commit, { hash: m.hash });
        ctx.send(ctx.the(Devices), PutDone, { hash: m.hash, ok: m.answer === "exists" });
      },
    },
    committed: {
      on: Committed,
      description: "Answers the upload only once it is committed; a commit too late fails it.",
      sources: ["packages/axo-api-worker/src/http/assets.ts#upload"],
      sends: [PutDone],
      run: (_s, m, ctx) => ctx.send(ctx.the(Devices), PutDone, m),
    },
  },
});

export const AssetsDO = defineActor({
  name: "AxoAssetsDO",
  description: "The account's index and quota.",
  zone: cloud,
  singleton: true,
  initialState: () => ({ assets: {} as Partial<Record<Hash, "reserved" | "ready">> }),
  display: { icon: "database", status: (s) => Object.entries(s.assets).map(([h, a]) => `${h} ${a}`).join(", ") || "empty" },
  transitions: {
    reserve: {
      on: Reserve,
      description: "Already there: exists. Over quota: refused. Otherwise reserved.",
      sources: ["packages/axo-api-worker/src/assets/assets-do.ts#AxoAssetsDO.reserve"],
      sends: [Reserved],
      starts: ["release"],
      run(s, m, ctx) {
        if (s.assets[m.hash] === "ready") return ctx.reply(Reserved, { hash: m.hash, answer: "exists" });
        if (s.assets[m.hash] === "reserved") return ctx.reply(Reserved, { hash: m.hash, answer: "quota" });
        const counted = Object.values(s.assets).filter((a) => a === "ready" || (reserveFirst.on && a === "reserved")).length;
        if (counted >= QUOTA) return ctx.reply(Reserved, { hash: m.hash, answer: "quota" });
        s.assets[m.hash] = "reserved";
        ctx.reply(Reserved, { hash: m.hash, answer: "reserved" });
        ctx.start("release");
      },
    },
    commit: {
      on: Commit,
      description: "Marks it ready; a reservation already released can't be committed.",
      sources: ["packages/axo-api-worker/src/assets/assets-do.ts#AxoAssetsDO.commit"],
      sends: [Committed],
      run(s, m, ctx) {
        const ok = s.assets[m.hash] === "reserved";
        if (ok) s.assets[m.hash] = "ready";
        ctx.reply(Committed, { hash: m.hash, ok });
      },
    },
    release: {
      description: "Releases reservations not committed in time.",
      sources: ["packages/axo-api-worker/src/assets/assets-do.ts#AxoAssetsDO.alarm"],
      after: "10 minutes",
      run(s) {
        if (!releaseAbandoned.on) return;
        for (const [h, a] of Object.entries(s.assets)) if (a === "reserved") delete s.assets[h as Hash];
      },
    },
    commitLost: lose(Commit, { spend: faults }),
  },
});

const quotaHeld = defineProperty("quotaHeld", {
  description: "The account never holds more than its quota, with uploads in parallel.",
  always: (w) => Object.values(w.the(AssetsDO).state.assets).filter((a) => a === "ready").length <= QUOTA,
  needs: [reserveFirst],
});
const reservationsEnd = defineProperty("reservationsEnd", {
  description: "Once nothing is in flight, no abandoned reservation holds quota.",
  always: (w) => !w.quiet || Object.values(w.the(AssetsDO).state.assets).every((a) => a !== "reserved"),
  needs: [releaseAbandoned],
});

const okMeansKept = defineProperty("okMeansKept", {
  description: "An upload answered ok is in the account: a late commit fails the upload instead of being dropped.",
  always: (w) => w.the(Devices).state.kept.every((h) => w.the(AssetsDO).state.assets[h] === "ready"),
});

const threeAtOnce = defineScenario("Three uploads at once", {
  description: "Three photos upload in parallel into an account with room for two: two are stored, one is refused.",
  run(s) {
    s.act(s.the(Devices), "upload", { hash: "h1" });
    s.act(s.the(Devices), "upload", { hash: "h2" });
    s.act(s.the(Devices), "upload", { hash: "h3" });
    s.settle();
  },
});

export default defineSpec({
  name: "Asset quota",
  description: "How an account's quota holds with parallel and abandoned uploads.",
  actors: [Devices, Worker, AssetsDO],
  properties: [quotaHeld, reservationsEnd, okMeansKept],
  scenarios: [threeAtOnce],
  finalState: { description: "Anything quiet.", when: () => true },
});
