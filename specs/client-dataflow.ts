import { atMost, budget, crash, defineActor, defineMessage, defineProperty, defineScenario, defineSpec, defineZone, listOf, lose } from "@leostera/feynman";

type Directory = { sessions: string[]; subscribers: string[] };
type Host = { sessions: string[]; workspaces: string[]; registered: boolean; ready: boolean };
type Client = { sessions: string[]; workspaces: string[]; subscribed: boolean };

/** Faults on one path: lost messages and crashes (RFD0012). `--set faults=2` raises it. */
const faults = budget("faults", 1);

const Register = defineMessage("Register", { sessions: listOf(String) }, { name: "axo.host.register (session snapshots)", over: "websocket" });
const Registered = defineMessage("Registered", {}, { name: "registration stored", over: "websocket", tone: "reply" });
const ListSessions = defineMessage("ListSessions", {}, { name: "GET /api/v1/account/hosts/:host/sessions", over: "https" });
const Sessions = defineMessage("Sessions", { sessions: listOf(String) }, { name: "stored session snapshots", over: "https", tone: "reply" });
const Subscribe = defineMessage("Subscribe", { client: String }, { name: "axo.host.subscribe", over: "websocket" });
const Subscribed = defineMessage("Subscribed", {}, { name: "subscription accepted", over: "websocket", tone: "reply" });
const HostSessionChanged = defineMessage("HostSessionChanged", { session: String }, { name: "session snapshot event from axod", over: "websocket" });
const SessionChanged = defineMessage("SessionChanged", { session: String }, { name: "live session event", over: "websocket", tone: "stream" });
const ListWorkspaces = defineMessage("ListWorkspaces", {}, { name: "axo.remote.workspace.list", over: "websocket" });
const ReadWorkspaces = defineMessage("ReadWorkspaces", {}, { name: "workspace list request to axod", over: "websocket" });
const Workspaces = defineMessage("Workspaces", { workspaces: listOf(String) }, { name: "workspace list from axod", over: "websocket", tone: "reply" });
const WorkspaceResult = defineMessage("WorkspaceResult", { workspaces: listOf(String) }, { name: "workspace list returned to client", over: "websocket", tone: "reply" });


const cloud = defineZone({ name: "Cloudflare", description: "per-account Durable Object and API" });
const mac = defineZone({ name: "Host Mac", description: "local axod state" });
const phoneZone = defineZone({ name: "Client", description: "Axo app" });

export const Account = defineActor({
  name: "AxoAccountManager",
  description: "Stores host/session snapshots and relays live client traffic.",
  zone: cloud,
  singleton: true,
  initialState: (): Directory => ({ sessions: [], subscribers: [] }),
  display: {
    icon: "database",
    status: (s) => `${s.sessions.length} stored session snapshot(s)`,
    mood: () => "info",
    rows: (s) => s.sessions.map((session) => ({ label: "session snapshot", detail: session, mood: "info" })),
  },
  transitions: {
    register: {
      on: Register,
      description: "Saves the snapshots axod supplied when it registered.",
      sources: ["crates/axo-relay/src/relay.rs#run_connection", "packages/axo-api-worker/src/axo-host-relay.ts#registerHost", "packages/axo-api-worker/src/auth/account-manager.ts#storeHostRegistration"],
      sends: [Registered],
      run(state, msg, ctx) {
        state.sessions = [...msg.sessions];
        ctx.reply(Registered, {});
      },
    },
    listSessions: {
      on: ListSessions,
      description: "Returns the last session snapshots saved for this host; it does not query axod.",
      sources: ["packages/axo-api-worker/src/http/account-hosts.ts#serveAccountHostSessions", "packages/axo-api-worker/src/auth/account-manager.ts:280-288"],
      sends: [Sessions],
      run(state, _msg, ctx) {
        ctx.reply(Sessions, { sessions: [...state.sessions] });
      },
    },
    subscribe: {
      on: Subscribe,
      description: "Keeps this client subscribed to events for the connected host.",
      sources: ["packages/axo-api-worker/src/axo-host-relay.ts#subscribeHost"],
      sends: [Subscribed],
      run(state, msg, ctx) {
        if (!state.subscribers.includes(msg.client)) state.subscribers.push(msg.client);
        ctx.reply(Subscribed, {});
      },
    },
    hostSessionChanged: {
      on: HostSessionChanged,
      description: "Stores the new session snapshot and forwards the event to subscribed clients.",
      sources: ["packages/axo-api-worker/src/axo-host-relay.ts#receiveHostEvent", "packages/axo-api-worker/src/auth/account-manager.ts#storeHostEvent"],
      sends: [SessionChanged],
      run(state, msg, ctx) {
        if (!state.sessions.includes(msg.session)) state.sessions.push(msg.session);
        for (const label of state.subscribers) {
          const client = ctx.all(Client).find((candidate) => candidate.label === label);
          if (client) ctx.send(client, SessionChanged, { session: msg.session });
        }
      },
    },
    listWorkspaces: {
      on: ListWorkspaces,
      description: "Routes this request to the live host instead of reading a workspace cache.",
      sources: ["packages/axo-api-worker/src/axo-host-relay.ts#forwardHostRemoteCall"],
      sends: [ReadWorkspaces],
      run(_state, _msg, ctx) {
        ctx.send(ctx.the(HostMac), ReadWorkspaces, {});
      },
    },
    workspaces: {
      on: Workspaces,
      description: "Returns the workspace list received from the host to the requesting client.",
      sources: ["packages/axo-api-worker/src/axo-host-relay.ts#receiveReply"],
      sends: [WorkspaceResult],
      run(_state, msg, ctx) {
        const client = ctx.all(Client)[0];
        if (client) ctx.send(client, WorkspaceResult, { workspaces: [...msg.workspaces] });
      },
    },
    // Faults: what the network and restarts may do here.
    registerLost: lose(Register, { spend: faults }),
    listSessionsLost: lose(ListSessions, { spend: faults }),
    subscribeLost: lose(Subscribe, { spend: faults }),
    hostSessionChangedLost: lose(HostSessionChanged, { spend: faults }),
    listWorkspacesLost: lose(ListWorkspaces, { spend: faults }),
    workspacesLost: lose(Workspaces, { spend: faults }),
  },
});

export const HostMac = defineActor({
  name: "axod",
  description: "The host daemon; session/workspace state is sourced from its local SessionManager.",
  zone: mac,
  singleton: true,
  initialState: (): Host => ({ sessions: ["session-1"], workspaces: ["workspace-1"], registered: false, ready: false }),
  display: { icon: "server", status: (s) => `${s.sessions.length} local session(s)`, mood: () => "ok" },
  actions: {
    register: {
      with: [atMost(2)],
      label: "Register with relay",
      description: "Publishes the host's current session snapshots to the account service.",
      sources: ["crates/axo-server/src/session/handlers.rs#remote_session_snapshots", "crates/axo-relay/src/relay.rs#run_connection"],
      when: (state) => !state.registered,
      sends: [Register],
      run: (state, _input, ctx) => {
        state.registered = true;
        ctx.send(ctx.the(Account), Register, { sessions: [...state.sessions] });
      },
    },
    changeSession: {
      with: [atMost(2)],
      label: "Change session state",
      description: "Publishes an updated session snapshot from the host.",
      sources: ["crates/axo-server/src/session/events.rs#publish_event", "crates/axo-relay/src/relay.rs#relay_session"],
      when: (state) => state.ready,
      sends: [HostSessionChanged],
      run: (state, _input, ctx) => {
        const session = `session-${state.sessions.length + 1}`;
        state.sessions.push(session);
        ctx.send(ctx.the(Account), HostSessionChanged, { session });
      },
    },
    readWorkspaces: {
      with: [atMost(2)],
      label: "Answer workspace request",
      description: "Reads workspaces from the host's local session manager and replies.",
      sources: ["crates/axo-relay/src/relay.rs#remote_request_reply", "crates/axo-server/src/session/handlers.rs#remote_workspaces"],
      sends: [Workspaces],
      run: (state, _input, ctx) => ctx.send(ctx.the(Account), Workspaces, { workspaces: [...state.workspaces] }),
    },
  },
  transitions: {
    registered: {
      on: Registered,
      description: "Registration completed; axod can now stream events on this connection.",
      sources: ["crates/axo-relay/src/relay.rs#run_connection"],
      run: (state) => { state.ready = true; },
    },
    readWorkspaces2: {
      on: ReadWorkspaces,
      description: "Answers the relayed request using host-local workspace state.",
      sources: ["crates/axo-relay/src/relay.rs#remote_request_reply", "crates/axo-server/src/session/handlers.rs#remote_workspaces"],
      sends: [Workspaces],
      run: (state, _msg, ctx) => ctx.send(ctx.the(Account), Workspaces, { workspaces: [...state.workspaces] }),
    },
    // Faults: what the network and restarts may do here.
    registeredLost: lose(Registered, { spend: faults }),
    readWorkspacesLost: lose(ReadWorkspaces, { spend: faults }),
  },
});

export const Client = defineActor({
  name: "Phone",
  description: "A native Axo client that first loads account snapshots, then follows live host events.",
  zone: phoneZone,
  display: {
    icon: "phone",
    status: (s) => s.subscribed ? "following host" : "not connected",
    mood: (s) => s.subscribed ? "ok" : "info",
    rows: (s) => [
      { label: "sessions", detail: s.sessions.join(", ") || "none", mood: "info" },
      { label: "workspaces", detail: s.workspaces.join(", ") || "not loaded", mood: "info" },
    ],
  },
  initialState: (): Client => ({ sessions: [], workspaces: [], subscribed: false }),
  actions: {
    refreshSessions: {
      with: [atMost(2)],
      label: "Load sessions",
      description: "Fetches the account's stored snapshot list over HTTPS.",
      sources: ["apple/AxoClient/Sources/AxoClient/Remote/AccountClient.swift#sessions"],
      sends: [ListSessions],
      run: (_state, _input, ctx) => ctx.send(ctx.the(Account), ListSessions, {}),
    },
    followHost: {
      with: [atMost(2)],
      label: "Follow host events",
      description: "Subscribes to live host events through the relay WebSocket.",
      sources: ["apple/AxoClient/Sources/AxoClient/Remote/HostConnection.swift#subscribe"],
      sends: [Subscribe],
      run: (_state, _input, ctx) => ctx.send(ctx.the(Account), Subscribe, { client: ctx.label }),
    },
    loadWorkspaces: {
      with: [atMost(2)],
      label: "Load workspaces",
      description: "Asks the host for its current workspace list through the relay.",
      sources: ["apple/AxoClient/Sources/AxoClient/Remote/HostConnection.swift#workspaces"],
      sends: [ListWorkspaces],
      run: (_state, _input, ctx) => ctx.send(ctx.the(Account), ListWorkspaces, {}),
    },
  },
  transitions: {
    sessions: {
      on: Sessions,
      description: "Uses the snapshot list returned by the account API.",
      sources: ["apple/AxoClient/Sources/AxoClient/Remote/AccountClient.swift#sessions"],
      run: (state, msg) => { state.sessions = [...msg.sessions]; },
    },
    subscribed: {
      on: Subscribed,
      description: "Marks the host event stream as subscribed.",
      sources: ["apple/AxoClient/Sources/AxoClient/Remote/HostConnection.swift#subscribe"],
      run: (state) => { state.subscribed = true; },
    },
    sessionChanged: {
      on: SessionChanged,
      description: "Applies the live session snapshot pushed through the relay.",
      sources: ["apple/AxoPhone/Sources/AxoPhoneModel/HostWorkbenchModel.swift#apply"],
      run: (state, msg) => { if (!state.sessions.includes(msg.session)) state.sessions.push(msg.session); },
    },
    workspaceResult: {
      on: WorkspaceResult,
      description: "Displays the workspace list returned by axod.",
      sources: ["apple/AxoPhone/Sources/AxoPhoneModel/HostWorkbenchModel.swift#refreshWorkspaces"],
      run: (state, msg) => { state.workspaces = [...msg.workspaces]; },
    },
    // Faults: what the network and restarts may do here.
    sessionsLost: lose(Sessions, { spend: faults }),
    subscribedLost: lose(Subscribed, { spend: faults }),
    sessionChangedLost: lose(SessionChanged, { spend: faults }),
    workspaceResultLost: lose(WorkspaceResult, { spend: faults }),
    crash: crash({ spend: faults }),
  },
});

const storedSnapshotsComeFromHost = defineProperty("storedSnapshotsComeFromHost", {
  description: "Every session snapshot in account storage exists in axod's local session list.",
  always: (world) => {
    const stored = world.the(Account).state.sessions;
    const hostSessions = world.the(HostMac).state.sessions;
    return stored.every((session) => hostSessions.includes(session));
  },
});
const clientSessionsComeFromAccountStorage = defineProperty("clientSessionsComeFromAccountStorage", {
  description: "Every session shown by the client is backed by an account snapshot.",
  always: (world) => {
    const stored = world.the(Account).state.sessions;
    return world.all(Client).every((client) =>
      client.state.sessions.every((session) => stored.includes(session))
    );
  },
});
const clientWorkspacesComeFromHost = defineProperty("clientWorkspacesComeFromHost", {
  description: "Every workspace shown by the client came from the host's workspace list.",
  always: (world) => {
    const hostWorkspaces = world.the(HostMac).state.workspaces;
    return world.all(Client).every((client) =>
      client.state.workspaces.every((workspace) => hostWorkspaces.includes(workspace))
    );
  },
});

const storedSessionListing = defineScenario("Stored session listing", {
  description: "axod publishes local session snapshots; the client later gets those snapshots from account storage over HTTPS.",
  run(s) {
    const host = s.the(HostMac);
    const client = s.spawn(Client, "Phone");
    s.act(host, "register");
    s.settle();
    s.act(client, "refreshSessions");
    s.settle();
  },
});

const liveWorkspaceRequest = defineScenario("Live workspace request", {
  description: "Workspace data is not read from account storage: the relay forwards the request to axod and returns its answer.",
  run(s) {
    const client = s.spawn(Client, "Phone");
    s.act(client, "loadWorkspaces");
    s.settle();
  },
});

const liveSessionUpdate = defineScenario("Live session update", {
  description: "The account service stores a host event snapshot and also pushes it to the subscribed client.",
  run(s) {
    const host = s.the(HostMac);
    const client = s.spawn(Client, "Phone");
    s.act(host, "register");
    s.settle();
    s.act(client, "refreshSessions");
    s.settle();
    s.act(client, "followHost");
    s.settle();
    s.act(host, "changeSession");
    s.settle();
  },
});

export default defineSpec({
  name: "Where client data comes from",
  description:
    "Which client data is read from the account Durable Object's stored snapshots, and which is fetched live from axod on the host.",
  actors: [Account, HostMac, Client],
  properties: [storedSnapshotsComeFromHost, clientSessionsComeFromAccountStorage, clientWorkspacesComeFromHost],
  scenarios: [storedSessionListing, liveWorkspaceRequest, liveSessionUpdate],
});
