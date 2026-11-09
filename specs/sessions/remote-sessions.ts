import { atMost, budget, type Ctx, defineActor, defineCall, defineGroup, defineLimit, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone, failed, listOf, lose, oneOf } from "@leostera/feynman";

// RFD0024: a Session runs on one Mac, and only that Mac's Pi writes its log. Another Mac shows it
// in a terminal pane running Pi in remote mode (pi-axo, `pi --no-session`): the pane draws the
// local copy of the log (RFD0022's mirror) and sends what Leo types to the Mac that runs the
// Session, through its own axod and the peers socket, as the phone does (RFD0018). Nothing the
// pane does writes the log; what Leo typed shows up only when the log, on its way back, says so.
//
// Leo works on the MacBook. The Session runs on the Studio, where someone (Leo, or the phone) may
// also type. Every prompt is "yes", so two prompts can only be told apart by their commandId.
//
// Folded away: the upload and the delivery of records. Studio axod uploads the whole file as a
// snapshot with a version, and "Cloud copy" (the HostDO, the SessionDO and the MacBook's ClientDO
// together) hands the newest one to MacBook axod. session-sync.ts and client-delivery.ts check
// that the real, line-by-line path delivers exactly that: the cloud's records, in order, with a
// reset after a cut. Not modelled: answering questions (the same rule as stop: it names the
// question), progress while a reply is written, several Sessions, continuing on another Mac.

const faults = budget("faults", 1);

const EntryFields = { kind: oneOf("user", "reply", "stopped"), turn: Number, command: String };

type Entry = { kind: "user" | "reply" | "stopped"; turn: number; command: string };
type Copy = { version: number; epoch: number; entries: Entry[] };
type Kind = "prompt" | "stop";
type Outcome = "accepted" | "offline" | "unknown" | "ignored";
type Pending = { state: "sending" | "unknown" | "accepted" };
type StudioAxodState = { online: boolean; studio: number; file: Copy; uploaded: number };
type StudioPiState = {
  log: Entry[];
  epoch: number;
  version: number;
  turns: number;
  /** The turn running, by the id of the user record that started it. */
  running: number | null;
  /** Remote prompts pi-axo holds until Pi is idle (ownQueue). */
  held: string[];
  /** Pi's own steering queue. */
  steering: string[];
  /** commandIds pi-axo has seen in this Pi's life: the log's, and the ones it holds. */
  seen: Set<string>;
  /** Remote prompts a stop moved into the Studio's editor. */
  editor: string[];
  /** How many user records each commandId got, ever (for the properties). */
  landed: Record<string, number>;
  /** The turns remote stops ended, and the turn each one named (for the properties). */
  stops: { named: number; ended: number }[];
};

const NO_COMMAND = "";
const TEXT = "yes";

// Rules: each one exists to keep a property true; check expects that property to break without it.
const commandReceipts = defineRule("commandReceipts", { description: "A prompt's user record carries its commandId, and clients match pending prompts by it, never by text." });
const dedupeCommands = defineRule("dedupeCommands", { description: "pi-axo on the Studio answers a commandId it has seen with accepted, and does not prompt Pi again." });
const retryUnknown = defineRule("retryUnknown", { description: "A prompt whose outcome is unknown is sent again, with the same commandId, until an answer says what happened." });
const unknownStaysUnknown = defineRule("unknownStaysUnknown", { description: "Once a prompt may have run, an offline refusal of a retry does not give the text back: the first try may still land." });
const ownQueue = defineRule("ownQueue", { description: "pi-axo holds remote prompts that arrive during a turn and prompts Pi with each when it is idle, rather than steering Pi's queue, which a stop empties into the Studio's editor." });
const stopNamesTurn = defineRule("stopNamesTurn", { description: "A stop names the turn the client showed running, and the Studio ignores it when another turn is running." });
const restartOnCut = defineRule("restartOnCut", { description: "When the copy is cut back (a new epoch), the pane draws it again from the copy rather than adding the lines after the ones it shows." });

// MacBook Pi (remote pane) ⇄ MacBook axod: axod's local socket.
const PeerCommand = defineMessage("PeerCommand", { command: String, kind: String, turn: Number }, { name: "axo.peer.command", over: "unix socket" });
const PeerAnswer = defineMessage("PeerAnswer", { command: String, kind: String, outcome: String }, { name: "what happened", over: "unix socket", tone: "reply" });
const Shown = defineMessage("Shown", { version: Number, epoch: Number, entries: listOf(EntryFields) }, { name: "axo.peer.session.copy", over: "unix socket" });
// MacBook axod ⇄ its ClientDO: the peers socket.
const ClientCommand = defineMessage("ClientCommand", { socket: Number, command: String, kind: String, turn: Number }, { name: "axo.client.command", over: "websocket" });
const ClientReply = defineMessage("ClientReply", { socket: Number, command: String, kind: String, outcome: String }, { name: "command reply", over: "websocket", tone: "reply" });
// ClientDO → HostDO: a Durable Object call, which can throw.
const HostCommand = defineCall("HostCommand", { socket: Number, command: String, kind: String, turn: Number }, { name: "HostDO.command", over: "rpc" });
const HostAnswer = defineMessage("HostAnswer", { socket: Number, command: String, kind: String, outcome: String }, { name: "command outcome", over: "rpc", tone: "reply" });
// HostDO ⇄ Studio axod: the host socket.
const Remote = defineMessage("Remote", { hop: String, studio: Number, command: String, kind: String, turn: Number }, { name: "axo.remote.session.prompt / stop", over: "websocket" });
const RemoteReply = defineMessage("RemoteReply", { hop: String, studio: Number, outcome: String }, { name: "remote reply", over: "websocket", tone: "reply" });
const Online = defineMessage("Online", { studio: Number }, { name: "host socket opened", over: "websocket" });
const Offline = defineMessage("Offline", { studio: Number }, { name: "host socket closed", over: "websocket", tone: "refused" });
// Studio axod ⇄ Studio Pi: pi-axo's bridge socket, and the session file.
const Bridge = defineMessage("Bridge", { hop: String, command: String, kind: String, turn: Number }, { name: "bridge command", over: "unix socket" });
const BridgeReply = defineMessage("BridgeReply", { hop: String, outcome: String }, { name: "bridge reply", over: "unix socket", tone: "reply" });
const Written = defineMessage("Written", { version: Number, epoch: Number, entries: listOf(EntryFields) }, { name: "session file changed", over: "file" });
// Studio axod → Cloud copy → MacBook axod: the upload and the delivery, folded.
const Upload = defineMessage("Upload", { version: Number, epoch: Number, entries: listOf(EntryFields) }, { name: "axo.host.session.append", over: "websocket" });
const Records = defineMessage("Records", { version: Number, epoch: Number, entries: listOf(EntryFields) }, { name: "axo.client.session.records / reset", over: "websocket" });

const macbook = defineZone({ name: "MacBook", description: "where Leo reads and types", place: { column: 0 } });
const cloud = defineZone({ name: "Cloudflare", description: "one ClientDO per follower, one HostDO per Mac", place: { column: 1, region: true } });
const studio = defineZone({ name: "Studio", description: "where the Session runs", place: { column: 2 } });

const deadline = defineLimit({ name: "A command with no reply from the host for this long has an unknown outcome", value: 10, unit: "seconds", sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.command"] });
const renewal = defineLimit({ name: "The peers socket is renewed after", value: 50, unit: "minutes", sources: ["crates/axo-relay/src/peers/follower.rs#Follower::follow"] });

const sameEntries = (a: readonly Entry[], b: readonly Entry[]) => a.length === b.length && a.every((e, i) => e.kind === b[i]!.kind && e.turn === b[i]!.turn && e.command === b[i]!.command);
/** The turn the log shows running: its last record is a user message. */
const runningTurn = (entries: readonly Entry[]): number | null => {
  const last = entries.at(-1);
  return last?.kind === "user" ? last.turn : null;
};

export const MacBookPi = defineActor({
  name: "MacBook Pi",
  description: "Pi in remote mode in a MacBook pane: pi-axo draws the copy and turns what Leo types into commands; no model or tool ever runs here.",
  zone: macbook,
  singleton: true,
  initialState: () => ({
    /** The version of the copy on screen: the pane ignores an older one. */
    version: 0,
    epoch: 1,
    entries: [] as Entry[],
    /** Prompts sent and not yet seen in the log, by commandId. */
    pending: {} as Record<string, Pending>,
    /** Prompts the chat shows as Leo's, by commandId. */
    delivered: new Set<string>(),
    /** Prompts given back to the editor: Leo may send the text again. */
    returned: new Set<string>(),
    /** User records already matched to a prompt, when matching by text. */
    matched: 0,
    prompts: 0,
    stopping: false,
  }),
  display: {
    icon: "terminal",
    status: (s) => `${s.entries.length} record(s) shown, ${Object.keys(s.pending).length} prompt(s) pending`,
    mood: (s) => (Object.keys(s.pending).length ? "busy" : "ok"),
    rows: (s) => [
      { label: "chat", detail: s.entries.map((e) => `${e.kind}${e.turn}`).join(" ") || "empty" },
      ...Object.entries(s.pending).map(([command, p]) => ({ label: `"${TEXT}" ${command}`, detail: p.state, mood: p.state === "unknown" ? ("warn" as const) : ("busy" as const) })),
      ...[...s.returned].map((command) => ({ label: `"${TEXT}" ${command}`, detail: "back in the editor", mood: "info" as const })),
    ],
  },
  actions: {
    prompt: {
      with: [atMost(2)],
      label: `Leo sends "${TEXT}"`,
      description: "pi-axo's input handler takes the text, marks it handled so Pi starts no turn here, and sends it to the Studio.",
      sends: [PeerCommand],
      run(state, _i, ctx) {
        state.prompts += 1;
        const command = `c${state.prompts}`;
        state.pending[command] = { state: "sending" };
        ctx.send(ctx.the(MacBookAxod), PeerCommand, { command, kind: "prompt", turn: 0 });
      },
    },
    stop: {
      with: [atMost(1)],
      label: "Leo presses Escape",
      description: "Stops the turn the chat shows running on the Studio.",
      when: (s) => !s.stopping && runningTurn(s.entries) !== null,
      sends: [PeerCommand],
      run(state, _i, ctx) {
        state.stopping = true;
        ctx.send(ctx.the(MacBookAxod), PeerCommand, { command: "stop", kind: "stop", turn: runningTurn(state.entries)! });
      },
    },
  },
  transitions: {
    answered: {
      on: PeerAnswer,
      description: "Shows what happened to a command: a prompt waits for its record, comes back to the editor, or is tried again.",
      starts: ["retry"],
      say: (_s, m) => `${m.kind} ${m.command}: ${m.outcome}`,
      run(state, m, ctx) {
        if (m.kind === "stop") return void (state.stopping = false);
        const pending = state.pending[m.command];
        if (!pending) return;
        if (m.outcome === "accepted") return void (pending.state = "accepted");
        if (m.outcome === "offline" && (pending.state !== "unknown" || !unknownStaysUnknown.on)) {
          // Nothing ran: the text goes back to the editor, with "The Studio is offline".
          delete state.pending[m.command];
          state.returned.add(m.command);
          return;
        }
        pending.state = "unknown";
        if (retryUnknown.on) ctx.start("retry");
      },
    },
    retry: {
      description: "Sends every prompt whose outcome is unknown again, with its commandId.",
      after: "5 seconds",
      sends: [PeerCommand],
      run(state, _, ctx) {
        for (const [command, pending] of Object.entries(state.pending)) {
          if (pending.state !== "unknown") continue;
          ctx.send(ctx.the(MacBookAxod), PeerCommand, { command, kind: "prompt", turn: 0 });
        }
      },
    },
    shown: {
      on: Shown,
      description: "Draws the copy, and retires the pending prompts whose records it now shows.",
      say: (s) => `Shows ${s.entries.length} record(s) of epoch ${s.epoch}`,
      run(state, m) {
        if (m.version <= state.version) return;
        state.version = m.version;
        const entries = m.entries;
        if (m.epoch === state.epoch || restartOnCut.on) state.entries = entries.map((e) => ({ ...e }));
        // Tailing: only the lines past the ones on screen are added.
        else state.entries.push(...entries.slice(state.entries.length).map((e) => ({ ...e })));
        if (m.epoch !== state.epoch) state.matched = Math.min(state.matched, state.entries.length);
        state.epoch = m.epoch;
        if (commandReceipts.on) {
          for (const e of state.entries) {
            if (e.kind !== "user" || !state.pending[e.command]) continue;
            delete state.pending[e.command];
            state.delivered.add(e.command);
          }
          return;
        }
        // By text: the oldest pending "yes" takes each new user record that says "yes".
        const users = state.entries.filter((e) => e.kind === "user");
        for (; state.matched < users.length; state.matched++) {
          const oldest = Object.keys(state.pending).sort()[0];
          if (oldest === undefined) continue;
          delete state.pending[oldest];
          state.delivered.add(oldest);
        }
      },
    },
  },
});

export const MacBookAxod = defineActor({
  name: "MacBook axod",
  description: "Follows the account over the peers socket: keeps the copy, and forwards the pane's commands with the host credential.",
  zone: macbook,
  singleton: true,
  initialState: () => ({
    connected: true,
    socket: 1,
    /** Commands sent on the current socket and not answered, as "kind:commandId". */
    inFlight: new Set<string>(),
    copy: { version: 0, epoch: 1, entries: [] as Entry[] } as Copy,
  }),
  display: {
    icon: "laptop",
    status: (s) => `${s.connected ? "peers socket open" : "peers socket closed"}, copy of ${s.copy.entries.length} record(s)`,
    mood: (s) => (s.connected ? "ok" : "off"),
  },
  links: (s) => (s.connected ? [{ to: "ClientDO", kind: "websocket" }] : []),
  actions: {
    renew: {
      with: [atMost(1)],
      label: "The peers socket closes",
      description: "The socket is renewed (every 50 minutes) or the network drops it; replies still on it are lost.",
      when: (s) => s.connected,
      sends: [PeerAnswer],
      sources: ["crates/axo-relay/src/peers/follower.rs#Follower::follow"],
      run(state, _i, ctx) {
        state.connected = false;
        for (const key of state.inFlight) {
          const [kind, command] = key.split(":") as [Kind, string];
          ctx.send(ctx.the(MacBookPi), PeerAnswer, { command, kind, outcome: "unknown" });
        }
        state.inFlight.clear();
      },
    },
  },
  transitions: {
    reconnect: {
      description: "Opens a new peers socket and signs in with the host credential.",
      when: (s) => !s.connected,
      sources: ["crates/axo-relay/src/peers.rs#PeersWorker::start"],
      run(state) {
        state.socket += 1;
        state.connected = true;
      },
    },
    command: {
      on: PeerCommand,
      description: "Sends the pane's command to the Studio on the peers socket; with no socket, nothing is sent and the pane is told the Studio is unreachable.",
      sends: [ClientCommand, PeerAnswer],
      run(state, m, ctx) {
        if (!state.connected) return ctx.reply(PeerAnswer, { command: m.command, kind: m.kind, outcome: "offline" });
        state.inFlight.add(`${m.kind}:${m.command}`);
        ctx.send(ctx.the(ClientDO), ClientCommand, { socket: state.socket, command: m.command, kind: m.kind, turn: m.turn });
      },
    },
    reply: {
      on: ClientReply,
      description: "Passes the outcome to the pane; a reply on an older socket answers nothing.",
      sends: [PeerAnswer],
      run(state, m, ctx) {
        if (m.socket !== state.socket || !state.inFlight.delete(`${m.kind}:${m.command}`)) return;
        const outcome = m.outcome === "unavailable" ? "unknown" : m.outcome;
        ctx.send(ctx.the(MacBookPi), PeerAnswer, { command: m.command, kind: m.kind, outcome });
      },
    },
    records: {
      on: Records,
      description: "Writes the records to the copy under ~/.axo/sessions/<Studio>/ and tells the pane.",
      sources: ["crates/axo-relay/src/peers/follower.rs#Follower::records", "crates/axo-relay/src/peers/follower.rs#Follower::reset"],
      sends: [Shown],
      run(state, m, ctx) {
        if (m.version <= state.copy.version) return;
        state.copy = { version: m.version, epoch: m.epoch, entries: m.entries.map((e) => ({ ...e })) };
        ctx.send(ctx.the(MacBookPi), Shown, { version: m.version, epoch: m.epoch, entries: m.entries });
      },
    },
  },
});

export const ClientDO = defineActor({
  name: "ClientDO",
  description: "The MacBook's client Durable Object (client id host-<MacBook>): forwards commands to the Studio's HostDO.",
  zone: cloud,
  singleton: true,
  initialState: () => ({}),
  display: { icon: "cloud", status: () => "forwards commands" },
  transitions: {
    command: {
      on: ClientCommand,
      description: "Calls the HostDO with the command.",
      sources: ["packages/axo-api-worker/src/client-do.ts#AxoClientDO.receive"],
      sends: [HostCommand],
      run: (_s, m, ctx) => ctx.send(ctx.the(HostDO), HostCommand, { socket: m.socket, command: m.command, kind: m.kind, turn: m.turn }),
    },
    answer: {
      on: HostAnswer,
      description: "Replies to MacBook axod with the outcome.",
      sends: [ClientReply],
      run: (_s, m, ctx) => ctx.send(ctx.the(MacBookAxod), ClientReply, { socket: m.socket, command: m.command, kind: m.kind, outcome: m.outcome }),
    },
    callFailed: {
      on: failed(HostCommand),
      description: "The call threw: the reply is -32603 \"Unavailable; try again\", and nobody knows whether the Studio got it.",
      sources: ["packages/axo-api-worker/src/client-do.ts#AxoClientDO.receive"],
      sends: [ClientReply],
      run: (_s, f, ctx) => ctx.send(ctx.the(MacBookAxod), ClientReply, { socket: f.payload.socket, command: f.payload.command, kind: f.payload.kind, outcome: "unavailable" }),
    },
  },
});

export const HostDO = defineActor({
  name: "HostDO",
  description: "The Studio's host Durable Object: holds its socket and forwards commands to it, failing at once when it is offline.",
  zone: cloud,
  singleton: true,
  initialState: () => ({
    online: true,
    studio: 1,
    /** Commands forwarded to the Studio and not answered, by hop id. */
    waiting: {} as Record<string, { socket: number; command: string; kind: string }>,
    hops: 0,
  }),
  display: {
    icon: "cloud",
    status: (s) => `${s.online ? "Studio online" : "Studio offline"}, ${Object.keys(s.waiting).length} command(s) waiting`,
    mood: (s) => (s.online ? "ok" : "off"),
  },
  transitions: {
    command: {
      on: HostCommand,
      description: "Forwards the command to the Studio, or answers -32005 \"Host offline; nothing queued\".",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.command"],
      sends: [Remote, HostAnswer],
      starts: ["deadline"],
      run(state, m, ctx) {
        if (!state.online) return ctx.reply(HostAnswer, { socket: m.socket, command: m.command, kind: m.kind, outcome: "offline" });
        state.hops += 1;
        const hop = `h${state.hops}`;
        state.waiting[hop] = { socket: m.socket, command: m.command, kind: m.kind };
        ctx.send(ctx.the(StudioAxod), Remote, { hop, studio: state.studio, command: m.command, kind: m.kind, turn: m.turn });
        ctx.start("deadline");
      },
    },
    reply: {
      on: RemoteReply,
      description: "Answers the waiting command with the Studio's reply; a reply from an older socket answers nothing.",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.receiveReply"],
      sends: [HostAnswer],
      run(state, m, ctx) {
        const waiting = state.waiting[m.hop];
        if (!waiting || m.studio !== state.studio) return;
        delete state.waiting[m.hop];
        ctx.send(ctx.the(ClientDO), HostAnswer, { ...waiting, outcome: m.outcome });
      },
    },
    deadline: {
      description: "Commands the Studio has not answered in time get -32004 \"Outcome unknown; reconcile commandId\".",
      after: "10 seconds",
      sources: ["packages/axo-api-worker/src/host-do.ts#AxoHostDO.command"],
      sends: [HostAnswer],
      run(state, _, ctx) {
        for (const waiting of Object.values(state.waiting)) ctx.send(ctx.the(ClientDO), HostAnswer, { ...waiting, outcome: "unknown" });
        state.waiting = {};
      },
    },
    online: {
      on: Online,
      description: "The Studio's socket is open.",
      run(state, m) {
        state.online = true;
        state.studio = m.studio;
      },
    },
    offline: {
      on: Offline,
      description: "The Studio's socket closed: commands still waiting have an unknown outcome.",
      sources: ["packages/axo-api-worker/src/axo-host-relay.ts#AxoHostRelay.webSocketClose"],
      sends: [HostAnswer],
      run(state, m, ctx) {
        if (m.studio !== state.studio) return;
        state.online = false;
        for (const waiting of Object.values(state.waiting)) ctx.send(ctx.the(ClientDO), HostAnswer, { ...waiting, outcome: "unknown" });
        state.waiting = {};
      },
    },
    commandLost: lose(HostCommand, { spend: faults }),
    replyLost: lose(RemoteReply, { spend: faults }),
  },
});

export const CloudCopy = defineActor({
  name: "Cloud copy",
  description: "The Session's log in the cloud and its delivery to MacBook axod (HostDO upload, SessionDO, ClientDO), folded: session-sync.ts and client-delivery.ts check it.",
  zone: cloud,
  singleton: true,
  initialState: () => ({ copy: { version: 0, epoch: 1, entries: [] as Entry[] } as Copy }),
  display: { icon: "database", status: (s) => `${s.copy.entries.length} record(s), epoch ${s.copy.epoch}` },
  transitions: {
    upload: {
      on: Upload,
      description: "Commits the Studio's records and delivers them to every follower.",
      sources: ["crates/axo-relay/src/sync/uploader.rs#Uploader::upload_next"],
      sends: [Records],
      run(state, m, ctx) {
        if (m.version <= state.copy.version) return;
        state.copy = { version: m.version, epoch: m.epoch, entries: m.entries.map((e) => ({ ...e })) };
        ctx.send(ctx.the(MacBookAxod), Records, { version: m.version, epoch: m.epoch, entries: m.entries });
      },
    },
  },
});

export const StudioAxod = defineActor({
  name: "Studio axod",
  description: "The Studio's daemon: holds the host socket, passes commands to the Session's Pi, and uploads its file.",
  zone: studio,
  singleton: true,
  initialState: (): StudioAxodState => ({ online: true, studio: 1, file: { version: 0, epoch: 1, entries: [] }, uploaded: 0 }),
  display: {
    icon: "desktop",
    status: (s) => (s.online ? `online, uploaded version ${s.uploaded}` : "asleep"),
    mood: (s) => (s.online ? "ok" : "off"),
  },
  links: (s) => (s.online ? [{ to: "HostDO", kind: "websocket" }] : []),
  actions: {
    sleep: {
      with: [atMost(1)],
      label: "The Studio sleeps",
      description: "The Studio goes to sleep and its host socket closes.",
      when: (s) => s.online,
      sends: [Offline],
      starts: ["wake"],
      run(state, _i, ctx) {
        state.online = false;
        ctx.send(ctx.the(HostDO), Offline, { studio: state.studio });
        ctx.start("wake");
      },
    },
  },
  transitions: {
    wake: {
      description: "The Studio wakes, opens a new host socket, and uploads what it wrote meanwhile.",
      after: "a while",
      sends: [Online, Upload],
      run(state, _, ctx) {
        state.online = true;
        state.studio += 1;
        ctx.send(ctx.the(HostDO), Online, { studio: state.studio });
        upload(state, ctx);
      },
    },
    remote: {
      on: Remote,
      description: "Passes a prompt or a stop to the Session's pi-axo over its bridge.",
      sources: ["crates/axo-relay/src/relay/forward.rs#answer", "crates/axo-server/src/session/remote.rs#prompt", "crates/axo-server/src/session/prompts.rs#SessionManager::prompt_pi"],
      sends: [Bridge],
      run(state, m, ctx) {
        if (!state.online || m.studio !== state.studio) return;
        ctx.send(ctx.the(StudioPi), Bridge, { hop: m.hop, command: m.command, kind: m.kind, turn: m.turn });
      },
    },
    bridged: {
      on: BridgeReply,
      description: "Replies to the HostDO on the socket the command came on, if it is still open.",
      sends: [RemoteReply],
      run(state, m, ctx) {
        if (!state.online) return;
        ctx.send(ctx.the(HostDO), RemoteReply, { hop: m.hop, studio: state.studio, outcome: m.outcome });
      },
    },
    written: {
      on: Written,
      description: "Sees the session file change and uploads it while online.",
      sends: [Upload],
      run(state, m, ctx) {
        if (m.version <= state.file.version) return;
        state.file = { version: m.version, epoch: m.epoch, entries: m.entries.map((e) => ({ ...e })) };
        if (state.online) upload(state, ctx);
      },
    },
    remoteLost: lose(Remote, { spend: faults }),
  },
});

function upload(state: StudioAxodState, ctx: Ctx) {
  if (state.file.version <= state.uploaded) return;
  state.uploaded = state.file.version;
  ctx.send(ctx.the(CloudCopy), Upload, { version: state.file.version, epoch: state.file.epoch, entries: state.file.entries });
}

export const StudioPi = defineActor({
  name: "Studio Pi",
  description: "The Session's Pi on the Studio, with pi-axo: the only writer of its log.",
  zone: studio,
  singleton: true,
  initialState: (): StudioPiState => ({ log: [], epoch: 1, version: 0, turns: 0, running: null, held: [], steering: [], seen: new Set(), editor: [], landed: {}, stops: [] }),
  display: {
    icon: "robot",
    status: (s) => (s.running !== null ? `turn ${s.running} running` : "idle"),
    mood: (s) => (s.editor.length ? "bad" : s.running !== null ? "busy" : "ok"),
    rows: (s) => [
      { label: "log", detail: s.log.map((e) => `${e.kind}${e.turn}${e.command ? `(${e.command})` : ""}`).join(" ") || "empty" },
      ...(s.held.length ? [{ label: "held by pi-axo", detail: s.held.join(", ") }] : []),
      ...(s.editor.length ? [{ label: "Studio editor", detail: s.editor.join(", "), mood: "bad" as const }] : []),
    ],
  },
  actions: {
    localPrompt: {
      with: [atMost(1)],
      label: `Someone types "${TEXT}" on the Studio`,
      description: "A prompt typed in the Studio's own pane (or sent from the phone while Pi is idle) starts a turn.",
      when: (s) => s.running === null,
      sends: [Written],
      starts: ["finish"],
      run(state, _i, ctx) {
        start(state, NO_COMMAND, ctx);
        written(state, ctx);
      },
    },
    rewrite: {
      with: [atMost(1)],
      label: "The file is cut back",
      description: "While Pi is idle, the session file is rewritten shorter (a restore, a migration): the upload cuts the cloud's copy back and starts a new epoch.",
      when: (s) => s.log.length > 0 && s.running === null,
      sends: [Written],
      run(state, _i, ctx) {
        state.log.pop();
        state.epoch += 1;
        written(state, ctx);
      },
    },
  },
  transitions: {
    finish: {
      description: "The model finishes the turn; pi-axo then prompts Pi with the next prompt it holds.",
      after: "a while",
      sends: [Written],
      starts: ["finish"],
      run(state, _, ctx) {
        if (state.running === null) return;
        state.log.push({ kind: "reply", turn: state.running!, command: NO_COMMAND });
        state.running = null;
        const next = state.held.shift();
        if (next !== undefined) start(state, next, ctx);
        written(state, ctx);
      },
    },
    steered: {
      description: "Pi reads a steering message between two tool calls of the turn.",
      when: (s) => s.running !== null && s.steering.length > 0,
      sends: [Written],
      run(state, _, ctx) {
        const command = state.steering.shift()!;
        state.log.push({ kind: "user", turn: state.running!, command });
        state.landed[command] = (state.landed[command] ?? 0) + 1;
        written(state, ctx);
      },
    },
    bridge: {
      on: Bridge,
      description: "pi-axo takes a prompt (it prompts Pi, or holds or steers it during a turn) or a stop.",
      sources: ["packages/pi-axo/src/extension.ts#installAxoPiExtension"],
      sends: [BridgeReply, Written],
      starts: ["finish"],
      run(state, m, ctx) {
        if (m.kind === "stop") {
          if (state.running === null || (stopNamesTurn.on && state.running !== m.turn)) return ctx.reply(BridgeReply, { hop: m.hop, outcome: "ignored" });
          state.stops.push({ named: m.turn, ended: state.running });
          state.log.push({ kind: "stopped", turn: state.running, command: NO_COMMAND });
          state.running = null;
          // Pi's terminal UI: an abort moves the steering queue into the editor (restoreQueuedMessagesToEditor).
          state.editor.push(...state.steering);
          state.steering = [];
          const next = state.held.shift();
          if (next !== undefined) start(state, next, ctx);
          written(state, ctx);
          return ctx.reply(BridgeReply, { hop: m.hop, outcome: "accepted" });
        }
        if (dedupeCommands.on && state.seen.has(m.command)) return ctx.reply(BridgeReply, { hop: m.hop, outcome: "accepted" });
        state.seen.add(m.command);
        if (state.running === null) {
          start(state, m.command, ctx);
          written(state, ctx);
        } else if (ownQueue.on) state.held.push(m.command);
        else state.steering.push(m.command);
        ctx.reply(BridgeReply, { hop: m.hop, outcome: "accepted" });
      },
    },
  },
});

function start(state: StudioPiState, command: string, ctx: Ctx) {
  ctx.start("finish");
  state.turns += 1;
  state.log.push({ kind: "user", turn: state.turns, command });
  state.running = state.turns;
  if (command !== NO_COMMAND) state.landed[command] = (state.landed[command] ?? 0) + 1;
}
function written(state: StudioPiState, ctx: Ctx) {
  state.version += 1;
  ctx.send(ctx.the(StudioAxod), Written, { version: state.version, epoch: state.epoch, entries: state.log.map((e) => ({ ...e })) });
}

const macbookGroup = defineGroup({ name: "MacBook", actors: [MacBookPi, MacBookAxod], icon: "laptop", collapsed: false });
const studioGroup = defineGroup({ name: "Studio", actors: [StudioAxod, StudioPi], icon: "desktop", collapsed: false });

// Properties ------------------------------------------------------------------------------------

const promptLandsOnce = defineProperty("promptLandsOnce", {
  description: "A prompt Leo sent once becomes at most one user record on the Studio.",
  always: (w) => Object.values(w.the(StudioPi).state.landed).every((n) => n <= 1),
  needs: [dedupeCommands],
});
const deliveredMeansLanded = defineProperty("deliveredMeansLanded", {
  description: "The MacBook shows a prompt as Leo's only if the Studio wrote it.",
  always: (w) => [...w.the(MacBookPi).state.delivered].every((c) => (w.the(StudioPi).state.landed[c] ?? 0) > 0),
  needs: [commandReceipts],
});
const returnedNeverLands = defineProperty("returnedNeverLands", {
  description: "A prompt given back to the editor never runs: Leo can send it again without sending it twice.",
  always: (w) => [...w.the(MacBookPi).state.returned].every((c) => (w.the(StudioPi).state.landed[c] ?? 0) === 0),
  needs: [unknownStaysUnknown],
});
const remotePromptsStayRemote = defineProperty("remotePromptsStayRemote", {
  description: "A remote prompt never ends up in the Studio's editor, where nobody sees it.",
  always: (w) => w.the(StudioPi).state.editor.length === 0,
  needs: [ownQueue],
});
const stopEndsTheTurnShown = defineProperty("stopEndsTheTurnShown", {
  description: "Leo's stop ends only the turn his chat showed running.",
  always: (w) => w.the(StudioPi).state.stops.every((s) => s.named === s.ended),
  needs: [stopNamesTurn],
});
const paneShowsTheLog = defineProperty("paneShowsTheLog", {
  description: "Once nothing is in flight and the Studio is online, the pane shows exactly the Studio's log.",
  always: (w) => !w.quiet || !w.the(StudioAxod).state.online || (w.the(MacBookPi).state.epoch === w.the(StudioPi).state.epoch && sameEntries(w.the(MacBookPi).state.entries, w.the(StudioPi).state.log)),
  needs: [restartOnCut],
});
const promptsResolve = defineProperty("promptsResolve", {
  description: "Every prompt Leo sends ends shown in the chat or back in his editor.",
  leadsTo: { whenever: (w) => Object.keys(w.the(MacBookPi).state.pending).length > 0, then: (w) => Object.keys(w.the(MacBookPi).state.pending).length === 0 },
  needs: [retryUnknown, ownQueue],
});

// Scenarios -------------------------------------------------------------------------------------

const aPrompt = defineScenario("A prompt from the MacBook", {
  description: "Leo types on the MacBook; the Studio's Pi writes the prompt and its reply, and the MacBook shows both from its copy.",
  run(s) {
    s.act(s.the(MacBookPi), "prompt");
    s.settle();
  },
});

const studioAsleep = defineScenario("The Studio is asleep", {
  description: "Nothing is queued in the cloud: the text comes back to Leo's editor with \"The Studio is offline\".",
  run(s) {
    s.act(s.the(StudioAxod), "sleep");
    s.deliver(s.the(HostDO), Offline);
    s.act(s.the(MacBookPi), "prompt");
    s.settle({ until: (w) => w.the(MacBookPi).state.returned.size > 0 });
    s.settle();
  },
});

const lostReply = defineScenario("The reply is lost", {
  description: "The Studio runs the prompt but its reply never reaches the HostDO. The outcome is unknown; the MacBook sends it again with the same commandId, and pi-axo answers without prompting Pi twice.",
  run(s) {
    s.act(s.the(MacBookPi), "prompt");
    s.settle({ until: (w) => w.the(StudioPi).state.log.length > 0 });
    s.deliver(s.the(StudioAxod), BridgeReply);
    s.step(s.the(HostDO), "replyLost");
    s.settle();
  },
});

const promptDuringATurn = defineScenario("A prompt during a turn, then a stop", {
  description: "The Studio is busy with a prompt typed there. Leo's prompt waits in pi-axo, not in Pi's steering queue, so Leo's stop ends the turn and his prompt runs next instead of landing in the Studio's editor.",
  run(s) {
    s.act(s.the(StudioPi), "localPrompt");
    s.settle({ until: (w) => runningTurn(w.the(MacBookPi).state.entries) !== null });
    s.act(s.the(MacBookPi), "prompt");
    s.settle({ until: (w) => w.the(StudioPi).state.held.length > 0 || w.the(StudioPi).state.steering.length > 0 });
    s.act(s.the(MacBookPi), "stop");
    s.settle();
  },
});

const studioBusy = defineScenario("The Studio is busy", {
  description: "A turn typed on the Studio is running, and the MacBook's pane shows it running. The checker explores on from here: prompts and stops during a turn.",
  run(s) {
    s.act(s.the(StudioPi), "localPrompt");
    s.settle({ until: (w) => runningTurn(w.the(MacBookPi).state.entries) !== null });
  },
});

const leosTurn = defineScenario("Leo's prompt is running", {
  description: "Leo's prompt is running on the Studio and his pane shows it. The checker explores on from here: a stop that arrives after the turn it named, a retry after a lost reply.",
  run(s) {
    s.act(s.the(MacBookPi), "prompt");
    s.settle({ until: (w) => runningTurn(w.the(MacBookPi).state.entries) !== null && Object.keys(w.the(MacBookPi).state.pending).length === 0 });
  },
});

const ranButReplyLost = defineScenario("Leo's prompt ran, but its reply is lost", {
  description: "The Studio wrote Leo's prompt; its reply to the HostDO is lost. The checker explores on from here: the deadline, the retry, the Studio answering it again.",
  run(s) {
    s.act(s.the(MacBookPi), "prompt");
    s.settle({ until: (w) => w.the(StudioPi).state.log.length > 0 });
    s.deliver(s.the(StudioAxod), BridgeReply);
    s.step(s.the(HostDO), "replyLost");
  },
});

export default defineSpec({
  name: "Remote Sessions",
  description: "A Session that runs on the Studio, shown and prompted from a MacBook pane: the Studio's Pi is the only writer.",
  actors: [MacBookPi, MacBookAxod, ClientDO, HostDO, CloudCopy, StudioAxod, StudioPi],
  groups: [macbookGroup, studioGroup],
  limits: [deadline, renewal],
  rules: [commandReceipts, dedupeCommands, retryUnknown, unknownStaysUnknown, ownQueue, stopNamesTurn, restartOnCut],
  properties: [promptLandsOnce, deliveredMeansLanded, returnedNeverLands, remotePromptsStayRemote, stopEndsTheTurnShown, paneShowsTheLog, promptsResolve],
  scenarios: [aPrompt, studioAsleep, lostReply, promptDuringATurn, studioBusy, leosTurn, ranButReplyLost],
});
