import { atMost, defineActor, defineGroup, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone, input, nullable, oneOf } from "@leostera/feynman";

// RFD0030: assets, files named by the SHA-256 of their bytes, kept per account.
// - Uploads reserve in the account's AxoAssetsDO, store the bytes in R2 (which checks the
//   hash), then commit.
// - Reads go through the gateway, which authenticates, then Workers Cache, keyed with the account
//   from ctx.props, then AxoAssetCache, then the account's AxoAssetsDO and R2.
// - Deletes purge the cache by tag, and again later.
// - A prompt with attachments reaches Pi with all of them or not at all.
//
// Leo owns account A. Mallory, account B, knows the hash of Leo's h1 but not its bytes.
// Not built yet: no step has sources.

// Quota and abandoned uploads are in specs/asset-quota.ts; here an account's quota is never reached.

type Account = "A" | "B";
type Hash = "h1" | "h2" | "h3";
const HashKind = oneOf("h1", "h2", "h3");
const AccountKind = oneOf("A", "B");
const Status = oneOf("ok", "notFound");
const Reserve = oneOf("reserved", "exists", "quota", "busy");

/** The bytes whose SHA-256 is `hash`. */
const content = (hash: string) => `content-${hash}`;

// Uploading.
const Put = defineMessage("Put", { account: AccountKind, hash: HashKind, bytes: String }, { name: "PUT /assets/<hash>", over: "https" });
const PutDone = defineMessage("PutDone", { hash: HashKind, ok: Boolean, version: Number }, { name: "PUT result", over: "https", tone: "reply" });
const Reserve_ = defineMessage("Reserve", { upload: String, account: AccountKind, hash: HashKind }, { name: "reserve", over: "rpc" });
const Reserved = defineMessage("Reserved", { upload: String, answer: Reserve, version: Number }, { name: "reserve result", over: "rpc", tone: "reply" });
const Store = defineMessage("Store", { upload: String, key: String, bytes: String, hash: HashKind }, { name: "R2 put (sha256)", over: "r2" });
const Stored = defineMessage("Stored", { upload: String, ok: Boolean }, { name: "R2 put result", over: "r2", tone: "reply" });
const Commit = defineMessage("Commit", { upload: String, account: AccountKind, hash: HashKind, ok: Boolean }, { name: "commit / release", over: "rpc" });
const Committed = defineMessage("Committed", { upload: String, version: Number }, { name: "commit result", over: "rpc", tone: "reply" });

// Reading.
const Get = defineMessage("Get", { account: AccountKind, hash: HashKind, afterUpload: Boolean, deletes: Number }, { name: "GET /assets/<hash>", over: "https" });
const Got = defineMessage("Got", { hash: HashKind, status: Status, bytes: nullable(String), afterUpload: Boolean, deletes: Number }, { name: "GET result", over: "https", tone: "reply" });
const Lookup = defineMessage("Lookup", { read: String, account: AccountKind, hash: HashKind }, { name: "AxoAssetCache fetch (props.accountId)", over: "ctx.exports" });
const Served = defineMessage("Served", { read: String, status: Status, bytes: nullable(String) }, { name: "cached or fresh response", over: "ctx.exports", tone: "reply" });
const Fetch = defineMessage("Fetch", { read: String, account: AccountKind, hash: HashKind }, { name: "cache miss", over: "workers cache" });
const Fill = defineMessage("Fill", { read: String, status: Status, bytes: nullable(String) }, { name: "response to store", over: "workers cache" });
const Read = defineMessage("Read", { read: String, account: AccountKind, hash: HashKind }, { name: "read asset", over: "rpc" });
const ReadDone = defineMessage("ReadDone", { read: String, status: Status, bytes: nullable(String) }, { name: "asset bytes", over: "rpc", tone: "reply" });

// Deleting.
const Delete = defineMessage("Delete", { account: AccountKind, hash: HashKind, version: Number }, { name: "POST /assets/<hash>/delete", over: "https" });
const Unstore = defineMessage("Unstore", { account: AccountKind, hash: HashKind, key: String }, { name: "R2 delete", over: "r2" });
const Unstored = defineMessage("Unstored", { account: AccountKind, hash: HashKind }, { name: "R2 delete result", over: "r2", tone: "reply" });
const Purge = defineMessage("Purge", { account: AccountKind, hash: HashKind, late: Boolean, apply: Boolean }, { name: "purge tag asset-<account>-<hash>", over: "rpc" });

// Attachments.
const Prompt = defineMessage("Prompt", { attachments: String }, { name: "axo.remote.session.prompt + attachments", over: "relay" });
const Delivered = defineMessage("Delivered", { attachments: Number }, { name: "send (with attachments)", over: "pi bridge" });
const Refused = defineMessage("Refused", {}, { name: "the attachment could not be fetched", over: "relay" });

const devices = defineZone({ name: "Clients" });
const cloud = defineZone({ name: "Cloudflare", place: { column: 1, region: true } });
const mac = defineZone({ name: "Studio", place: { column: 2 } });

const propsInCacheKey = defineRule("propsInCacheKey", { description: "The gateway calls AxoAssetCache with the account in ctx.props, which is part of Workers Cache's key." });
const r2ChecksHash = defineRule("r2ChecksHash", { description: "R2 stores the bytes only if their SHA-256 is the asset's name (put with sha256)." });
const perAccountKeys = defineRule("perAccountKeys", { description: "R2 keys are accounts/<account>/<hash>: one account's delete never removes another's bytes." });
const noStoreMisses = defineRule("noStoreMisses", { description: "A 404 is answered with Cache-Control: no-store, so it is never cached." });
const deleteIfUnchanged = defineRule("deleteIfUnchanged", { description: "Every PUT that succeeds, \"exists\" too, raises the asset's version; a delete names the version it saw, and is refused if the asset was put again since." });
const deleteBeforeReuse = defineRule("deleteBeforeReuse", { description: "An asset stays deleting until R2 has deleted its object; uploading it again meanwhile answers busy." });
const purgeAgain = defineRule("purgeAgain", { description: "AxoAssetsDO purges a deleted asset's tag again, 15 minutes after the delete." });
const readsEndInTime = defineRule("readsEndInTime", { description: "Assumption: a read finishes, its response stored or dropped, within 15 minutes." });
const allOrNothing = defineRule("allOrNothing", { description: "axod passes a prompt to Pi only once every attachment is downloaded and matches its hash." });

type Asset = { state: "reserved" | "ready" | "deleting" | "deleted"; version: number };
type Who = "leo" | "mallory" | "axod";
type Upload = { account: Account; hash: Hash; bytes: string; from: Who };
type Pending = { from: Who; hash: Hash; account: Account; afterUpload: boolean; deletes: number };
const who = (ctx: any): Who => (ctx.from.id === ctx.the(Leo).id ? "leo" : ctx.from.id === ctx.the(Mallory).id ? "mallory" : "axod");
const to = (ctx: any, w: Who) => (w === "leo" ? ctx.the(Leo) : w === "mallory" ? ctx.the(Mallory) : ctx.the(Axod));

const key = (account: string, hash: string) => (perAccountKeys.on ? `accounts/${account}/${hash}` : hash);
const cacheKey = (account: string, hash: string) => (propsInCacheKey.on ? `${account}:${hash}` : hash);

export const Leo = defineActor({
  name: "Leo (account A)",
  description: "Leo's phone: uploads photos, reads them back, deletes one, and sends a prompt with two attachments.",
  zone: devices,
  singleton: true,
  initialState: () => ({ uploaded: [] as Hash[], uploading: [] as Hash[], versions: {} as Partial<Record<Hash, number>>, deletes: 0, got: [] as { hash: Hash; status: string; afterUpload: boolean }[], prompt: "none" as "none" | "sent" | "delivered" | "refused" }),
  display: {
    icon: "phone",
    status: (s) => `uploaded ${s.uploaded.join(", ") || "nothing"}; prompt ${s.prompt}`,
    rows: (s) => s.got.map((g) => ({ label: `GET ${g.hash}`, detail: g.status, mood: g.status === "ok" ? ("ok" as const) : ("off" as const) })),
  },
  actions: {
    upload: {
      with: [atMost(3)],
      label: "Upload",
      description: "Leo attaches a photo; the app uploads it.",
      inputs: { hash: input(HashKind, { examples: (w): Hash[] => (["h1", "h2"] as const).filter((h) => !w.the(Leo).state.uploading.includes(h)) }) },
      sends: [Put],
      run(s, { hash }, ctx) {
        s.uploading.push(hash);
        ctx.send(ctx.the(Gateway), Put, { account: "A", hash, bytes: content(hash) });
      },
    },
    get: {
      with: [atMost(2)],
      label: "Open",
      description: "Leo opens an attachment.",
      inputs: { hash: input(HashKind, { examples: ["h1", "h2"] as const }) },
      sends: [Get],
      // Ghost: whether its upload had finished when Leo opened it.
      run: (s, { hash }, ctx) => ctx.send(ctx.the(Gateway), Get, { account: "A", hash, afterUpload: s.uploaded.includes(hash), deletes: s.deletes }),
    },
    delete: {
      with: [atMost(1)],
      label: "Delete",
      description: "Leo deletes an asset from the web's file list.",
      // The file list offers Delete for finished uploads only.
      inputs: { hash: input(HashKind, { examples: (w): Hash[] => w.the(Leo).state.uploaded.filter((h) => !w.the(Leo).state.uploading.includes(h)) }) },
      when: (s) => s.uploaded.some((h) => !s.uploading.includes(h)),
      sends: [Delete],
      run(s, { hash }, ctx) {
        s.uploaded = s.uploaded.filter((h) => h !== hash);
        s.deletes += 1;
        ctx.send(ctx.the(Gateway), Delete, { account: "A", hash, version: s.versions[hash] ?? 0 });
      },
    },
    sendPrompt: {
      with: [atMost(1)],
      label: "Send with h1 and h2",
      description: "Leo sends a prompt with two attachments, once both uploads have finished.",
      when: (s) => s.uploaded.includes("h1") && s.uploaded.includes("h2"),
      sends: [Prompt],
      run(s, _i, ctx) {
        s.prompt = "sent";
        ctx.send(ctx.the(Axod), Prompt, { attachments: "h1,h2" });
      },
    },
  },
  transitions: {
    putDone: {
      on: PutDone,
      description: "The upload finished.",
      run(s, m) {
        s.uploading = s.uploading.filter((h) => h !== m.hash);
        if (m.ok && !s.uploaded.includes(m.hash)) s.uploaded.push(m.hash);
        if (m.ok) s.versions[m.hash] = m.version;
      },
    },
    got: {
      on: Got,
      description: "The file, or 404.",
      // A request made before a later delete may rightly answer 404.
      run: (s, m) => void s.got.push({ hash: m.hash, status: m.status, afterUpload: m.afterUpload && m.deletes === s.deletes }),
    },
    delivered: { on: Delivered, description: "Pi took the prompt.", run: (s) => void (s.prompt = "delivered") },
    refused: { on: Refused, description: "The prompt was refused.", run: (s) => void (s.prompt = "refused") },
  },
});

export const Mallory = defineActor({
  name: "Mallory (account B)",
  description: "Another account. She knows the hash of Leo's h1, not its bytes, and has her own copy of h2.",
  zone: devices,
  singleton: true,
  initialState: () => ({ got: [] as string[] }),
  display: { icon: "person", status: (s) => (s.got.length ? `got ${s.got.join(", ")}` : "nothing"), mood: (s) => (s.got.includes(content("h1")) ? "bad" : "ok") },
  actions: {
    forge: {
      with: [atMost(1)],
      label: "Upload h1 without its bytes",
      description: "Mallory uploads other bytes under the name h1, to claim it.",
      sends: [Put],
      run: (_s, _i, ctx) => ctx.send(ctx.the(Gateway), Put, { account: "B", hash: "h1", bytes: "forged" }),
    },
    uploadOwn: {
      with: [atMost(1)],
      label: "Upload her h2",
      description: "Mallory uploads her own copy of h2: the same bytes Leo has.",
      sends: [Put],
      run: (_s, _i, ctx) => ctx.send(ctx.the(Gateway), Put, { account: "B", hash: "h2", bytes: content("h2") }),
    },
    get: {
      with: [atMost(2)],
      label: "GET h1",
      description: "Mallory asks for h1 with her own sign-in.",
      sends: [Get],
      run: (_s, _i, ctx) => ctx.send(ctx.the(Gateway), Get, { account: "B", hash: "h1", afterUpload: false, deletes: 0 }),
    },
    delete: {
      with: [atMost(1)],
      label: "Delete her h2",
      description: "Mallory deletes her copy of h2.",
      sends: [Delete],
      run: (_s, _i, ctx) => ctx.send(ctx.the(Gateway), Delete, { account: "B", hash: "h2", version: ctx.the(AssetsDO).state.index.B.h2?.version ?? 0 }),
    },
  },
  transitions: {
    putDone: { on: PutDone, description: "Her upload finished, or was refused.", run: () => {} },
    got: { on: Got, description: "Whatever she got.", run: (s, m) => void (m.bytes && s.got.push(m.bytes)) },
  },
});

export const Gateway = defineActor({
  name: "Gateway (default entrypoint)",
  description: "Caching off: authenticates every request, runs uploads and deletes, and sends reads to AxoAssetCache with the account in ctx.props.",
  zone: cloud,
  singleton: true,
  initialState: () => ({ uploads: {} as Record<string, Upload>, reads: {} as Record<string, Pending> }),
  display: { icon: "shield", status: (s) => `${Object.keys(s.uploads).length} upload(s), ${Object.keys(s.reads).length} read(s)` },
  transitions: {
    put: {
      on: Put,
      description: "Reserves the upload in the account's AxoAssetsDO.",
      sources: ["packages/axo-api-worker/src/http/assets.ts#upload"],
      sends: [Reserve_],
      run(s, m, ctx) {
        const upload = ctx.fresh("upload");
        s.uploads[upload] = { account: m.account, hash: m.hash, bytes: m.bytes, from: who(ctx) };
        ctx.send(ctx.the(AssetsDO), Reserve_, { upload, account: m.account, hash: m.hash });
      },
    },
    reserved: {
      on: Reserved,
      description: "Already there, over quota, or reserved: then streams the bytes to R2.",
      sources: ["packages/axo-api-worker/src/http/assets.ts#upload"],
      sends: [Store, PutDone],
      run(s, m, ctx) {
        const u = s.uploads[m.upload];
        if (!u) return;
        if (m.answer !== "reserved") {
          delete s.uploads[m.upload];
          return ctx.send(to(ctx, u.from), PutDone, { hash: u.hash, ok: m.answer === "exists", version: m.version });
        }
        ctx.send(ctx.the(R2), Store, { upload: m.upload, key: key(u.account, u.hash), bytes: u.bytes, hash: u.hash });
      },
    },
    stored: {
      on: Stored,
      description: "Commits the asset, or releases the reservation if R2 refused the bytes.",
      sources: ["packages/axo-api-worker/src/http/assets.ts#upload"],
      sends: [Commit, PutDone],
      run(s, m, ctx) {
        const u = s.uploads[m.upload];
        if (!u) return;
        ctx.send(ctx.the(AssetsDO), Commit, { upload: m.upload, account: u.account, hash: u.hash, ok: m.ok });
        if (!m.ok) {
          delete s.uploads[m.upload];
          ctx.send(to(ctx, u.from), PutDone, { hash: u.hash, ok: false, version: 0 });
        }
      },
    },
    committed: {
      on: Committed,
      description: "Answers the upload with the asset's version.",
      sources: ["packages/axo-api-worker/src/http/assets.ts#upload"],
      sends: [PutDone],
      run(s, m, ctx) {
        const u = s.uploads[m.upload];
        if (!u) return;
        delete s.uploads[m.upload];
        ctx.send(to(ctx, u.from), PutDone, { hash: u.hash, ok: true, version: m.version });
      },
    },
    get: {
      on: Get,
      description: "Authenticates, then asks AxoAssetCache with props { accountId }.",
      sources: ["packages/axo-api-worker/src/http/assets.ts#read"],
      sends: [Lookup],
      run(s, m, ctx) {
        const read = ctx.fresh("read");
        s.reads[read] = { from: who(ctx), hash: m.hash, account: m.account, afterUpload: m.afterUpload, deletes: m.deletes };
        ctx.send(ctx.the(Cache), Lookup, { read, account: m.account, hash: m.hash });
      },
    },
    served: {
      on: Served,
      description: "Passes the response on, private to the caller.",
      sources: ["packages/axo-api-worker/src/http/assets.ts#read"],
      sends: [Got],
      run(s, m, ctx) {
        const r = s.reads[m.read];
        if (!r) return;
        delete s.reads[m.read];
        ctx.send(to(ctx, r.from), Got, { hash: r.hash, status: m.status, bytes: m.bytes, afterUpload: r.afterUpload, deletes: r.deletes });
      },
    },
    delete: { on: Delete, description: "A person's delete goes to the account's AxoAssetsDO.", sources: ["packages/axo-api-worker/src/http/assets.ts#serveAccountAssets"], sends: [Delete], run: (_s, m, ctx) => ctx.send(ctx.the(AssetsDO), Delete, m) },
  },
});

type Entry = { account: Account; hash: Hash; status: "ok" | "notFound"; bytes: string | null };

export const Cache = defineActor({
  name: "Workers Cache",
  description: "Tiered cache in front of AxoAssetCache: a hit answers without running it or the Durable Object.",
  zone: cloud,
  singleton: true,
  initialState: () => ({ entries: {} as Record<string, Entry>, filling: {} as Record<string, { key: string; account: Account; hash: Hash }>, settled: [] as string[] }),
  display: {
    icon: "storage",
    status: (s) => `${Object.keys(s.entries).length} entr(ies)`,
    rows: (s) => Object.entries(s.entries).map(([k, e]) => ({ label: k, detail: `${e.status} (stored for ${e.account})`, mood: e.status === "ok" ? ("info" as const) : ("warn" as const) })),
  },
  transitions: {
    lookup: {
      on: Lookup,
      description: "A hit answers at once; a miss runs AxoAssetCache.",
      sends: [Served, Fetch],
      run(s, m, ctx) {
        const k = cacheKey(m.account, m.hash);
        const hit = s.entries[k];
        if (hit) return ctx.reply(Served, { read: m.read, status: hit.status, bytes: hit.bytes });
        s.filling[m.read] = { key: k, account: m.account, hash: m.hash };
        ctx.send(ctx.the(AssetCache), Fetch, { read: m.read, account: m.account, hash: m.hash });
      },
    },
    fill: {
      on: Fill,
      description: "Stores the response, unless it says no-store, and answers the read.",
      sends: [Served],
      run(s, m, ctx) {
        const f = s.filling[m.read];
        if (!f) return;
        delete s.filling[m.read];
        if (m.status === "ok" || !noStoreMisses.on) s.entries[f.key] = { account: f.account, hash: f.hash, status: m.status, bytes: m.bytes };
        ctx.send(ctx.the(Gateway), Served, { read: m.read, status: m.status, bytes: m.bytes });
      },
    },
    purge: {
      on: Purge,
      description: "Drops every entry tagged asset-<account>-<hash>.",
      run(s, m) {
        if (m.apply) for (const [k, e] of Object.entries(s.entries)) if (e.account === m.account && e.hash === m.hash) delete s.entries[k];
        if (m.late) s.settled.push(`${m.account}:${m.hash}`);
      },
    },
  },
});

export const AssetCache = defineActor({
  name: "AxoAssetCache",
  description: "The cached entrypoint: asks the account's AxoAssetsDO and returns its answer with Cache-Control and Cache-Tag.",
  zone: cloud,
  singleton: true,
  initialState: () => ({}),
  display: { icon: "gear", status: () => "fronts AxoAssetsDO" },
  transitions: {
    fetch: { on: Fetch, description: "Asks the account's AxoAssetsDO.", sources: ["packages/axo-api-worker/src/assets/cache.ts#AxoAssetCache.fetch"], sends: [Read], run: (_s, m, ctx) => ctx.send(ctx.the(AssetsDO), Read, m) },
    readDone: { on: ReadDone, description: "Returns it to the cache, tagged.", sources: ["packages/axo-api-worker/src/assets/cache.ts#AxoAssetCache.fetch"], sends: [Fill], run: (_s, m, ctx) => ctx.send(ctx.the(Cache), Fill, m) },
  },
});

/** One AxoAssetsDO per account: their states are kept apart by account; nothing crosses them. */
export const AssetsDO = defineActor({
  name: "AxoAssetsDO (A and B)",
  description: "Each account's index of assets and its quota; reads the bytes from R2 and purges on delete.",
  zone: cloud,
  singleton: true,
  initialState: () => ({
    index: { A: {}, B: {} } as Record<Account, Partial<Record<Hash, Asset>>>,
    latePurges: [] as { account: Account; hash: Hash }[],
  }),
  display: {
    icon: "database",
    status: (s) => `A: ${Object.entries(s.index.A).map(([h, a]) => `${h} ${a!.state}`).join(", ") || "empty"}; B: ${Object.entries(s.index.B).map(([h, a]) => `${h} ${a!.state}`).join(", ") || "empty"}`,
  },
  transitions: {
    reserve: {
      on: Reserve_,
      description: "Already there: exists. Over quota: refused. Otherwise reserved.",
      sources: ["packages/axo-api-worker/src/assets/assets-do.ts#AxoAssetsDO.reserve"],
      sends: [Reserved],
      run(s, m, ctx) {
        const index = s.index[m.account];
        const asset = index[m.hash];
        if (asset?.state === "ready") {
          if (deleteIfUnchanged.on) asset.version += 1;
          return ctx.reply(Reserved, { upload: m.upload, answer: "exists", version: asset.version });
        }
        if (asset?.state === "reserved") return ctx.reply(Reserved, { upload: m.upload, answer: "reserved", version: 0 });
        if (asset?.state === "deleting" && deleteBeforeReuse.on) return ctx.reply(Reserved, { upload: m.upload, answer: "busy", version: 0 });
        index[m.hash] = { state: "reserved", version: (asset?.version ?? 0) + 1 };
        ctx.reply(Reserved, { upload: m.upload, answer: "reserved", version: 0 });
      },
    },
    commit: {
      on: Commit,
      description: "Marks it ready and answers with its version, or releases the reservation.",
      sources: ["packages/axo-api-worker/src/assets/assets-do.ts#AxoAssetsDO.commit"],
      sends: [Committed],
      run(s, m, ctx) {
        const asset = s.index[m.account][m.hash];
        if (asset?.state !== "reserved") return;
        if (!m.ok) return void delete s.index[m.account][m.hash];
        asset.state = "ready";
        ctx.reply(Committed, { upload: m.upload, version: asset.version });
      },
    },
    read: {
      on: Read,
      description: "Serves it only if it is ready in this account's index, from this account's key.",
      sources: ["packages/axo-api-worker/src/assets/assets-do.ts#AxoAssetsDO.head"],
      sends: [ReadDone],
      run(s, m, ctx) {
        const bytes = ctx.the(R2).state.objects[key(m.account, m.hash)];
        if (s.index[m.account][m.hash]?.state !== "ready" || bytes === undefined) return ctx.reply(ReadDone, { read: m.read, status: "notFound", bytes: null });
        ctx.reply(ReadDone, { read: m.read, status: "ok", bytes });
      },
    },
    delete: {
      on: Delete,
      description: "Marks it deleted, deletes the R2 object, purges its tag, and sets the second purge.",
      sources: ["packages/axo-api-worker/src/assets/assets-do.ts#AxoAssetsDO.remove"],
      sends: [Unstore, Purge],
      starts: ["latePurge"],
      run(s, m, ctx) {
        const asset = s.index[m.account][m.hash];
        if (asset?.state !== "ready") return;
        if (deleteIfUnchanged.on && asset.version !== m.version) return ctx.note("Refused: put again since the delete was asked for.");
        asset.state = deleteBeforeReuse.on ? "deleting" : "deleted";
        ctx.send(ctx.the(R2), Unstore, { account: m.account, hash: m.hash, key: key(m.account, m.hash) });
        ctx.send(ctx.the(Cache), Purge, { account: m.account, hash: m.hash, late: false, apply: true });
        s.latePurges.push({ account: m.account, hash: m.hash });
        ctx.start("latePurge");
      },
    },
    unstored: {
      on: Unstored,
      description: "R2 has deleted the object: the asset may be uploaded again.",
      sources: ["packages/axo-api-worker/src/assets/assets-do.ts#AxoAssetsDO.remove"],
      run(s, m) {
        const asset = s.index[m.account][m.hash];
        if (asset?.state === "deleting") asset.state = "deleted";
      },
    },
    latePurge: {
      description: "15 minutes after a delete: purges again, once reads that began before it are over.",
      sources: ["packages/axo-api-worker/src/assets/assets-do.ts#AxoAssetsDO.alarm"],
      after: "15 minutes",
      sends: [Purge],
      starts: ["latePurge"],
      run(s, _m, ctx) {
        const next = s.latePurges[0];
        if (!next) return;
        // The assumption: 15 minutes is longer than any read. Modelled as waiting for reads of
        // this asset still being stored.
        const reading = Object.values(ctx.the(Cache).state.filling).some((f) => f.account === next.account && f.hash === next.hash);
        if (readsEndInTime.on && reading) return ctx.start("latePurge");
        s.latePurges.shift();
        // Without purgeAgain nothing is purged; the message only marks the moment for the property.
        ctx.send(ctx.the(Cache), Purge, { ...next, late: true, apply: purgeAgain.on });
        if (s.latePurges.length) ctx.start("latePurge");
      },
    },
  },
});

export const R2 = defineActor({
  name: "R2 axo-assets",
  description: "The bytes. A put with sha256 stores only bytes that hash to it.",
  zone: cloud,
  singleton: true,
  initialState: () => ({ objects: {} as Record<string, string> }),
  display: { icon: "storage", status: (s) => `${Object.keys(s.objects).length} object(s)`, rows: (s) => Object.entries(s.objects).map(([k, v]) => ({ label: k, detail: v, mood: "info" as const })) },
  transitions: {
    store: {
      on: Store,
      description: "Stores the bytes, or refuses them if their hash is not the name.",
      sends: [Stored],
      run(s, m, ctx) {
        if (r2ChecksHash.on && m.bytes !== content(m.hash)) return ctx.reply(Stored, { upload: m.upload, ok: false });
        s.objects[m.key] = m.bytes;
        ctx.reply(Stored, { upload: m.upload, ok: true });
      },
    },
    unstore: {
      on: Unstore,
      description: "Deletes the object.",
      sends: [Unstored],
      run(s, m, ctx) {
        delete s.objects[m.key];
        ctx.reply(Unstored, { account: m.account, hash: m.hash });
      },
    },
  },
});

export const Axod = defineActor({
  name: "Studio axod",
  description: "Downloads a prompt's attachments with the Mac's credential, checks each hash, and passes the prompt to Pi.",
  zone: mac,
  singleton: true,
  initialState: () => ({ wanted: [] as Hash[], have: [] as Hash[], answered: 0, failed: false, done: false, delivered: [] as number[] }),
  display: { icon: "cpu", status: (s) => (s.delivered.length ? `Pi got ${s.delivered.join(", ")} attachment(s)` : s.wanted.length ? `fetching ${s.wanted.join(", ")}` : "idle") },
  transitions: {
    prompt: {
      on: Prompt,
      description: "Fetches each attachment.",
      sources: ["crates/axo-relay/src/assets.rs#fetch_all"],
      sends: [Get],
      run(s, m, ctx) {
        s.wanted = m.attachments.split(",") as Hash[];
        for (const hash of s.wanted) ctx.send(ctx.the(Gateway), Get, { account: "A", hash, afterUpload: false, deletes: 0 });
      },
    },
    got: {
      on: Got,
      description: "Keeps it if its bytes match; delivers once all are here, or refuses on the first failure.",
      sources: ["crates/axo-relay/src/assets.rs#fetch_all"],
      sends: [Delivered, Refused],
      run(s, m, ctx) {
        if (s.done) return;
        s.answered += 1;
        if (m.status === "ok" && m.bytes === content(m.hash)) s.have.push(m.hash);
        else s.failed = true;
        if (allOrNothing.on) {
          if (s.failed) {
            s.done = true;
            return ctx.send(ctx.the(Leo), Refused, {});
          }
          if (s.have.length < s.wanted.length) return;
        } else if (s.answered < s.wanted.length) return;
        s.done = true;
        s.delivered.push(s.have.length);
        ctx.send(ctx.the(Leo), Delivered, { attachments: s.have.length });
      },
    },
  },
});

const cloudGroup = defineGroup({ name: "Worker", actors: [Gateway, Cache, AssetCache, AssetsDO, R2], icon: "cloud", collapsed: false });

const noCrossAccountReads = defineProperty("noCrossAccountReads", {
  description: "Mallory never gets the bytes of Leo's h1: not from the cache, not from R2, not by uploading under its name.",
  always: (w) => !w.the(Mallory).state.got.includes(content("h1")),
  needs: [propsInCacheKey],
});
const bytesMatchNames = defineProperty("bytesMatchNames", {
  description: "Every stored object's bytes hash to the name it is stored under.",
  always: (w) => Object.entries(w.the(R2).state.objects).every(([k, v]) => v === content(k.split("/").at(-1)!)),
  needs: [r2ChecksHash],
});
const readyMeansStored = defineProperty("readyMeansStored", {
  description: "An asset ready in an account's index has its bytes in R2: another account's delete never takes them.",
  always: (w) => {
    const { index } = w.the(AssetsDO).state;
    const objects = w.the(R2).state.objects;
    const writing = (account: string, hash: string) => Object.values(w.the(Gateway).state.uploads).some((u) => u.account === account && u.hash === hash);
    return (["A", "B"] as const).every((a) => Object.entries(index[a]).every(([h, x]) => x!.state !== "ready" || h in objects || `accounts/${a}/${h}` in objects || writing(a, h)));
  },
  needs: [perAccountKeys, deleteBeforeReuse],
});
const uploadsAreVisible = defineProperty("uploadsAreVisible", {
  description: "Opening an asset after its upload finished, with no delete since, never answers 404.",
  always: (w) => w.the(Leo).state.got.every((g) => g.status === "ok" || !g.afterUpload),
  needs: [noStoreMisses, deleteIfUnchanged],
});
const deletedStaysDeleted = defineProperty("deletedStaysDeleted", {
  description: "Once a delete has settled (its second purge has run), the cache holds nothing for that asset while it stays deleted.",
  always: (w) => {
    const { index } = w.the(AssetsDO).state;
    const { settled } = w.the(Cache).state;
    return settled.every((s) => {
      const [account, hash] = s.split(":") as [Account, Hash];
      const state = index[account][hash]?.state;
      if (state !== "deleted" && state !== "deleting") return true;
      return !Object.values(w.the(Cache).state.entries).some((e) => e.account === account && e.hash === hash && e.status === "ok");
    });
  },
  needs: [purgeAgain, readsEndInTime],
});
const allAttachmentsOrNone = defineProperty("allAttachmentsOrNone", {
  description: "A prompt reaches Pi with every attachment it named, or not at all.",
  always: (w) => w.the(Axod).state.delivered.every((n) => n === w.the(Axod).state.wanted.length),
  needs: [allOrNothing],
});

const photoAndPdf = defineScenario("Send a prompt with two attachments", {
  description: "Leo uploads h1 and h2 and sends a prompt with both; the Mac fetches them and Pi gets both.",
  run(s) {
    s.act(s.the(Leo), "upload", { hash: "h1" });
    s.act(s.the(Leo), "upload", { hash: "h2" });
    s.settle({ until: (w) => w.the(Leo).state.uploaded.length === 2 });
    s.act(s.the(Leo), "sendPrompt");
    s.settle({ until: (w) => w.the(Leo).state.prompt !== "sent" });
  },
});
const cachedRead = defineScenario("A second read comes from the cache", {
  description: "Leo opens h1 twice; the second answer comes from Workers Cache without the Durable Object.",
  run(s) {
    s.act(s.the(Leo), "upload", { hash: "h1" });
    s.settle({ until: (w) => w.the(Leo).state.uploaded.length === 1 });
    s.act(s.the(Leo), "get", { hash: "h1" });
    s.settle({ until: (w) => w.the(Leo).state.got.length === 1 });
    s.act(s.the(Leo), "get", { hash: "h1" });
    s.settle({ until: (w) => w.the(Leo).state.got.length === 2 });
  },
});
const mallorysTries = defineScenario("Mallory tries for Leo's h1", {
  description: "Leo's h1 is cached; Mallory asks for it by hash and uploads other bytes under its name. She gets nothing.",
  run(s) {
    s.act(s.the(Leo), "upload", { hash: "h1" });
    s.settle({ until: (w) => w.the(Leo).state.uploaded.length === 1 });
    s.act(s.the(Leo), "get", { hash: "h1" });
    s.settle({ until: (w) => w.the(Leo).state.got.length === 1 });
    s.act(s.the(Mallory), "get");
    s.act(s.the(Mallory), "forge");
    s.settle({ until: (w) => Object.keys(w.the(Gateway).state.uploads).length === 0 && Object.keys(w.the(Gateway).state.reads).length === 0 });
    s.act(s.the(Mallory), "get");
    s.settle({ until: (w) => Object.keys(w.the(Gateway).state.reads).length === 0 });
  },
});
const deleteWhileReading = defineScenario("Delete while a read is in flight", {
  description: "Leo opens h1 and deletes it while the read is on its way back; the second purge clears what the read stored.",
  run(s) {
    s.act(s.the(Leo), "upload", { hash: "h1" });
    s.settle({ until: (w) => w.the(Leo).state.uploaded.length === 1 });
    s.act(s.the(Leo), "get", { hash: "h1" });
    // The read gets the bytes from the Durable Object; its response is on its way to the cache.
    s.deliver(s.the(Gateway), Get);
    s.deliver(s.the(Cache), Lookup);
    s.deliver(s.the(AssetCache), Fetch);
    s.deliver(s.the(AssetsDO), Read);
    s.deliver(s.the(AssetCache), ReadDone);
    // Now Leo deletes it, and the first purge lands before the read's response is stored.
    s.act(s.the(Leo), "delete", { hash: "h1" });
    s.deliver(s.the(Gateway), Delete);
    s.deliver(s.the(AssetsDO), Delete);
    s.deliver(s.the(Cache), Purge);
    s.deliver(s.the(Cache), Fill);
    s.settle();
  },
});

const openBeforeUpload = defineScenario("Open before the upload finished", {
  description: "Leo's other device opens h1 before it is uploaded (404, never cached), then uploads it and opens it again.",
  run(s) {
    s.act(s.the(Leo), "get", { hash: "h1" });
    s.settle({ until: (w) => w.the(Leo).state.got.length === 1 });
    s.act(s.the(Leo), "upload", { hash: "h1" });
    s.settle({ until: (w) => w.the(Leo).state.uploaded.length === 1 });
    s.act(s.the(Leo), "get", { hash: "h1" });
    s.settle({ until: (w) => w.the(Leo).state.got.length === 2 });
  },
});
const slowRead = defineScenario("A read outlasts the delete", {
  description: "A read of h1 got its bytes before the delete and is still on its way to the cache when the delete and its first purge land.",
  run(s) {
    s.act(s.the(Leo), "upload", { hash: "h1" });
    s.settle({ until: (w) => w.the(Leo).state.uploaded.length === 1 });
    s.act(s.the(Leo), "get", { hash: "h1" });
    s.deliver(s.the(Gateway), Get);
    s.deliver(s.the(Cache), Lookup);
    s.deliver(s.the(AssetCache), Fetch);
    s.deliver(s.the(AssetsDO), Read);
    s.deliver(s.the(AssetCache), ReadDone);
    s.act(s.the(Leo), "delete", { hash: "h1" });
    s.deliver(s.the(Gateway), Delete);
    s.deliver(s.the(AssetsDO), Delete);
    s.deliver(s.the(Cache), Purge);
  },
});
const deleteDuringPrompt = defineScenario("An attachment is deleted while the Mac fetches it", {
  description: "Leo sends a prompt with h1 and h2, then deletes h2 from another device before the Mac has it: the prompt is refused, not delivered with h1 alone.",
  run(s) {
    s.act(s.the(Leo), "upload", { hash: "h1" });
    s.act(s.the(Leo), "upload", { hash: "h2" });
    s.settle({ until: (w) => w.the(Leo).state.uploaded.length === 2 });
    s.act(s.the(Leo), "sendPrompt");
    s.deliver(s.the(Axod), Prompt);
    s.act(s.the(Leo), "delete", { hash: "h2" });
    s.deliver(s.the(Gateway), Delete);
    s.deliver(s.the(AssetsDO), Delete);
    s.settle();
  },
});

export default defineSpec({
  name: "Assets",
  description: "How assets are uploaded, read through Workers Cache, deleted, and attached to prompts, one AxoAssetsDO per account.",
  actors: [Leo, Mallory, Gateway, Cache, AssetCache, AssetsDO, R2, Axod],
  groups: [cloudGroup],
  properties: [noCrossAccountReads, bytesMatchNames, readyMeansStored, uploadsAreVisible, deletedStaysDeleted, allAttachmentsOrNone],
  scenarios: [photoAndPdf, cachedRead, mallorysTries, deleteWhileReading, openBeforeUpload, slowRead, deleteDuringPrompt],
  finalState: { description: "Anything quiet.", when: () => true },
});
