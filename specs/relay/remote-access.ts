import { atMost, budget, crash, defineActor, defineGroup, defineLimit, defineMessage, defineProperty, defineScenario, defineSpec, defineZone, input, listOf, lose, oneOf } from "@leostera/feynman";

const SEC = 1_000;
const MIN = 60 * SEC;
const HOUR = 60 * MIN;

// What the spec leaves out: per-IP and global rate limits (AxoPairingRateLimit), code-collision
// retries, signing out, and everything a terminal does once a command reaches the Mac. The old
// explainer's "Unlink button" and "Wi-Fi off" are proposals / a UI shortcut, not code: message loss
// and restarts (the checker's faults) stand in for the network going away.
//
//

type Entry = { account: string };
type Pairing = { account: string; consumed: null | { host: string; verifier: string } };
type HostRow = { account: string; label: string; credentialId: string; verifier: string; revoked: boolean };
type Route = { conn: string; ready: boolean };
type Status = "online" | "offline" | "revoked";
type Pending = { person: string; key: string; conn: string };
type Manager = { viewers: Record<string, string[]>; pairings: Record<string, Pairing>; routes: Record<string, Route>; pending: Record<string, Pending> };

const who = (account: string) => account.replace(/^acct-/, "");
/** "Studio app" and "Studio daemon" are the two halves of one Mac. */
const macName = (label: string) => label.replace(/ (app|daemon)$/, "");

const keyOf = (account: string, host: string) => `${account}/${host}`;

/** Faults on one path: lost messages and crashes (RFD0012). `--set faults=2` raises it. */
const faults = budget("faults", 1);

// Person <-> Cloudflare Access
const SignIn = defineMessage("SignIn", { person: String, account: String }, { name: "sign in with Cloudflare Access", over: "https" });
const SignedIn = defineMessage("SignedIn", {}, { name: "signed in (CF_Authorization)", over: "https", tone: "reply" });
const NotSignedIn = defineMessage("NotSignedIn", { request: String }, { name: "401 sign in first", over: "https", tone: "refused" });
// Person -> Access -> Worker (HTTPS/WebSocket; Access adds the signed JWT)
const CreatePairing = defineMessage("CreatePairing", { account: String, person: String }, { name: "POST /api/v1/account/host-pairings", over: "https" });
const RunCommand = defineMessage("RunCommand", { account: String, host: String, request: String, person: String }, { name: "terminal input", over: "websocket" });
const ListHosts = defineMessage("ListHosts", { account: String, person: String }, { name: "GET /api/v1/account/hosts", over: "https" });
const OpenHost = defineMessage("OpenHost", { account: String, host: String, person: String }, { name: "open …/hosts/:host/client", over: "websocket" });
const LeaveHost = defineMessage("LeaveHost", { account: String, host: String, person: String }, { name: "close …/hosts/:host/client", over: "websocket" });
const RevokeHost = defineMessage("RevokeHost", { account: String, host: String, person: String }, { name: "POST …/hosts/:host/revoke", over: "https" });
// Worker -> pairing index / account manager
const ReserveCode = defineMessage("ReserveCode", { verifier: String, account: String, code: String, person: String }, { name: "reserve code", over: "rpc" });
const IssuePairing = defineMessage("IssuePairing", { verifier: String, account: String, code: String, person: String }, { name: "createPairing", over: "rpc" });
const LookupCode = defineMessage("LookupCode", { verifier: String, host: String, label: String, credentialId: String, secretVerifier: String }, { name: "lookup code", over: "rpc" });
const RedeemPairing = defineMessage("RedeemPairing", { account: String, verifier: String, host: String, label: String, credentialId: String, secretVerifier: String }, { name: "redeemPairing", over: "rpc" });
const UpgradeDaemon = defineMessage("UpgradeDaemon", { account: String, host: String, credentialId: String, secret: String, conn: String }, { name: "daemon WebSocket upgrade", over: "rpc" });
const ForwardCall = defineMessage("ForwardCall", { account: String, host: String, request: String, person: String }, { name: "client WebSocket call", over: "rpc" });
const RevokeInAccount = defineMessage("RevokeInAccount", { account: String, host: String, person: String }, { name: "revokeHost", over: "rpc" });
// index / manager -> Worker
const CodeReserved = defineMessage("CodeReserved", { code: String, person: String }, { name: "code reserved", over: "rpc", tone: "reply" });
const CodeUnknown = defineMessage("CodeUnknown", { credentialId: String }, { name: "code unknown or forgotten", over: "rpc", tone: "refused" });
const CodeFound = defineMessage("CodeFound", { account: String, verifier: String, host: String, label: String, credentialId: String, secretVerifier: String }, { name: "code found", over: "rpc", tone: "reply" });
const PairingIssued = defineMessage("PairingIssued", { verifier: String, account: String, code: String, person: String }, { name: "pairing created", over: "rpc", tone: "reply" });
const PairingLimited = defineMessage("PairingLimited", { person: String }, { name: "three codes already waiting", over: "rpc", tone: "refused" });
const PairingRedeemed = defineMessage("PairingRedeemed", { account: String, credentialId: String }, { name: "pairing redeemed", over: "rpc", tone: "reply" });
const PairingInvalid = defineMessage("PairingInvalid", { credentialId: String }, { name: "pairing invalid", over: "rpc", tone: "refused" });
// Worker -> person
const Code = defineMessage("Code", { code: String }, { name: "pairing code", over: "https", tone: "reply" });
const TooManyCodes = defineMessage("TooManyCodes", {}, { name: "429 too many codes", over: "https", tone: "refused" });
const Revoked = defineMessage("Revoked", {}, { name: "204 revoked", over: "https", tone: "reply" });
// axod -> Worker (no Access: the code, then the host credential, is the proof)
const RedeemCode = defineMessage("RedeemCode", { code: String, host: String, label: String, credentialId: String, secret: String }, { name: "POST /api/v1/host-pairings/redeem", over: "https" });
const Connect = defineMessage("Connect", { account: String, host: String, credentialId: String, secret: String, conn: String }, { name: "GET …/hosts/:host/daemon", over: "websocket" });
// Worker -> axod
const Linked = defineMessage("Linked", { account: String, credentialId: String }, { name: "200 linked", over: "https", tone: "reply" });
const CodeRejected = defineMessage("CodeRejected", { credentialId: String }, { name: "400 code invalid or expired", over: "https", tone: "refused" });
// account manager <-> axod over the daemon WebSocket
const Admitted = defineMessage("Admitted", { conn: String }, { name: "101 upgraded", over: "websocket", tone: "reply" });
const ConnectRefused = defineMessage("ConnectRefused", { conn: String }, { name: "403 host is not authorized", over: "websocket", tone: "refused" });
const RegisterHost = defineMessage("RegisterHost", { account: String, host: String, conn: String }, { name: "axo.host.register", over: "websocket" });
const HostRegistered = defineMessage("HostRegistered", { conn: String }, { name: "register result", over: "websocket", tone: "reply" });
const Disconnect = defineMessage("Disconnect", { account: String, host: String, conn: String }, { name: "socket closed by the Mac", over: "websocket" });
const SocketClosed = defineMessage("SocketClosed", { conn: String }, { name: "socket closed by the relay", over: "websocket", tone: "refused" });
const Forward = defineMessage("Forward", { request: String, account: String }, { name: "axo.remote.terminal.input", over: "websocket", tone: "stream" });
const CallDone = defineMessage("CallDone", { request: String, account: String, host: String, conn: String }, { name: "call result", over: "websocket", tone: "reply" });
// manager -> person
const HostList = defineMessage("HostList", { hosts: listOf({ host: String, status: oneOf("online", "offline", "revoked") }) }, { name: "host list", over: "https", tone: "reply" });
const Opened = defineMessage("Opened", { host: String, status: oneOf("online", "offline", "revoked") }, { name: "attached to host", over: "websocket", tone: "reply" });
const NoSuchHost = defineMessage("NoSuchHost", { host: String }, { name: "404 no such host in your account", over: "websocket", tone: "refused" });
const HostRevokedMsg = defineMessage("HostRevokedMsg", { host: String }, { name: "403 host revoked", over: "websocket", tone: "refused" });
const HostStatus = defineMessage("HostStatus", { host: String, status: oneOf("online", "offline", "revoked") }, { name: "host presence", over: "websocket", tone: "stream" });
const Detached = defineMessage("Detached", { host: String, reason: oneOf("closed", "revoked") }, { name: "detached from host", over: "websocket", tone: "refused" });
const Output = defineMessage("Output", { request: String }, { name: "terminal output", over: "websocket", tone: "stream" });
const NotYourMac = defineMessage("NotYourMac", { request: String }, { name: "no such host on this account", over: "websocket", tone: "refused" });
const MacOffline = defineMessage("MacOffline", { request: String }, { name: "-32005 host offline", over: "websocket", tone: "refused" });
const OutcomeUnknown = defineMessage("OutcomeUnknown", { request: String }, { name: "-32004 outcome unknown", over: "websocket", tone: "refused" });
// app <-> axod (unix socket)
const LinkHost = defineMessage("LinkHost", { code: String }, { name: "axo.relay.link", over: "unix socket" });
const HostLinked = defineMessage("HostLinked", {}, { name: "host linked", over: "unix socket", tone: "reply" });
const LinkFailed = defineMessage("LinkFailed", {}, { name: "could not link this Mac", over: "unix socket", tone: "refused" });


const devices = defineZone({ name: "People's devices", description: "browsers and phones signed in with Access" });
const cloudflare = defineZone({ name: "Cloudflare", description: "Access, the Worker and its Durable Objects", place: { column: 1, region: true } });
const macs = defineZone({ name: "Macs", description: "each runs Axo.app and axod" });

const statusOf = (state: Manager & { hosts: Record<string, HostRow> }, key: string): Status =>
  state.hosts[key]?.revoked ? "revoked" : state.routes[key]?.ready ? "online" : "offline";
/** Tells everyone watching a host what its presence now is. */
const announce = (state: Manager & { hosts: Record<string, HostRow> }, ctx: any, key: string) => {
  for (const id of state.viewers[key] ?? []) {
    const person = ctx.all(Person).find((x: { id: string }) => x.id === id);
    if (person) ctx.send(person, HostStatus, { host: key.split("/")[1]!, status: statusOf(state, key) });
  }
};

const CODE_LIFETIME = defineLimit({ name: "Pairing code lifetime", value: 10 * MIN, sources: ["packages/axo-api-worker/src/auth/pairing.ts#PAIRING_LIFETIME_MS"] });
const INDEX_GRACE = defineLimit({ name: "The pairing index keeps a code this long after it expires", value: 24 * HOUR, sources: ["packages/axo-api-worker/src/auth/pairing.ts#createHostPairing"] });
const PENDING_CODES = defineLimit({ name: "Unused codes an account may hold", value: 3, unit: "codes", sources: ["packages/axo-api-worker/src/auth/account-manager.ts#AxoAccountManager.createPairing"] });
const HTTP_TIMEOUT = defineLimit({ name: "axod waits this long for the pairing service", value: 10 * SEC, sources: ["crates/axo-relay/src/pairing.rs#HTTP_TIMEOUT"] });
const CONNECT_TIMEOUT = defineLimit({ name: "axod waits this long to bring the relay connection up", value: 5 * SEC, sources: ["crates/axo-relay/src/relay/socket.rs#CONNECT_TIMEOUT"] });
const LEASE = defineLimit({ name: "The host's spot is kept for", value: 30 * SEC, sources: ["packages/axo-api/src/contracts.ts#LIMITS"] });
const DEADLINE = defineLimit({ name: "The relay waits this long for a host to register or answer", value: 10 * SEC, sources: ["packages/axo-api/src/contracts.ts#LIMITS"] });
const MAX_RETRY = defineLimit({ name: "Longest wait between reconnect attempts", value: 30 * SEC, sources: ["crates/axo-relay/src/relay.rs#MAX_RECONNECT_DELAY"] });
const APP_RPC_TIMEOUT = defineLimit({ name: "Axo.app waits this long for axod to answer axo.relay.link", value: 5 * SEC, sources: ["apple/AxoClient/Sources/AxoClient/Axod/AxodMethods.swift#AxodMethod.init"] });
const REQUEST_TIMEOUT = defineLimit({ name: "The web app waits this long for an answer", value: 10 * SEC, sources: ["packages/axo-app/src/index.ts#DEFAULT_TIMEOUT_MS"] });

// ---- Cloudflare Access: signs people in and puts a signed JWT on what they send ----

export const Access = defineActor({
  name: "Sign-in",
  description: "Signs people in with Cloudflare OAuth (RFD0013) and only lets requests with Axo's session for their account through to the Worker.",
  zone: cloudflare,
  singleton: true,
  initialState: () => ({ sessions: {} as Record<string, string> }), // person -> account (the JWT subject)
  display: { icon: "shield", status: (s) => `${Object.keys(s.sessions).length} signed in` },
  place: { edge: "left" },
  transitions: {
    signIn: {
      on: SignIn,
      description: "Signs the person in; from now on their requests carry a session for their account.",
      sources: ["packages/axo-api-worker/src/auth/login.ts#completeLogin"],
      sends: [SignedIn],
      say: (_s, m) => `Signed ${who(m.account)} in`,
      run(state, m, ctx) { state.sessions[m.person] = m.account; ctx.reply(SignedIn, {}); },
    },
    createPairing: {
      on: CreatePairing,
      description: "Lets a signed-in request through, or stops it before the Worker sees it.",
      sources: ["packages/axo-api-worker/src/auth/account-access.ts#requireAccount"],
      sends: [CreatePairing, NotSignedIn],
      run(state, m, ctx) { return state.sessions[m.person] === m.account ? ctx.send(ctx.the(Worker), CreatePairing, m) : ctx.reply(NotSignedIn, { request: "" }); },
    },
    listHosts: {
      on: ListHosts,
      description: "Lets a signed-in request through, or stops it before the Worker sees it.",
      sources: ["packages/axo-api-worker/src/auth/account-access.ts#requireAccount"],
      sends: [ListHosts, NotSignedIn],
      run(state, m, ctx) { return state.sessions[m.person] === m.account ? ctx.send(ctx.the(Worker), ListHosts, m) : ctx.reply(NotSignedIn, { request: "" }); },
    },
    openHost: {
      on: OpenHost,
      description: "Lets a signed-in request through, or stops it before the Worker sees it.",
      sources: ["packages/axo-api-worker/src/auth/account-access.ts#requireAccount"],
      sends: [OpenHost, NotSignedIn],
      run(state, m, ctx) { return state.sessions[m.person] === m.account ? ctx.send(ctx.the(Worker), OpenHost, m) : ctx.reply(NotSignedIn, { request: "" }); },
    },
    leaveHost: {
      on: LeaveHost,
      description: "Lets a signed-in request through, or stops it before the Worker sees it.",
      sources: ["packages/axo-api-worker/src/auth/account-access.ts#requireAccount"],
      sends: [LeaveHost, NotSignedIn],
      run(state, m, ctx) { return state.sessions[m.person] === m.account ? ctx.send(ctx.the(Worker), LeaveHost, m) : ctx.reply(NotSignedIn, { request: "" }); },
    },
    runCommand: {
      on: RunCommand,
      description: "Lets a signed-in request through, or stops it before the Worker sees it.",
      sources: ["packages/axo-api-worker/src/auth/account-access.ts#requireAccount"],
      sends: [RunCommand, NotSignedIn],
      run(state, m, ctx) { return state.sessions[m.person] === m.account ? ctx.send(ctx.the(Worker), RunCommand, m) : ctx.reply(NotSignedIn, { request: m.request }); },
    },
    revokeHost: {
      on: RevokeHost,
      description: "Lets a signed-in request through, or stops it before the Worker sees it.",
      sources: ["packages/axo-api-worker/src/auth/account-access.ts#requireAccount"],
      sends: [RevokeHost, NotSignedIn],
      run(state, m, ctx) { return state.sessions[m.person] === m.account ? ctx.send(ctx.the(Worker), RevokeHost, m) : ctx.reply(NotSignedIn, { request: "" }); },
    },
    // Faults: what the network and restarts may do here.
    signInLost: lose(SignIn, { spend: faults }),
    createPairingLost: lose(CreatePairing, { spend: faults }),
    listHostsLost: lose(ListHosts, { spend: faults }),
    openHostLost: lose(OpenHost, { spend: faults }),
    leaveHostLost: lose(LeaveHost, { spend: faults }),
    runCommandLost: lose(RunCommand, { spend: faults }),
    revokeHostLost: lose(RevokeHost, { spend: faults }),
  },
});

// ---- The Worker: stateless; hashes with SESSION_SECRET and routes between Durable Objects ----

export const Worker = defineActor({
  name: "Worker",
  description: "The Cloudflare Worker in front of everything. It keeps no state; it checks, hashes and routes.",
  zone: cloudflare,
  singleton: true,
  initialState: () => ({}),
  display: { icon: "server", status: () => "stateless" },
  transitions: {
    createPairing: {
      on: CreatePairing,
      description: "Makes a code and asks the account to hold it.",
      sources: ["packages/axo-api-worker/src/auth/pairing.ts#createHostPairing", "packages/axo-api-worker/src/auth/pairing.ts#generatePairingCode"],
      sends: [IssuePairing],
      run(_s, msg, ctx) {
        const code = ctx.fresh("code");
        ctx.send(ctx.the(Manager), IssuePairing, { verifier: ctx.hash(code), account: msg.account, code, person: msg.person });
      },
    },
    pairingIssued: {
      on: PairingIssued,
      description: "Records the code in the pairing index so a host can find its account from the code alone.",
      sources: ["packages/axo-api-worker/src/auth/pairing.ts#createHostPairing"],
      sends: [ReserveCode],
      run: (_s, m, ctx) => ctx.send(ctx.the(Index), ReserveCode, m),
    },
    pairingLimited: {
      on: PairingLimited,
      description: "Tells the person the account already holds three codes.",
      sources: ["packages/axo-api-worker/src/auth/pairing.ts#rateLimited"],
      sends: [TooManyCodes],
      run(_s, m, ctx) { const p = ctx.all(Person).find((x) => x.id === m.person); if (p) ctx.send(p, TooManyCodes, {}); },
    },
    codeReserved: {
      on: CodeReserved,
      description: "Shows the person their code.",
      sources: ["packages/axo-api-worker/src/auth/pairing.ts#createHostPairing"],
      sends: [Code],
      run(_s, m, ctx) { const p = ctx.all(Person).find((x) => x.id === m.person); if (p) ctx.send(p, Code, { code: m.code }); },
    },
    redeemCode: {
      on: RedeemCode,
      description: "Looks the code up in the pairing index to learn which account issued it.",
      sources: ["packages/axo-api-worker/src/auth/pairing.ts#redeemHostPairing"],
      sends: [LookupCode],
      run(_s, m, ctx) {
        ctx.send(ctx.the(Index), LookupCode, { verifier: ctx.hash(m.code), host: m.host, label: m.label, credentialId: m.credentialId, secretVerifier: ctx.hash(m.secret) });
      },
    },
    codeFound: {
      on: CodeFound,
      description: "Asks that account to redeem the code for this host.",
      sources: ["packages/axo-api-worker/src/auth/pairing.ts#redeemHostPairing"],
      sends: [RedeemPairing],
      run: (_s, m, ctx) => ctx.send(ctx.the(Manager), RedeemPairing, m),
    },
    codeUnknown: {
      on: CodeUnknown,
      description: "Answers the host that the code is invalid.",
      sources: ["packages/axo-api-worker/src/auth/pairing.ts#invalidPairing"],
      sends: [CodeRejected],
      run: (_s, m, ctx) => ctx.send(ctx.all(Axod).find((a) => a.state.pending === m.credentialId) ?? ctx.all(Axod)[0]!, CodeRejected, m),
    },
    pairingRedeemed: {
      on: PairingRedeemed,
      description: "Answers the host that it is linked.",
      sources: ["packages/axo-api-worker/src/auth/pairing.ts#redeemHostPairing"],
      sends: [Linked],
      run: (_s, m, ctx) => ctx.send(ctx.all(Axod).find((a) => a.state.pending === m.credentialId) ?? ctx.all(Axod)[0]!, Linked, m),
    },
    pairingInvalid: {
      on: PairingInvalid,
      description: "Answers the host that the code is invalid.",
      sources: ["packages/axo-api-worker/src/auth/pairing.ts#invalidPairing"],
      sends: [CodeRejected],
      run: (_s, m, ctx) => ctx.send(ctx.all(Axod).find((a) => a.state.pending === m.credentialId) ?? ctx.all(Axod)[0]!, CodeRejected, m),
    },
    listHosts: {
      on: ListHosts,
      description: "Asks the account's Durable Object for its hosts.",
      sources: ["packages/axo-api-worker/src/http/account-hosts.ts#serveAccountHosts"],
      sends: [ListHosts],
      run: (_s, m, ctx) => ctx.send(ctx.the(Manager), ListHosts, m),
    },
    openHost: {
      on: OpenHost,
      description: "Hands a person's WebSocket to their client's Durable Object, which follows the account's hosts (RFD0018).",
      sources: ["packages/axo-api-worker/src/http/account-hosts.ts#upgradeAccountClient"],
      sends: [OpenHost],
      run: (_s, m, ctx) => ctx.send(ctx.the(Manager), OpenHost, m),
    },
    leaveHost: {
      on: LeaveHost,
      description: "Tells the account's Durable Object the person's socket closed.",
      sources: ["packages/axo-api-worker/src/client-do.ts#AxoClientDO.webSocketClose"],
      sends: [LeaveHost],
      run: (_s, m, ctx) => ctx.send(ctx.the(Manager), LeaveHost, m),
    },
    connect: {
      on: Connect,
      description: "Hands a host's WebSocket upgrade to its account's Durable Object.",
      sources: ["packages/axo-api-worker/src/http/account-hosts.ts#upgradeHostDaemon"],
      sends: [UpgradeDaemon],
      run: (_s, m, ctx) => ctx.send(ctx.the(Manager), UpgradeDaemon, m),
    },
    runCommand: {
      on: RunCommand,
      description: "Hands a signed-in person's command, from their client's Durable Object, to the host's.",
      sources: ["packages/axo-api-worker/src/client-do.ts#AxoClientDO.webSocketMessage", "packages/axo-api-worker/src/host-do.ts#AxoHostDO.command"],
      sends: [ForwardCall],
      run: (_s, m, ctx) => ctx.send(ctx.the(Manager), ForwardCall, m),
    },
    revokeHost: {
      on: RevokeHost,
      description: "Asks the account's Durable Object to revoke the host.",
      sources: ["packages/axo-api-worker/src/http/account-hosts.ts#revokeAccountHost"],
      sends: [RevokeInAccount],
      run: (_s, m, ctx) => ctx.send(ctx.the(Manager), RevokeInAccount, m),
    },
    // Faults: what the network and restarts may do here.
    createPairingLost: lose(CreatePairing, { spend: faults }),
    pairingIssuedLost: lose(PairingIssued, { spend: faults }),
    pairingLimitedLost: lose(PairingLimited, { spend: faults }),
    codeReservedLost: lose(CodeReserved, { spend: faults }),
    redeemCodeLost: lose(RedeemCode, { spend: faults }),
    codeFoundLost: lose(CodeFound, { spend: faults }),
    codeUnknownLost: lose(CodeUnknown, { spend: faults }),
    pairingRedeemedLost: lose(PairingRedeemed, { spend: faults }),
    pairingInvalidLost: lose(PairingInvalid, { spend: faults }),
    listHostsLost: lose(ListHosts, { spend: faults }),
    openHostLost: lose(OpenHost, { spend: faults }),
    leaveHostLost: lose(LeaveHost, { spend: faults }),
    connectLost: lose(Connect, { spend: faults }),
    runCommandLost: lose(RunCommand, { spend: faults }),
    revokeHostLost: lose(RevokeHost, { spend: faults }),
  },
});

// ---- AxoPairingIndex: code hash -> account (sharded by hash's first character; one shard here) ----

export const Index = defineActor({
  name: "AxoPairingIndex",
  description: "A Durable Object mapping a code's hash to the account that issued it, so redemption needs no sign-in.",
  zone: cloudflare,
  singleton: true,
  initialState: () => ({ entries: {} as Record<string, Entry> }),
  display: { icon: "database", status: (s) => `${Object.keys(s.entries).length} code(s) indexed` },
  transitions: {
    reserveCode: {
      on: ReserveCode,
      description: "Remembers which account a code belongs to, for ten minutes plus a day.",
      sources: ["packages/axo-api-worker/src/auth/pairing-directory.ts#AxoPairingIndex.reserve"],
      sends: [CodeReserved],
      run(state, m, ctx) {
        state.entries[m.verifier] = { account: m.account };
        ctx.reply(CodeReserved, { code: m.code, person: m.person });
      },
    },
    lookupCode: {
      on: LookupCode,
      description: "Finds the account for a code, or forgets the code if its day of grace is over.",
      sources: ["packages/axo-api-worker/src/auth/pairing-directory.ts#AxoPairingIndex.lookup"],
      sends: [CodeFound, CodeUnknown],
      run(state, m, ctx) {
        const entry = state.entries[m.verifier];
        if (!entry) return ctx.reply(CodeUnknown, { credentialId: m.credentialId });
        ctx.reply(CodeFound, { account: entry.account, verifier: m.verifier, host: m.host, label: m.label, credentialId: m.credentialId, secretVerifier: m.secretVerifier });
      },
    },
    // Faults: what the network and restarts may do here.
    reserveCodeLost: lose(ReserveCode, { spend: faults }),
    lookupCodeLost: lose(LookupCode, { spend: faults }),
  },
});

// ---- AxoAccountManager: the account's Durable Object (pairings, hosts) that is also its relay ----

export const Manager = defineActor({
  name: "AxoAccountManager",
  description: "The account's Durable Object: its pairing codes, its linked hosts, and the relay that connects people to them.",
  zone: cloudflare,
  singleton: true,
  initialState: () => ({
    pairings: {} as Record<string, Pairing>,
    hosts: {} as Record<string, HostRow>,
    routes: {} as Record<string, Route>,
    pending: {} as Record<string, Pending>,
    viewers: {} as Record<string, string[]>, // open client sockets, per host
  }),
  display: {
    icon: "cloud",
    status: (s) => `${Object.keys(s.routes).length} host(s) online`,
    rows: (s) =>
      Object.entries(s.hosts).map(([key, h]) => ({
        group: `${who(h.account)}'s account`,
        owner: who(h.account),
        label: h.label,
        detail: h.revoked ? "revoked" : s.routes[key]?.ready ? "online" : "offline",
        mood: h.revoked ? "bad" : s.routes[key]?.ready ? "ok" : "off",
      })),
  },
  transitions: {
    issuePairing: {
      on: IssuePairing,
      description: "Stores the code's hash, unless the account already holds three unused ones.",
      sources: ["packages/axo-api-worker/src/auth/account-manager.ts#AxoAccountManager.createPairing"],
      sends: [PairingIssued, PairingLimited],
      say: (_s, m) => `Made a code for ${who(m.account)}, valid 10 minutes; only its hash is kept`,
      run(state, m, ctx) {
        const unused = Object.values(state.pairings).filter((p) => p.account === m.account && p.consumed === null).length;
        if (unused >= PENDING_CODES.value) return ctx.reply(PairingLimited, { person: m.person });
        state.pairings[m.verifier] = { account: m.account, consumed: null };
        ctx.reply(PairingIssued, m);
      },
    },
    redeemPairing: {
      on: RedeemPairing,
      description: "Links the host if the code is unused and fresh; the same host and credential asking again gets the same answer.",
      sources: ["packages/axo-api-worker/src/auth/account-manager.ts#AxoAccountManager.redeemPairing"],
      sends: [PairingRedeemed, PairingInvalid, SocketClosed, OutcomeUnknown, HostStatus],
      run(state, m, ctx) {
        const pairing = state.pairings[m.verifier];
        if (!pairing) return ctx.reply(PairingInvalid, { credentialId: m.credentialId });
        const key = keyOf(pairing.account, m.host);
        const host = state.hosts[key];
        if (pairing.consumed) {
          const same = pairing.consumed.host === m.host && pairing.consumed.verifier === m.secretVerifier;
          if (!same || !host || host.verifier !== m.secretVerifier || host.credentialId !== m.credentialId || host.revoked)
            return ctx.reply(PairingInvalid, { credentialId: m.credentialId });
          return ctx.reply(PairingRedeemed, { account: pairing.account, credentialId: m.credentialId }, "Same host, same credential: answered again.");
        }
        const rotated = !!host && (host.verifier !== m.secretVerifier || host.credentialId !== m.credentialId || host.revoked);
        state.hosts[key] = { account: pairing.account, label: m.label, credentialId: m.credentialId, verifier: m.secretVerifier, revoked: false };
        pairing.consumed = { host: m.host, verifier: m.secretVerifier };
        const route = state.routes[key];
        if (rotated && route) {
          delete state.routes[key];
          for (const [request, p] of Object.entries(state.pending)) {
            if (p.key !== key) continue;
            delete state.pending[request];
            const person = ctx.all(Person).find((x) => x.id === p.person);
            if (person) ctx.send(person, OutcomeUnknown, { request });
        }
          const axod = ctx.all(Axod).find((a) => a.id === m.host);
          if (axod) ctx.send(axod, SocketClosed, { conn: route.conn });
          announce(state, ctx, key);
        }
        ctx.reply(PairingRedeemed, { account: pairing.account, credentialId: m.credentialId });
      },
    },
    revokeInAccount: {
      on: RevokeInAccount,
      description: "Marks the host revoked, drops its socket and fails what was waiting on it.",
      sources: ["packages/axo-api-worker/src/auth/account-manager.ts#AxoAccountManager.revokeHost", "packages/axo-api-worker/src/host-do.ts#AxoHostDO.disconnect"],
      sends: [Revoked, SocketClosed, OutcomeUnknown, Detached],
      say: (s, m) => `${who(m.account)} revokes ${s.hosts[keyOf(m.account, m.host)]?.label ?? "a Mac"}`,
      run(state, m, ctx) {
        const key = keyOf(m.account, m.host);
        const host = state.hosts[key];
        if (host) host.revoked = true;
        for (const id of state.viewers[key] ?? []) {
          const viewer = ctx.all(Person).find((x) => x.id === id);
          if (viewer) ctx.send(viewer, Detached, { host: m.host, reason: "revoked" });
        }
        delete state.viewers[key];
        const route = state.routes[key];
        if (route) {
          delete state.routes[key];
          for (const [request, p] of Object.entries(state.pending)) {
            if (p.key !== key) continue;
            delete state.pending[request];
            const person = ctx.all(Person).find((x) => x.id === p.person);
            if (person) ctx.send(person, OutcomeUnknown, { request });
        }
          const axod = ctx.all(Axod).find((a) => a.id === m.host);
          if (axod) ctx.send(axod, SocketClosed, { conn: route.conn });
        }
        const person = ctx.all(Person).find((x) => x.id === m.person);
        if (person) ctx.send(person, Revoked, {});
      },
    },
    upgradeDaemon: {
      on: UpgradeDaemon,
      description: "Accepts a host's socket only with the credential it was linked with, replacing the prior route in this model's no-lease abstraction.",
      sources: ["packages/axo-api-worker/src/auth/account-manager.ts#AxoAccountManager.authorizeHost", "packages/axo-api-worker/src/axo-host-relay.ts#AxoHostRelay.fetch"],
      sends: [Admitted, ConnectRefused],
      run(state, m, ctx) {
        const key = keyOf(m.account, m.host);
        const host = state.hosts[key];
        const axod = ctx.all(Axod).find((a) => a.id === m.host);
        if (!host || host.revoked || host.credentialId !== m.credentialId || host.verifier !== ctx.hash(m.secret))
          return axod && ctx.send(axod, ConnectRefused, { conn: m.conn }); // the Worker hands the socket over, so this reaches the host directly
        state.routes[key] = { conn: m.conn, ready: false };
        if (axod) ctx.send(axod, Admitted, { conn: m.conn });
      },
    },
    registerHost: {
      on: RegisterHost,
      description: "Marks the host online. Its spot is held while its socket stays open (axod's routine heartbeats are left out of this model).",
      sources: ["packages/axo-api-worker/src/axo-host-relay.ts#AxoHostRelay.registerHost"],
      sends: [HostRegistered, HostStatus],
      say: (s, m) => `${s.hosts[keyOf(m.account, m.host)]?.label ?? "A Mac"} is online`,
      run(state, m, ctx) {
        const route = state.routes[keyOf(m.account, m.host)];
        if (!route || route.conn !== m.conn) return; // "Stale lease"
        route.ready = true;
        announce(state, ctx, keyOf(m.account, m.host));
        ctx.reply(HostRegistered, { conn: m.conn });
      },
    },
    disconnect: {
      on: Disconnect,
      description: "The host closed its socket; the relay forgets it and fails what was waiting.",
      sources: ["packages/axo-api-worker/src/axo-host-relay.ts#AxoHostRelay.drop", "packages/axo-api-worker/src/axo-host-relay.ts#AxoHostRelay.fence"],
      sends: [OutcomeUnknown, HostStatus],
      run(state, m, ctx) {
        const key = keyOf(m.account, m.host);
        const route = state.routes[key];
        if (!route || route.conn !== m.conn) return;
        delete state.routes[key];
        announce(state, ctx, key);
        for (const [request, p] of Object.entries(state.pending)) {
          if (p.key !== key || p.conn !== m.conn) continue;
          delete state.pending[request];
          const person = ctx.all(Person).find((x) => x.id === p.person);
          if (person) ctx.send(person, OutcomeUnknown, { request });
        }
      },
    },
    listHosts: {
      on: ListHosts,
      description: "Lists the account's hosts and whether each is online. It never mentions other accounts' hosts.",
      sources: ["packages/axo-api-worker/src/auth/account-manager.ts#AxoAccountManager.listHosts"],
      sends: [HostList],
      run(state, m, ctx) {
        const person = ctx.all(Person).find((x) => x.id === m.person);
        const hosts = Object.entries(state.hosts)
          .filter(([, h]) => h.account === m.account)
          .map(([key]) => ({ host: key.split("/")[1]!, status: statusOf(state, key) }));
        if (person) ctx.send(person, HostList, { hosts });
      },
    },
    openHost: {
      on: OpenHost,
      description: "Attaches the person's socket to a host of their account; anything else is a 404 that reveals nothing.",
      sources: ["packages/axo-api-worker/src/axo-host-relay.ts#AxoHostRelay.fetch", "packages/axo-api-worker/src/auth/account-manager.ts#AxoAccountManager.authorizeHost"],
      sends: [Opened, NoSuchHost, HostRevokedMsg],
      say: (s, m) => `${who(m.account)} opens ${s.hosts[keyOf(m.account, m.host)]?.label ?? "a Mac"}`,
      run(state, m, ctx) {
        const person = ctx.all(Person).find((x) => x.id === m.person);
        if (!person) return;
        const key = keyOf(m.account, m.host);
        const host = state.hosts[key];
        if (!host) return ctx.send(person, NoSuchHost, { host: m.host });
        if (host.revoked) return ctx.send(person, HostRevokedMsg, { host: m.host });
        state.viewers[key] = [...new Set([...(state.viewers[key] ?? []), m.person])];
        ctx.send(person, Opened, { host: m.host, status: statusOf(state, key) });
      },
    },
    leaveHost: {
      on: LeaveHost,
      description: "Detaches the person's socket from the host.",
      sources: ["packages/axo-api-worker/src/axo-host-relay.ts#AxoHostRelay.webSocketClose"],
      sends: [Detached],
      run(state, m, ctx) {
        const key = keyOf(m.account, m.host);
        state.viewers[key] = (state.viewers[key] ?? []).filter((id) => id !== m.person);
        const person = ctx.all(Person).find((x) => x.id === m.person);
        if (person) ctx.send(person, Detached, { host: m.host, reason: "closed" });
      },
    },
    forwardCall: {
      on: ForwardCall,
      description: "Passes a command to the host, if the account owns it and it is online.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.command"],
      sends: [Forward, NotYourMac, MacOffline],
      say: (s, m) => `${who(m.account)} types into ${s.hosts[keyOf(m.account, m.host)]?.label ?? "a Mac"}`,
      run(state, m, ctx) {
        const person = ctx.all(Person).find((x) => x.id === m.person);
        if (!person) return;
        const key = keyOf(m.account, m.host);
        const host = state.hosts[key];
        if (!host || host.revoked) return ctx.send(person, NotYourMac, { request: m.request });
        const route = state.routes[key];
        const axod = ctx.all(Axod).find((a) => a.id === m.host);
        if (!route || !route.ready || !axod) return ctx.send(person, MacOffline, { request: m.request });
        state.pending[m.request] = { person: m.person, key, conn: route.conn };
        ctx.send(axod, Forward, { request: m.request, account: m.account });
      },
    },
    callDone: {
      on: CallDone,
      description: "Hands the host's answer to the person who asked.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.receiveReply"],
      sends: [Output],
      run(state, m, ctx) {
        const pending = state.pending[m.request];
        const route = pending ? state.routes[pending.key] : undefined;
        if (!pending || !route || route.conn !== m.conn) return;
        delete state.pending[m.request];
        for (const id of new Set([pending.person, ...(state.viewers[pending.key] ?? [])])) {
          const viewer = ctx.all(Person).find((x) => x.id === id);
          if (viewer) ctx.send(viewer, Output, { request: m.request });
        }
      },
    },
    // Faults: what the network and restarts may do here.
    issuePairingLost: lose(IssuePairing, { spend: faults }),
    redeemPairingLost: lose(RedeemPairing, { spend: faults }),
    revokeInAccountLost: lose(RevokeInAccount, { spend: faults }),
    upgradeDaemonLost: lose(UpgradeDaemon, { spend: faults }),
    registerHostLost: lose(RegisterHost, { spend: faults }),
    disconnectLost: lose(Disconnect, { spend: faults }),
    listHostsLost: lose(ListHosts, { spend: faults }),
    openHostLost: lose(OpenHost, { spend: faults }),
    leaveHostLost: lose(LeaveHost, { spend: faults }),
    forwardCallLost: lose(ForwardCall, { spend: faults }),
    callDoneLost: lose(CallDone, { spend: faults }),
  },
});

// ---- A person signed in with Cloudflare Access ----

export const Person = defineActor({
  name: "Person",
  description: "Someone on a browser or phone. Their account is whatever Cloudflare Access signs them in as.",
  zone: devices,
  initialState: (ctx) => ({
    account: `acct-${ctx.label}`,
    signedIn: false as boolean,
    codes: [] as string[],
    commands: {} as Record<string, string>, // what was typed, per request
    seenHosts: [] as string[],
    watching: {} as Record<string, string>,
    asked: [] as string[],
    answered: [] as string[],
    outputs: [] as string[],
    timedOut: [] as string[],
  }),
  display: {
    icon: "phone",
    status: (s) => (!s.signedIn ? "signed out" : Object.keys(s.watching).length ? `watching ${Object.keys(s.watching).length}` : s.codes.length ? `code ${s.codes.at(-1)}` : "signed in"),
    mood: (s) => (s.asked.length > s.answered.length ? "busy" : s.signedIn ? "ok" : "off"),
    names: ["Alice", "Bob", "Carol"],
    tokens: (s) => s.codes.slice(-1).map((code) => ({ kind: "pairing code", value: code, label: "pairing code" })),
  },
  actions: {
    signIn: {
      with: [atMost(2)],
      label: "Sign in with Cloudflare",
      description: "Signs in through Cloudflare Access.",
      when: (s) => !s.signedIn,
      sources: ["packages/axo-web-app/src/cloudflare-sign-in-app.tsx#CloudflareSignInApp"],
      sends: [SignIn],
      run: (s, _i, ctx) => ctx.send(ctx.the(Access), SignIn, { person: ctx.id, account: s.account }),
    },
    pair: {
      with: [atMost(2)],
      label: "Pair a host",
      description: "Asks for a one-time code to type into a Mac.",

      sends: [CreatePairing],
      run: (s, _i, ctx) => ctx.send(ctx.the(Access), CreatePairing, { account: s.account, person: ctx.id }),
    },
    refresh: {
      with: [atMost(2)],
      label: "Refresh hosts",
      description: "Asks which Macs the account has and whether they are online.",
      when: (s) => s.signedIn,
      sources: ["packages/axo-app/src/index.ts#RemoteAxoApi"],
      sends: [ListHosts],
      run: (s, _i, ctx) => ctx.send(ctx.the(Access), ListHosts, { account: s.account, person: ctx.id }),
    },
    open: {
      with: [atMost(2)],
      label: "Open a Mac",
      description: "Attaches to a Mac's terminal.",
      inputs: { host: input(String, { examples: (w): string[] => w.all(Axod).map((a) => a.id) }) },
      when: (s) => s.signedIn,
      sources: ["packages/axo-app/src/index.ts#AccountConnection.open"],
      sends: [OpenHost],
      run: (s, { host }, ctx) => ctx.send(ctx.the(Access), OpenHost, { account: s.account, host, person: ctx.id }),
    },
    leave: {
      with: [atMost(2)],
      label: "Close the terminal",
      description: "Stops watching a Mac.",
      inputs: { host: input(String, { examples: (w): string[] => w.all(Axod).map((a) => a.id) }) },
      when: (s) => Object.keys(s.watching).length > 0,
      sources: ["packages/axo-app/src/index.ts#AccountConnection.close"],
      sends: [LeaveHost],
      run: (s, { host }, ctx) => ctx.send(ctx.the(Access), LeaveHost, { account: s.account, host, person: ctx.id }),
    },
    run: {
      with: [atMost(2)],
      label: "Run a command on a Mac",
      description: "Types into a Mac's terminal through the relay.",
      inputs: {
        host: input(String, { examples: (w): string[] => w.all(Axod).map((a) => a.id) }),
        command: input(String, { examples: ["whoami"] }),
      },
      when: (s) => s.codes.length > 0, // the app lists hosts only for accounts that paired one
      sources: ["packages/axo-app/src/index.ts#AccountConnection.command"],
      sends: [RunCommand],
      run(s, { host, command }, ctx) {
        const request = ctx.fresh("req");
        s.asked.push(request);
        s.commands[request] = command;
        ctx.send(ctx.the(Access), RunCommand, { account: s.account, host, request, person: ctx.id });
      },
    },
    revoke: {
      with: [atMost(2)],
      label: "Revoke a Mac",
      description: "Cuts a Mac off from the account.",
      inputs: { host: input(String, { examples: (w): string[] => w.all(Axod).map((a) => a.id) }) },
      when: (s) => s.codes.length > 0,

      sends: [RevokeHost],
      run: (s, { host }, ctx) => ctx.send(ctx.the(Access), RevokeHost, { account: s.account, host, person: ctx.id }),
    },
  },
  transitions: {
    signedIn: { on: SignedIn, description: "The page shows the signed-in account.", sources: ["packages/axo-web-app/src/cloudflare-sign-in-app.tsx#CloudflareSignInApp"], run: (s) => void (s.signedIn = true) },
    notSignedIn: {
      on: NotSignedIn,
      description: "Access sends the person to sign in; nothing reached the relay.",
      sources: ["packages/axo-app/src/index.ts#AxoApiError"],
      run(s, m) { if (m.request && !s.answered.includes(m.request)) s.answered.push(m.request); },
    },
    code: { on: Code, description: "The code appears on screen.", run(s, m) { s.codes.push(m.code); } },
    tooManyCodes: { on: TooManyCodes, description: "The page says the account holds too many codes.", run() {} },
    revoked: { on: Revoked, description: "The Mac disappears from the list.", run() {} },
    hostList: {
      on: HostList,
      description: "The list shows each Mac with its status.",

      run(s, m) { for (const h of m.hosts) if (!s.seenHosts.includes(h.host)) s.seenHosts.push(h.host); },
    },
    opened: {
      on: Opened,
      description: "The terminal attaches and shows whether the Mac is online.",

      run(s, m) { s.watching[m.host] = m.status; if (!s.seenHosts.includes(m.host)) s.seenHosts.push(m.host); },
    },
    noSuchHost: { on: NoSuchHost, description: "The page says there is no such Mac; it learns nothing about other accounts.", run() {} },
    hostRevokedMsg: { on: HostRevokedMsg, description: "The page says the Mac was revoked.", run() {} },
    hostStatus: { on: HostStatus, description: "The terminal shows the Mac coming online or going offline.", run(s, m) { if (m.host in s.watching) s.watching[m.host] = m.status; } },
    detached: { on: Detached, description: "The terminal closes.", run(s, m) { delete s.watching[m.host]; } },
    output: {
      on: Output,
      description: "The Mac's answer appears in the terminal.",

      run(s, m) { if (s.asked.includes(m.request)) { s.answered.push(m.request); s.outputs.push(m.request); } },
    },
    notYourMac: { on: NotYourMac, description: "The terminal says this account has no such Mac.", run: (s, m) => void s.answered.push(m.request) },
    macOffline: { on: MacOffline, description: "The terminal says the Mac is offline.", run: (s, m) => void s.answered.push(m.request) },
    outcomeUnknown: { on: OutcomeUnknown, description: "The terminal says the command may or may not have run.", run: (s, m) => void s.answered.push(m.request) },
    requestTimeout: {
      description: "No answer after ten seconds; the app gives up on the command.",
      sources: ["packages/axo-app/src/index.ts#Channel.request"],
      run(s) { for (const r of s.asked) if (!s.answered.includes(r)) { s.answered.push(r); s.timedOut.push(r); } },
    },
    // Faults: what the network and restarts may do here.
    signedInLost: lose(SignedIn, { spend: faults }),
    notSignedInLost: lose(NotSignedIn, { spend: faults }),
    codeLost: lose(Code, { spend: faults }),
    tooManyCodesLost: lose(TooManyCodes, { spend: faults }),
    revokedLost: lose(Revoked, { spend: faults }),
    hostListLost: lose(HostList, { spend: faults }),
    openedLost: lose(Opened, { spend: faults }),
    noSuchHostLost: lose(NoSuchHost, { spend: faults }),
    hostRevokedMsgLost: lose(HostRevokedMsg, { spend: faults }),
    hostStatusLost: lose(HostStatus, { spend: faults }),
    detachedLost: lose(Detached, { spend: faults }),
    outputLost: lose(Output, { spend: faults }),
    notYourMacLost: lose(NotYourMac, { spend: faults }),
    macOfflineLost: lose(MacOffline, { spend: faults }),
    outcomeUnknownLost: lose(OutcomeUnknown, { spend: faults }),
    crash: crash({ spend: faults }),
  },
});

// ---- Axo.app: Settings → Remote Access ----

export const App = defineActor({
  name: "Axo.app",
  description: "The Mac app. Its Settings pane passes a pasted code to axod.",
  zone: macs,
  initialState: () => ({ linking: false as boolean, result: "" as "" | "linked" | "failed", lateSuccess: false as boolean }),
  display: { icon: "laptop", status: (s) => (s.linking ? "linking…" : s.result || "Settings"), mood: (s) => (s.result === "failed" ? "bad" : s.result === "linked" ? "ok" : "off") },
  actions: {
    link: {
      with: [atMost(2)],
      label: "Link this Mac",
      description: "Pastes a pairing code into Settings → Remote Access.",
      inputs: { code: input(String, { examples: (w): string[] => w.all(Person).flatMap((p) => p.state.codes), accepts: "pairing code" }) },
      when: (s) => !s.linking,
      sources: ["apple/AxoMac/Sources/AxoMac/Settings/RemoteAccessModel.swift#RemoteAccessModel.link"],
      sends: [LinkHost],
      run(s, { code }, ctx) {
        s.linking = true;
        s.result = "";
        const axod = ctx.all(Axod).find((a) => macName(a.label) === macName(ctx.label)) ?? ctx.all(Axod)[0];
        if (axod) ctx.send(axod, LinkHost, { code });
      },
    },
  },
  transitions: {
    hostLinked: { on: HostLinked, description: "Settings says the Mac is linked.", sources: ["apple/AxoMac/Sources/AxoMac/Settings/RemoteAccessSettingsView.swift#RemoteAccessSettingsView.linkHost"], run(s, _m, ctx) {
      // A reply for a call the app already gave up on is dropped.
      if (!s.linking) { s.lateSuccess = true; return; }
      s.linking = false; s.result = "linked";
    } },
    linkFailed: { on: LinkFailed, description: "Settings says it could not link.", sources: ["apple/AxoMac/Sources/AxoMac/Settings/RemoteAccessSettingsView.swift#RemoteAccessSettingsView.linkHost"], run(s, _m, ctx) { if (!s.linking) return; s.linking = false; s.result = "failed"; } },
    linkTimeout: {
      description: "axod has not answered in five seconds; Settings says it could not link.",
      sources: ["apple/AxoClient/Sources/AxoClient/RPC/JSONRPCConnection.swift#JSONRPCConnection.call"],
      run(s) { if (!s.linking) return; s.linking = false; s.result = "failed"; },
    },
    // Faults: what the network and restarts may do here.
    hostLinkedLost: lose(HostLinked, { spend: faults }),
    linkFailedLost: lose(LinkFailed, { spend: faults }),
    crash: crash({ spend: faults }),
  },
});

// ---- axod: link_host (RPC thread) and the relay worker thread ----

export const Axod = defineActor({
  name: "axod",
  description: "The host daemon. Its database holds host_link; its Keychain holds the secret.",
  zone: macs,
  initialState: (ctx) => ({
    label: ctx.label,
    link: { account: null as string | null, credentialId: null as string | null }, // host_link.account / .credential
    pending: null as string | null, // host_link.pending: the credential reserved for an unfinished redemption
    keychain: {} as Record<string, string>,
    code: null as string | null,
    redeeming: false as boolean,
    attempts: 0,
    conn: "idle" as "idle" | "connecting" | "registering" | "connected",
    connId: null as string | null,
    backingOff: false as boolean,
    delay: 1 * SEC,
    ran: [] as { for: string; linkedTo: string | null }[],
  }),
  display: {
    icon: "terminal",
    status: (s) => (s.conn === "connected" ? "online" : s.link.account ? (s.conn === "idle" ? "offline" : "connecting") : s.redeeming ? "linking" : "not linked"),
    mood: (s) => (s.conn === "connected" ? "ok" : s.link.account ? "warn" : "off"),
    owner: (s) => (s.link.account ? who(s.link.account) : null),
  },
  links: (s) => (s.conn === "connected" ? [{ to: "AxoAccountManager", kind: "websocket", style: "solid", row: s.label }] : s.conn !== "idle" ? [{ to: "AxoAccountManager", kind: "websocket", style: "dotted", row: s.label }] : []),
  transitions: {
    linkHost: {
      on: LinkHost,
      description: "Reserves a credential in the Keychain and database, then sends the code to the Worker.",
      sources: ["crates/axo-server/src/lib.rs#add_relay_methods", "crates/axo-relay/src/link.rs#link_host", "crates/axo-relay/src/pairing.rs#validate_code", "crates/axo-relay/src/pairing.rs#prepare_credential"],
      sends: [RedeemCode, LinkFailed],
      run(state, m, ctx) {
        // A malformed code is refused before anything is reserved or sent.
        if (!/^code-\d+$/.test(m.code) || state.redeeming) return ctx.reply(LinkFailed, {});
        if (state.pending === null) {
          state.pending = ctx.fresh("cred");
          state.keychain[state.pending] = ctx.fresh("secret");
        }
        state.code = m.code;
        state.redeeming = true;
        state.attempts = 1;
        ctx.send(ctx.the(Worker), RedeemCode, { code: m.code, host: ctx.id, label: state.label, credentialId: state.pending, secret: state.keychain[state.pending]! });
      },
    },
    linked: {
      on: Linked,
      description: "Saves the link, deletes the old credential, and asks the relay thread to reconnect.",
      sources: ["crates/axo-relay/src/link.rs#link_host", "crates/axo-server/src/lib.rs#add_relay_methods", "crates/axo-relay/src/relay/status.rs#RelayControl::request_connect"],
      sends: [HostLinked, Disconnect],
      say: (_s, m) => `Linked to ${who(m.account)}`,
      run(state, m, ctx) {
        // The answer must echo this attempt's credential, or it answers a call that gave up.
        if (!state.redeeming || state.pending === null || m.credentialId !== state.pending) return;
        const previous = state.link;
        if (previous.credentialId) delete state.keychain[previous.credentialId];
        state.link = { account: m.account, credentialId: state.pending };
        state.pending = null;
        state.redeeming = false;
        if (state.conn !== "idle" && previous.account && state.connId)
          ctx.send(ctx.the(Manager), Disconnect, { account: previous.account, host: ctx.id, conn: state.connId });
        state.conn = "idle";
        state.connId = null;
        state.backingOff = false;
        state.delay = 1 * SEC;
        const app = ctx.all(App).find((a) => macName(a.label) === macName(ctx.label)) ?? ctx.all(App)[0];
        if (app) ctx.send(app, HostLinked, {});
      },
    },
    codeRejected: {
      on: CodeRejected,
      description: "The pairing service said no; axod keeps the reserved credential for the next try.",
      sources: ["crates/axo-relay/src/pairing.rs#redeem", "crates/axo-server/src/lib.rs#add_relay_methods"],
      sends: [LinkFailed],
      run(state, m, ctx) {
        if (!state.redeeming || m.credentialId !== state.pending) return;
        state.redeeming = false;
        const app = ctx.all(App).find((a) => macName(a.label) === macName(ctx.label)) ?? ctx.all(App)[0];
        if (app) ctx.send(app, LinkFailed, {});
      },
    },
    redeemTimeout: {
      description: "No answer in ten seconds; axod sends the same request once more, then gives up but keeps its reserved credential.",
      sources: ["crates/axo-relay/src/pairing.rs#redeem", "crates/axo-relay/src/pairing.rs#post_json", "crates/axo-relay/src/pairing.rs#HTTP_TIMEOUT"],
      sends: [RedeemCode, LinkFailed],
      run(state, _, ctx) {
        if (!state.redeeming || state.pending === null) return;
        const app = ctx.all(App).find((a) => macName(a.label) === macName(ctx.label)) ?? ctx.all(App)[0];
        if (state.attempts < 2 && state.code) {
          state.attempts += 1;
          ctx.send(ctx.the(Worker), RedeemCode, { code: state.code, host: ctx.id, label: state.label, credentialId: state.pending, secret: state.keychain[state.pending] ?? "" });
          return;
        }
        state.redeeming = false;
        if (app) ctx.send(app, LinkFailed, {});
      },
    },
    dial: {
      description: "A linked axod opens its WebSocket to the relay with its credential.",
      when: (s) => s.link.account !== null && s.link.credentialId !== null && s.conn === "idle" && !s.backingOff,
      sources: ["crates/axo-relay/src/relay.rs#run_reconnect_loop", "crates/axo-relay/src/relay.rs#run_connection", "crates/axo-relay/src/relay/socket.rs#relay_websocket_request"],
      sends: [Connect],
      run(state, _, ctx) {
        state.conn = "connecting";
        state.connId = ctx.fresh("conn");
        ctx.send(ctx.the(Worker), Connect, { account: state.link.account!, host: ctx.id, credentialId: state.link.credentialId!, secret: state.keychain[state.link.credentialId!] ?? "", conn: state.connId });
      },
    },
    admitted: {
      on: Admitted,
      description: "The socket is up; axod registers the host.",
      sources: ["crates/axo-relay/src/relay.rs#run_connection", "crates/axo-relay/src/relay/session.rs#rpc_call"],
      sends: [RegisterHost],
      run(state, m, ctx) {
        if (state.conn !== "connecting" || state.connId !== m.conn) return;
        state.conn = "registering";
        ctx.send(ctx.the(Manager), RegisterHost, { account: state.link.account!, host: ctx.id, conn: m.conn });
      },
    },
    connectRefused: {
      on: ConnectRefused,
      description: "The relay refused the socket; axod waits and tries again, longer each time.",
      sources: ["crates/axo-relay/src/relay/socket.rs#connect_websocket", "crates/axo-relay/src/relay.rs#run_reconnect_loop"],
      run(state, m, ctx) {
        if (state.connId !== m.conn || state.conn === "idle") return;
        state.conn = "idle";
        state.connId = null;
        state.backingOff = true;
        state.delay = Math.min(state.delay * 2, MAX_RETRY.value);
      },
    },
    hostRegistered: {
      on: HostRegistered,
      description: "The host is online.",
      sources: ["crates/axo-relay/src/relay.rs#run_connection", "crates/axo-relay/src/relay/session.rs#relay_session"],
      say: () => "Online",
      run(state, m, ctx) {
        if (state.conn !== "registering" || state.connId !== m.conn) return;
        state.conn = "connected";
        state.delay = 1 * SEC;
      },
    },
    connectTimeout: {
      description: "Bringing the socket up took too long; axod drops it and waits before trying again.",
      sources: ["crates/axo-relay/src/relay/socket.rs#CONNECT_TIMEOUT", "crates/axo-relay/src/relay/socket.rs#connect_websocket"],
      sends: [Disconnect],
      run(state, _, ctx) {
        if (state.conn !== "connecting" && state.conn !== "registering") return;
        if (state.link.account && state.connId) ctx.send(ctx.the(Manager), Disconnect, { account: state.link.account, host: ctx.id, conn: state.connId });
        state.conn = "idle";
        state.connId = null;
        state.backingOff = true;
        state.delay = Math.min(state.delay * 2, MAX_RETRY.value);
      },
    },
    socketClosed: {
      on: SocketClosed,
      description: "The relay hung up; axod waits and reconnects.",
      sources: ["crates/axo-relay/src/relay/socket.rs#receive", "crates/axo-relay/src/relay.rs#run_reconnect_loop"],
      run(state, m, ctx) {
        if (state.connId !== m.conn || state.conn === "idle") return;
        state.conn = "idle";
        state.connId = null;
        state.backingOff = true;
        state.delay = Math.min(state.delay * 2, MAX_RETRY.value);
      },
    },
    backoff: {
      description: "The wait is over; axod may dial again.",
      sources: ["crates/axo-relay/src/relay.rs#wait_for_reconnect"],
      run: (state) => void (state.backingOff = false),
    },
    forward: {
      on: Forward,
      description: "axod runs the command and answers over the same socket.",
      sources: ["crates/axo-relay/src/relay/forward.rs#answer", "crates/axo-server/src/session/handlers.rs#RelayHostAdapter::answer_remote", "crates/axo-server/src/session/remote.rs#Remote::register"],
      sends: [CallDone],
      run(state, m, ctx) {
        if (state.conn !== "connected" || !state.connId || !state.link.account) return;
        state.ran.push({ for: m.account, linkedTo: state.link.account });
        ctx.send(ctx.the(Manager), CallDone, { request: m.request, account: state.link.account, host: ctx.id, conn: state.connId });
      },
    },
    // Faults: what the network and restarts may do here.
    linkHostLost: lose(LinkHost, { spend: faults }),
    linkedLost: lose(Linked, { spend: faults }),
    codeRejectedLost: lose(CodeRejected, { spend: faults }),
    admittedLost: lose(Admitted, { spend: faults }),
    connectRefusedLost: lose(ConnectRefused, { spend: faults }),
    hostRegisteredLost: lose(HostRegistered, { spend: faults }),
    socketClosedLost: lose(SocketClosed, { spend: faults }),
    forwardLost: lose(Forward, { spend: faults }),
    crash: crash({ keeps: ["link", "pending", "keychain"], spend: faults }),
  },
});

const onlyHashesStored = defineProperty("onlyHashesStored", {
  description: "The cloud never stores a pairing code or a host secret, only hashes of them.",
  always: (w) =>
    Object.keys(w.the(Index).state.entries).every((k) => k.startsWith("hash:")) &&
    Object.keys(w.the(Manager).state.pairings).every((k) => k.startsWith("hash:")) &&
    Object.values(w.the(Manager).state.hosts).every((h) => h.verifier.startsWith("hash:")),
});
const onlyLinkedHostsConnect = defineProperty("onlyLinkedHostsConnect", {
  description: "The relay only holds a socket for a host its account has linked, never a revoked one.",
  always: (w) => Object.keys(w.the(Manager).state.routes).every((key) => { const h = w.the(Manager).state.hosts[key]; return h !== undefined && !h.revoked; }),
});
const axodServesOnlyItsAccount = defineProperty("axodServesOnlyItsAccount", {
  description: "axod only runs commands for the account it is linked to.",
  always: (w) => w.all(Axod).every((a) => a.state.ran.every((r) => r.for === r.linkedTo)),
});
const accessComesFirst = defineProperty("accessComesFirst", {
  description: "The account only holds a code for an account Access has signed in.",
  always: (w) => Object.values(w.the(Manager).state.pairings).every((p) => Object.values(w.the(Access).state.sessions).includes(p.account)),
});
const peopleSeeOnlyTheirHosts = defineProperty("peopleSeeOnlyTheirHosts", {
  description: "A person only ever learns of hosts that belong to their own account.",
  always: (w) => w.all(Person).every((p) => p.state.seenHosts.every((h) => w.the(Manager).state.hosts[keyOf(p.state.account, h)] !== undefined)),
});

const pairAndLink = (s: any, alice: any, app: any) => {
  s.act(alice, "signIn");
  s.settle();
  s.act(alice, "pair");
  s.settle();
  s.act(app, "link", { code: alice.state.codes[0]! });
  s.settle();
};
const pairAMacAndReachIt = defineScenario("Pair a Mac and reach it", {
  description: "Alice gets a code, pastes it into Axo on her Mac, then runs a command on it from her phone.",
  run(s) {
    const alice = s.spawn(Person, "Alice");
    const app = s.spawn(App, "Studio app");
    s.spawn(Axod, "Studio daemon");
    pairAndLink(s, alice, app);
    s.act(alice, "run", { host: s.world.all(Axod)[0]!.id, command: "whoami" });
    s.settle();
  },
});
const aStrangerCannotReachAMac = defineScenario("A stranger cannot reach a Mac", {
  description: "Mallory has an account of her own and knows the Mac's id; the relay says it is not hers.",
  run(s) {
    const alice = s.spawn(Person, "Alice");
    const mallory = s.spawn(Person, "Mallory");
    const app = s.spawn(App, "Studio app");
    const axod = s.spawn(Axod, "Studio daemon");
    pairAndLink(s, alice, app);
    s.act(mallory, "signIn");
    s.settle();
    s.act(mallory, "pair");
    s.settle();
    s.act(mallory, "refresh");
    s.settle();
    s.act(mallory, "open", { host: axod.id });
    s.settle();
    s.act(mallory, "run", { host: axod.id, command: "whoami" });
    s.settle();
  },
});
const anInvalidCode = defineScenario("An invalid code", {
  description: "A made-up pairing code is rejected, while a valid issued code can be redeemed.",
  run(s) {
    const alice = s.spawn(Person, "Alice");
    const app = s.spawn(App, "Studio app");
    s.spawn(Axod, "Studio daemon");
    s.act(alice, "signIn");
    s.settle();
    s.act(alice, "pair");
    s.settle();
    s.act(app, "link", { code: "NOT-A-CODE" });
    s.settle();
    s.act(app, "link", { code: alice.state.codes[0]! });
    s.settle();
  },
});
const axodRestartsAndComesBack = defineScenario("axod restarts and comes back", {
  description: "axod restarts without saying goodbye and reconnects; this model abstracts away the old route's lease period.",
  run(s) {
    const alice = s.spawn(Person, "Alice");
    const app = s.spawn(App, "Studio app");
    const axod = s.spawn(Axod, "Studio daemon");
    pairAndLink(s, alice, app);
    s.step(axod, "crash");
    s.settle();
    s.act(alice, "run", { host: axod.id, command: "whoami" });
    s.settle();
  },
});
const notSignedIn = defineScenario("Not signed in", {
  description: "Without a Cloudflare Access session the request never reaches the relay.",
  run(s) {
    const alice = s.spawn(Person, "Alice");
    s.act(alice, "pair");
    s.settle();
  },
});
const aliceWatchesHerMac = defineScenario("Alice watches her Mac", {
  description: "Alice opens her Mac, sees it online, types, then axod restarts: she sees it go offline and come back.",
  run(s) {
    const alice = s.spawn(Person, "Alice");
    const app = s.spawn(App, "Studio app");
    const axod = s.spawn(Axod, "Studio daemon");
    pairAndLink(s, alice, app);
    s.act(alice, "refresh");
    s.settle();
    s.act(alice, "open", { host: axod.id });
    s.settle();
    s.act(alice, "run", { host: axod.id, command: "whoami" });
    s.settle();
    s.step(axod, "crash");
    s.settle();
  },
});
const aPresenceUpdateIsLost = defineScenario("A presence update is lost", {
  description: "Alice opens her Mac while it is still connecting and sees it offline; the relay's 'online' notice to her is lost, so her terminal says offline though the Mac is online.",
  run(s) {
    const alice = s.spawn(Person, "Alice");
    const app = s.spawn(App, "Studio app");
    const axod = s.spawn(Axod, "Studio daemon");
    const manager = () => s.world.the(Manager).state;
    const key = () => keyOf(alice.state.account, axod.id);
    s.act(alice, "signIn");
    s.settle();
    s.act(alice, "pair");
    s.settle();
    s.act(app, "link", { code: alice.state.codes[0]! });
    // The account knows the Mac, but it has not registered on its socket yet.
    s.settle({ until: () => manager().hosts[key()] !== undefined });
    s.act(alice, "open", { host: axod.id });
    s.deliver(s.the(Access), OpenHost);
    s.deliver(s.the(Worker), OpenHost);
    s.deliver(s.the(Manager), OpenHost);
    s.deliver(alice, Opened);
    s.settle({ until: () => manager().routes[key()]?.ready === true });
    s.step(alice, "hostStatusLost");
    s.settle();
  },
});
const twoPeopleTwoMacs = defineScenario("Two people, two Macs", {
  description: "Alice and Bob each link a Mac. Bob's list shows only his, and opening Alice's is a 404.",
  run(s) {
    const alice = s.spawn(Person, "Alice");
    const bob = s.spawn(Person, "Bob");
    const studio = s.spawn(App, "Studio app");
    const imac = s.spawn(App, "iMac app");
    const studioD = s.spawn(Axod, "Studio daemon");
    s.spawn(Axod, "iMac daemon");
    s.act(alice, "signIn");
    s.act(bob, "signIn");
    s.settle();
    s.act(alice, "pair");
    s.act(bob, "pair");
    s.settle();
    s.act(studio, "link", { code: alice.state.codes[0]! });
    s.act(imac, "link", { code: bob.state.codes[0]! });
    s.settle();
    s.act(bob, "refresh");
    s.settle();
    s.act(bob, "open", { host: studioD.id });
    s.settle();
  },
});
const revokingAMac = defineScenario("Revoking a Mac", {
  description: "Alice revokes her Mac; it is cut off and cannot reconnect.",
  run(s) {
    const alice = s.spawn(Person, "Alice");
    const app = s.spawn(App, "Studio app");
    const axod = s.spawn(Axod, "Studio daemon");
    pairAndLink(s, alice, app);
    s.act(alice, "open", { host: axod.id });
    s.settle();
    s.act(alice, "revoke", { host: axod.id });
    s.settle();
    s.act(alice, "run", { host: axod.id, command: "whoami" });
    s.settle();
  },
});

// What a newcomer sees: one relay for people, and one Mac that runs an app and a daemon.
const axoRelayGroup = defineGroup({ name: "Axo relay", actors: [Worker, Manager, Index], icon: "cloud" });
const macGroup = defineGroup({ name: "Mac", actors: { app: App, daemon: Axod }, icon: "laptop", names: ["Studio", "iMac"] });

export default defineSpec({
  name: "Remote access",
  description:
    "How a Mac is paired with an account using a one-time code, and how a person then reaches it through the relay. The model omits code expiry, host leases, request deadlines, and reconnect backoff; message ordering and restarts remain in scope.",
  actors: [Access, Worker, Index, Manager, Person, App, Axod],
  groups: [axoRelayGroup, macGroup],
  limits: [CODE_LIFETIME, INDEX_GRACE, PENDING_CODES, HTTP_TIMEOUT, CONNECT_TIMEOUT, LEASE, DEADLINE, MAX_RETRY, APP_RPC_TIMEOUT, REQUEST_TIMEOUT],
  properties: [onlyHashesStored, onlyLinkedHostsConnect, axodServesOnlyItsAccount, accessComesFirst, peopleSeeOnlyTheirHosts],
  scenarios: [pairAMacAndReachIt, aStrangerCannotReachAMac, anInvalidCode, axodRestartsAndComesBack, notSignedIn, aliceWatchesHerMac, aPresenceUpdateIsLost, twoPeopleTwoMacs, revokingAMac],
});
