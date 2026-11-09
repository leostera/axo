import { atMost, defineActor, defineGroup, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineVariable, defineZone } from "@leostera/feynman";

// RFD0037: the uploader waits for a cause, never for a tick.
//
// axod's uploader used to check every open Session's transcript, and reread the catalog, every
// 500ms. That delayed every record by up to half a second and woke an idle Mac twice a second.
// Now a turn runs only when something says the transcript may have changed: Pi reports an event,
// the kernel reports a write to the file or a file created in its directory (kqueue), or the last
// append committed and there may be more. There is no timer on this path at all.
//
// The hard part is that Pi's two signals are not ordered: Pi may tell axod a message ended
// before it has appended the line. A turn woken by the event then reads nothing new, and without
// the file watch the line would wait for Pi's next event, which may never come. The watch closes
// that gap only if it is registered before the file is read, and on the directory while the
// file does not exist yet.
//
// One Session, one Pi and the Session's Durable Object. The handshake, cuts and failures are
// session-sync.ts's; here every append commits.

/** The transcript on disk, and the kernel's registrations on it (knotes in axod's kqueue). */
const transcript = defineVariable("transcript", { exists: false, lines: 0 });
const watches = defineVariable("watches", { file: false, directory: false });

const LINES = 2;

// ─── Messages ───────────────────────────────────────────────────────────────────

const PiEvent = defineMessage("PiEvent", {}, { name: "agent event (message.end)", over: "Pi bridge socket" });
const Vnode = defineMessage("Vnode", {}, { name: "EVFILT_VNODE (NOTE_WRITE)", over: "kqueue" });
const Append = defineMessage("Append", { count: Number }, { name: "axo.host.sync.append", over: "websocket" });
const Committed = defineMessage("Committed", { count: Number }, { name: "append committed", over: "websocket", tone: "reply" });

// ─── Zones, rules ───────────────────────────────────────────────────────────────

const mac = defineZone({ name: "Studio", description: "Pi and axod", place: { column: 0 } });
const cloudflare = defineZone({ name: "Cloudflare", description: "RFD0018's SessionDO", place: { column: 1, region: true } });

const watchTranscript = defineRule("watchTranscript", {
  description: "axod registers EVFILT_VNODE on each open Session's transcript, so a write wakes the uploader.",
});
const watchDirectory = defineRule("watchDirectory", {
  description: "While a transcript does not exist yet, axod watches its directory, so creating it wakes the uploader.",
});
const watchBeforeRead = defineRule("watchBeforeRead", {
  description: "A turn registers its watches before it reads the files, so a write after the read is always seen.",
});

// ─── Actors ─────────────────────────────────────────────────────────────────────

export const Pi = defineActor({
  name: "Pi",
  description: "The agent. When a message ends it appends a line to its transcript and reports the event to axod, in either order.",
  zone: mac,
  singleton: true,
  initialState: () => ({ toWrite: 0, toReport: 0 }),
  display: {
    icon: "robot",
    status: (s) => (s.toWrite || s.toReport ? "finishing a message" : "idle"),
  },
  actions: {
    endMessage: {
      with: [atMost(LINES)],
      label: "End a message",
      description: "Pi finishes a message: a line to write, and an event to report.",
      run(s) {
        s.toWrite += 1;
        s.toReport += 1;
      },
    },
  },
  transitions: {
    appendLine: {
      when: (s) => s.toWrite > 0,
      description: "Pi appends the line, creating the file for the first one. The kernel posts a vnode event for each registration it touches.",
      uses: [transcript, watches],
      sends: [Vnode],
      run(s, _m, ctx) {
        s.toWrite -= 1;
        const file = ctx.get(transcript);
        const watched = ctx.get(watches);
        const created = !file.exists;
        ctx.set(transcript, { exists: true, lines: file.lines + 1 });
        if ((watched.file && !created) || (watched.directory && created)) ctx.send(ctx.the(Axod), Vnode, {});
      },
    },
    reportEvent: {
      when: (s) => s.toReport > 0,
      description: "Pi reports the message's end on its bridge; axod forwards Session events to the uploader.",
      sends: [PiEvent],
      run(s, _m, ctx) {
        s.toReport -= 1;
        ctx.send(ctx.the(Axod), PiEvent, {});
      },
    },
  },
});

export const Axod = defineActor({
  name: "axod",
  description: "The uploader task: it sleeps until woken, then registers its watches, reads the transcript and appends what the cloud is missing.",
  zone: mac,
  singleton: true,
  initialState: () => ({ woken: true, read: 0, sent: 0, committed: 0, inFlight: false, lateRegistration: false, turns: 0 }),
  display: {
    icon: "gear",
    status: (s) => (s.woken ? "woken" : s.inFlight ? `appending ${s.sent}` : `asleep, ${s.committed} uploaded`),
    mood: (s) => (s.woken || s.inFlight ? "busy" : "ok"),
  },
  transitions: {
    piEvent: {
      on: PiEvent,
      description: "A Session event (anything but a streaming update) wakes the uploader.",
      sources: ["crates/axo-relay/src/relay/session.rs#forward_event"],
      run: (s) => void (s.woken = true),
    },
    vnode: {
      on: Vnode,
      description: "The kqueue became readable: the transcript, or its directory, changed.",
      run: (s) => void (s.woken = true),
    },
    turn: {
      when: (s) => s.woken && !s.inFlight,
      description: "One turn: register the watches, read the file to its end, and append the lines the cloud lacks.",
      uses: [transcript, watches],
      sends: [Append],
      run(s, _m, ctx) {
        s.woken = false;
        s.turns += 1;
        const register = () => {
          const file = ctx.get(transcript);
          ctx.set(watches, { file: watchTranscript.on && file.exists, directory: watchDirectory.on && !file.exists });
        };
        if (watchBeforeRead.on) register();
        else s.lateRegistration = true;
        const file = ctx.get(transcript);
        s.read = file.exists ? file.lines : 0;
        if (s.read > s.committed) {
          s.sent = s.read;
          s.inFlight = true;
          ctx.send(ctx.the(SessionDO), Append, { count: s.sent });
        }
      },
    },
    registerLate: {
      when: (s) => s.lateRegistration,
      description: "Without watchBeforeRead: the watches are registered after the file was read.",
      uses: [transcript, watches],
      run(s, _m, ctx) {
        s.lateRegistration = false;
        const file = ctx.get(transcript);
        ctx.set(watches, { file: watchTranscript.on && file.exists, directory: watchDirectory.on && !file.exists });
      },
    },
    committed: {
      on: Committed,
      description: "The append committed. There may be more on disk, so the next turn runs at once.",
      run(s, m) {
        s.inFlight = false;
        s.committed = m.count;
        s.woken = true;
      },
    },
  },
});

export const SessionDO = defineActor({
  name: "SessionDO",
  description: "The Session's Durable Object: it keeps the lines and acknowledges each append.",
  zone: cloudflare,
  singleton: true,
  initialState: () => ({ count: 0 }),
  display: { icon: "database", status: (s) => `${s.count} lines` },
  transitions: {
    append: {
      on: Append,
      description: "Commits the batch.",
      sends: [Committed],
      run(s, m, ctx) {
        s.count = Math.max(s.count, m.count);
        ctx.reply(Committed, { count: s.count });
      },
    },
  },
});

// ─── Properties ─────────────────────────────────────────────────────────────────

const everyLineReachesTheCloud = defineProperty("everyLineReachesTheCloud", {
  description: "Every line Pi writes ends up in the cloud, with no timer to fall back on, whichever of Pi's two signals comes first.",
  leadsTo: {
    whenever: (w) => w.get(transcript).lines > w.the(SessionDO).state.count,
    then: (w) => w.get(transcript).lines === w.the(SessionDO).state.count,
  },
  needs: [watchTranscript, watchDirectory, watchBeforeRead],
});

const neverAheadOfTheFile = defineProperty("neverAheadOfTheFile", {
  description: "The cloud never holds more than the file does.",
  always: (w) => w.the(SessionDO).state.count <= w.get(transcript).lines,
});

const settlesAsleep = defineProperty("settlesAsleep", {
  description: "Once Pi is done and everything is uploaded, the uploader goes to sleep: no turn runs without a cause.",
  leadsTo: {
    whenever: (w) => w.the(Pi).state.toWrite === 0 && w.the(Pi).state.toReport === 0 && w.the(SessionDO).state.count === w.get(transcript).lines,
    then: (w) => !w.the(Axod).state.woken && !w.the(Axod).state.inFlight,
  },
});

// ─── Scenarios ──────────────────────────────────────────────────────────────────

const reportsFirst = defineScenario("Pi reports before it writes", {
  description: "The event wakes a turn that finds no new line; the write that follows wakes the next one through the file watch.",
  run(s) {
    s.settle({ until: (w) => !w.the(Axod).state.woken });
    s.act(s.the(Pi), "endMessage");
    s.step(s.the(Pi), "appendLine");
    s.settle({ until: (w) => w.the(SessionDO).state.count === 1 && !w.the(Axod).state.woken });
    s.act(s.the(Pi), "endMessage");
    s.step(s.the(Pi), "reportEvent");
    s.deliver(s.the(Axod), PiEvent);
    s.step(s.the(Axod), "turn");
    s.step(s.the(Pi), "appendLine");
    s.settle({ until: (w) => w.the(SessionDO).state.count === 2 });
  },
});

const writesFirst = defineScenario("Pi writes before it reports", {
  description: "The usual order: the write and the event each wake the uploader, and one turn uploads the line.",
  run(s) {
    s.settle({ until: (w) => !w.the(Axod).state.woken });
    s.act(s.the(Pi), "endMessage");
    s.step(s.the(Pi), "appendLine");
    s.step(s.the(Pi), "reportEvent");
    s.settle({ until: (w) => w.the(SessionDO).state.count === 1 && !w.the(Axod).state.woken });
  },
});

const firstLine = defineScenario("The first line creates the file", {
  description: "axod watches the directory until the transcript exists, so its creation wakes the uploader even with Pi's event long gone.",
  run(s) {
    s.settle({ until: (w) => !w.the(Axod).state.woken && w.get(watches).directory });
    s.act(s.the(Pi), "endMessage");
    s.step(s.the(Pi), "reportEvent");
    s.deliver(s.the(Axod), PiEvent);
    s.step(s.the(Axod), "turn");
    s.step(s.the(Pi), "appendLine");
    s.settle({ until: (w) => w.the(SessionDO).state.count === 1 });
  },
});

export default defineSpec({
  name: "Upload wakes",
  description: "What wakes axod's uploader: Pi's events, the kernel's file events and its own commits. Never a timer.",
  actors: [Pi, Axod, SessionDO],
  groups: [defineGroup({ name: "Studio", actors: [Pi, Axod], icon: "laptop", collapsed: false })],
  properties: [everyLineReachesTheCloud, neverAheadOfTheFile, settlesAsleep],
  scenarios: [reportsFirst, writesFirst, firstLine],
});
