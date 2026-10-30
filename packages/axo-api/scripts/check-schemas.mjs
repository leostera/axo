import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import {
  hostListResultSchema,
  hostNotificationSchema,
  hostDataEventSchema,
  hostRelayNotificationSchema,
  hostRegisterSchema,
  hostSnapshotSchema,
  hostPairingCreateResultSchema,
  hostPairingRedeemRequestSchema,
  hostPairingRedeemResultSchema,
  hostV1Methods,
  hostV1Results,
} from "../dist/v1.js";
import { desiredSessionGraphSchema, stateSessionViewSchema, workspaceGraphSchema, fragmentSchema, discardSchema, MAX_FRAGMENTS } from "../dist/index.js";

const schemaRoot = resolve(import.meta.dirname, "../../../schemas/axo.leostera.dev/v1");
const ajv = new Ajv2020({ allErrors: true, strict: true, strictTypes: false });
addFormats(ajv, { mode: "full" });

const schemaNames = [
  "common.schema.json",
  "events.schema.json",
  "local-rpc.schema.json",
  "host-relay.schema.json",
  "pairing.schema.json",
  "connections.schema.json",
];
for (const name of schemaNames) {
  const schema = JSON.parse(await readFile(resolve(schemaRoot, name), "utf8"));
  ajv.addSchema(schema);
}

const validateWith = (schemaID, value) => {
  const validate = ajv.getSchema(schemaID);
  assert.ok(validate, `missing schema ${schemaID}`);
  assert.equal(validate(value), true, `${schemaID}: ${ajv.errorsText(validate.errors)}`);
};

const workspaceId = crypto.randomUUID();
const sessionId = crypto.randomUUID();
const piPaneId = crypto.randomUUID();
const terminalPaneId = crypto.randomUUID();
const validWorkspaceGraph = {
  workspace: {
    workspaceId,
    name: "Axo",
    directory: "/projects/axo",
    lifecycle: "open",
    configRevision: 0,
  },
  initialSession: {
    session: {
      sessionId,
      workspaceId,
      name: "Session 1",
      manualName: false,
      lifecycle: "open",
      configRevision: 0,
      layout: {
        kind: "split",
        id: crypto.randomUUID(),
        direction: "right",
        ratio: 0.5,
        first: { kind: "pane", paneId: piPaneId },
        second: { kind: "pane", paneId: terminalPaneId },
      },
    },
    panes: [
      { paneId: piPaneId, sessionId, role: { kind: "pi" }, present: true, ordinal: 0, configRevision: 0 },
      { paneId: terminalPaneId, sessionId, role: { kind: "accountShell" }, present: true, ordinal: 1, configRevision: 0 },
    ],
  },
};
assert.equal(workspaceGraphSchema.safeParse(validWorkspaceGraph).success, true, "Workspace creation starts with Pi and a terminal");
const standaloneGraph = structuredClone(validWorkspaceGraph.initialSession);
standaloneGraph.session.workspaceId = null;
standaloneGraph.session.layout = { kind: "pane", paneId: terminalPaneId };
standaloneGraph.panes = [
  { paneId: terminalPaneId, sessionId, role: { kind: "accountShell" }, present: true, ordinal: 0, configRevision: 0 },
];
assert.equal(desiredSessionGraphSchema.safeParse(standaloneGraph).success, true, "Workspace-less Sessions are one home terminal pane");
const invalidStandaloneGraph = structuredClone(standaloneGraph);
invalidStandaloneGraph.panes = [];
assert.equal(desiredSessionGraphSchema.safeParse(invalidStandaloneGraph).success, false, "a Workspace-less Session cannot be empty");
const standaloneView = {
  session: standaloneGraph.session,
  panes: standaloneGraph.panes.map(desired => ({ desired, availability: "materializing", lastRuntime: null, terminal: null })),
  readiness: "materializing",
};
assert.equal(stateSessionViewSchema.safeParse(standaloneView).success, true, "observed home Sessions remain valid without a Pi pane");
const missingPiGraph = structuredClone(validWorkspaceGraph);
missingPiGraph.initialSession.panes[0].role = { kind: "profileShell", profileId: "zsh" };
assert.equal(workspaceGraphSchema.safeParse(missingPiGraph).success, false, "a session requires exactly one Pi pane");
const agentOnlyGraph = structuredClone(validWorkspaceGraph);
agentOnlyGraph.initialSession.panes = agentOnlyGraph.initialSession.panes.slice(0, 1);
agentOnlyGraph.initialSession.session.layout = { kind: "pane", paneId: piPaneId };
assert.equal(workspaceGraphSchema.safeParse(agentOnlyGraph).success, true, "a terminal pane is optional");
const multipleTerminalGraph = structuredClone(validWorkspaceGraph);
const secondTerminalPaneId = crypto.randomUUID();
multipleTerminalGraph.initialSession.panes.push({
  paneId: secondTerminalPaneId,
  sessionId,
  role: { kind: "accountShell" },
  present: true,
  ordinal: 2,
  configRevision: 0,
});
multipleTerminalGraph.initialSession.session.layout.second = {
  kind: "split",
  id: crypto.randomUUID(),
  direction: "down",
  ratio: 0.5,
  first: { kind: "pane", paneId: terminalPaneId },
  second: { kind: "pane", paneId: secondTerminalPaneId },
};
assert.equal(workspaceGraphSchema.safeParse(multipleTerminalGraph).success, false, "a session has at most one terminal pane");
const duplicatePiGraph = structuredClone(validWorkspaceGraph);
duplicatePiGraph.initialSession.panes[1].role = { kind: "pi" };
assert.equal(desiredSessionGraphSchema.safeParse(duplicatePiGraph.initialSession).success, false, "a session cannot contain multiple Pi panes");
const invalidLayoutGraph = structuredClone(validWorkspaceGraph);
invalidLayoutGraph.initialSession.session.layout.second.paneId = crypto.randomUUID();
assert.equal(desiredSessionGraphSchema.safeParse(invalidLayoutGraph.initialSession).success, false, "layout leaves must match each present pane exactly once");
const validSessionView = {
  session: validWorkspaceGraph.initialSession.session,
  panes: validWorkspaceGraph.initialSession.panes.map(desired => ({
    desired,
    availability: "materializing",
    lastRuntime: null,
    terminal: null,
  })),
  readiness: "materializing",
};
assert.equal(stateSessionViewSchema.safeParse(validSessionView).success, true, "observed sessions retain the required Pi pane");
const agentOnlyView = structuredClone(validSessionView);
agentOnlyView.session.layout = { kind: "pane", paneId: piPaneId };
agentOnlyView.panes = agentOnlyView.panes.slice(0, 1);
assert.equal(stateSessionViewSchema.safeParse(agentOnlyView).success, true, "observed sessions can omit the optional terminal pane");
const invalidSessionView = structuredClone(validSessionView);
invalidSessionView.panes[0].desired.role = { kind: "accountShell" };
assert.equal(stateSessionViewSchema.safeParse(invalidSessionView).success, false, "invalid observed sessions cannot omit the Pi pane");
const foreignPaneGraph = structuredClone(validWorkspaceGraph);
foreignPaneGraph.initialSession.panes[1].sessionId = crypto.randomUUID();
assert.equal(desiredSessionGraphSchema.safeParse(foreignPaneGraph.initialSession).success, false, "panes cannot cross session ownership");
const mismatchedWorkspaceGraph = structuredClone(validWorkspaceGraph);
mismatchedWorkspaceGraph.initialSession.session.workspaceId = crypto.randomUUID();
assert.equal(workspaceGraphSchema.safeParse(mismatchedWorkspaceGraph).success, false, "initial session must belong to its Workspace");
const relativeWorkspaceGraph = structuredClone(validWorkspaceGraph);
relativeWorkspaceGraph.workspace.directory = "projects/axo";
assert.equal(workspaceGraphSchema.safeParse(relativeWorkspaceGraph).success, false, "Workspace roots must be absolute host-local paths");
const closedWorkspaceGraph = structuredClone(validWorkspaceGraph);
closedWorkspaceGraph.workspace.lifecycle = "archived";
assert.equal(workspaceGraphSchema.safeParse(closedWorkspaceGraph).success, false, "Workspace creation starts open");

const fixture = async (name) =>
  JSON.parse(await readFile(resolve(schemaRoot, "fixtures", name), "utf8"));

const localCallSchema = "https://schemas.axo.leostera.dev/v1/local-rpc.schema.json#/$defs/Call";
validateWith(localCallSchema, await fixture("session-list.call.json"));
validateWith(localCallSchema, await fixture("negotiate.call.json"));
validateWith(localCallSchema, await fixture("events-next.call.json"));
validateWith(localCallSchema, await fixture("terminal-input.local.call.json"));
validateWith(localCallSchema, await fixture("terminal-resize.local.call.json"));
validateWith(localCallSchema, await fixture("client-viewport-set.local.call.json"));
validateWith(localCallSchema, await fixture("remote-access-status.call.json"));
validateWith(localCallSchema, await fixture("remote-access-connect.call.json"));
validateWith(localCallSchema, await fixture("config.get.call.json"));
validateWith(localCallSchema, await fixture("config.set.agent.call.json"));
validateWith(localCallSchema, await fixture("config.set.shell.call.json"));
validateWith(
  "https://schemas.axo.leostera.dev/v1/local-rpc.schema.json#/$defs/ConfigValueResult",
  await fixture("config.value.agent.json"),
);
validateWith(
  "https://schemas.axo.leostera.dev/v1/local-rpc.schema.json#/$defs/ConfigValueResult",
  await fixture("config.value.shell.json"),
);
validateWith(
  "https://schemas.axo.leostera.dev/v1/local-rpc.schema.json#/$defs/NegotiateResult",
  await fixture("negotiate.result.json"),
);
validateWith(
  "https://schemas.axo.leostera.dev/v1/events.schema.json#/$defs/Notification",
  await fixture("session-snapshot.event.json"),
);
validateWith(
  "https://schemas.axo.leostera.dev/v1/events.schema.json#/$defs/Notification",
  await fixture("terminal-output.event.json"),
);
validateWith(
  "https://schemas.axo.leostera.dev/v1/events.schema.json#/$defs/HostNotification",
  await fixture("host-session-snapshot.event.json"),
);
validateWith(
  "https://schemas.axo.leostera.dev/v1/local-rpc.schema.json#/$defs/EventsNextResult",
  { event: null },
);
validateWith(
  "https://schemas.axo.leostera.dev/v1/local-rpc.schema.json#/$defs/EventsNextResult",
  { events: [{ type: "subscription.lagged" }] },
);
validateWith(
  "https://schemas.axo.leostera.dev/v1/events.schema.json#/$defs/LocalEvent",
  {
    type: "relay.status",
    status: {
      state: "connected",
      connectedSinceUnixMillis: 1792000000000,
      hostName: "Test Mac",
      hostKind: "macos",
      lastError: null,
    },
  },
);
validateWith(localCallSchema, {
  jsonrpc: "2.0",
  id: 1,
  method: "axo.shell.busy",
  params: { sessionId: 1, shellId: 2 },
});
validateWith(
  "https://schemas.axo.leostera.dev/v1/local-rpc.schema.json#/$defs/ShellBusyResult",
  { busy: true, foregroundProcess: "sleep" },
);
validateWith(localCallSchema, {
  jsonrpc: "2.0",
  id: 1,
  method: "axo.session.events.next",
  params: { subscriptionId: "00000000-0000-4000-8000-000000000001", timeoutMs: 15000, maxEvents: 64 },
});
validateWith(
  "https://schemas.axo.leostera.dev/v1/local-rpc.schema.json#/$defs/SessionListResult",
  await fixture("session-list.result.json"),
);
validateWith(
  "https://schemas.axo.leostera.dev/v1/local-rpc.schema.json#/$defs/RemoteAccessStatusResult",
  await fixture("remote-access-status.result.json"),
);
validateWith(
  "https://schemas.axo.leostera.dev/v1/local-rpc.schema.json#/$defs/RemoteAccessConnectResult",
  await fixture("remote-access-connect.result.json"),
);
const hostList = await fixture("host-list.result.json");
validateWith(
  "https://schemas.axo.leostera.dev/v1/host-relay.schema.json#/$defs/HostListResult",
  hostList,
);
assert.equal(hostListResultSchema.safeParse(hostList).success, true, "Zod must match the offline host fixture");
const register = await fixture("host-register.call.json");
assert.equal(hostRegisterSchema.safeParse(register.params).success, true, "registration fixture must satisfy runtime validation");
const duplicateHostCapability = structuredClone(register.params);
duplicateHostCapability.capabilities.push(duplicateHostCapability.capabilities[0]);
assert.equal(hostRegisterSchema.safeParse(duplicateHostCapability).success, false, "host capability IDs must be unique");
const hostEvent = await fixture("host-session-snapshot.event.json");
assert.equal(hostNotificationSchema.safeParse(hostEvent).success, true, "client host events must satisfy runtime validation");
const relayHostEvent = await fixture("host-session-snapshot.relay.event.json");
validateWith(
  "https://schemas.axo.leostera.dev/v1/events.schema.json#/$defs/HostRelayNotification",
  relayHostEvent,
);
assert.equal(hostRelayNotificationSchema.safeParse(relayHostEvent).success, true, "Axod host events must satisfy runtime validation");
const relayPiEvent = await fixture("host-pi-event.relay.json");
validateWith(
  "https://schemas.axo.leostera.dev/v1/events.schema.json#/$defs/HostRelayNotification",
  relayPiEvent,
);
assert.equal(hostRelayNotificationSchema.safeParse(relayPiEvent).success, true, "Pi events must satisfy host relay runtime validation");
assert.equal(hostDataEventSchema.safeParse(relayPiEvent.params).success, true, "Pi event payloads must satisfy host event validation");
const mismatchedOwner = structuredClone(hostList.hosts[0]);
mismatchedOwner.sessions[0].hostId = crypto.randomUUID();
assert.equal(hostSnapshotSchema.safeParse(mismatchedOwner).success, false, "host sessions must reference their owning host");
const falselyFresh = structuredClone(hostList.hosts[0]);
falselyFresh.status = "offline";
falselyFresh.stale = false;
assert.equal(hostSnapshotSchema.safeParse(falselyFresh).success, false, "offline hosts must be explicitly stale");
const fragment = await fixture("transport-fragment.relay.json");
validateWith("https://schemas.axo.leostera.dev/v1/connections.schema.json#/$defs/TransportFragment", fragment);
assert.equal(fragmentSchema.safeParse(fragment).success, true, "Zod must accept the fragment fixture");
assert.equal(MAX_FRAGMENTS, 46, "the schema's fragment bounds must match the runtime's");
const oversizedFragment = structuredClone(fragment);
oversizedFragment.params.count = MAX_FRAGMENTS + 1;
assert.equal(fragmentSchema.safeParse(oversizedFragment).success, false, "too many fragments are refused at runtime");
assert.equal(ajv.getSchema("https://schemas.axo.leostera.dev/v1/connections.schema.json#/$defs/TransportFragment")(oversizedFragment), false, "and by the schema");
const discard = await fixture("transport-discard.relay.json");
validateWith("https://schemas.axo.leostera.dev/v1/connections.schema.json#/$defs/TransportDiscard", discard);
assert.equal(discardSchema.safeParse(discard).success, true, "Zod must accept the discard fixture");
const remoteCreate = await fixture("host-session-create.call.json");
const hostCallSchema = "https://schemas.axo.leostera.dev/v1/host-relay.schema.json#/$defs/Call";
validateWith(hostCallSchema, remoteCreate);
validateWith(hostCallSchema, await fixture("host-register.call.json"));
validateWith(hostCallSchema, await fixture("terminal-input.call.json"));
validateWith(hostCallSchema, await fixture("session-prompt.call.json"));
validateWith(hostCallSchema, await fixture("session-key.call.json"));
const validateHostCall = ajv.getSchema(hostCallSchema);
remoteCreate.params.target.hostId = "not-a-uuid";
assert.equal(validateHostCall(remoteCreate), false, "malformed host identities must be rejected");
const missingParams = await fixture("terminal-input.call.json");
delete missingParams.params;
assert.equal(validateHostCall(missingParams), false, "control calls require their parameters");
const extraField = await fixture("host-session-create.call.json");
extraField.params.unscopedSessionId = 9;
assert.equal(validateHostCall(extraField), false, "host-scoped calls reject unscoped fields");
const pairingSchema = "https://schemas.axo.leostera.dev/v1/pairing.schema.json#/$defs/";
const createPairing = await fixture("host-pairing-create.result.json");
validateWith(`${pairingSchema}HostPairingCreateResult`, createPairing);
assert.equal(hostPairingCreateResultSchema.safeParse(createPairing).success, true);
const redeemPairing = await fixture("host-pairing-redeem.call.json");
validateWith(`${pairingSchema}HostPairingRedeemRequest`, redeemPairing);
assert.equal(hostPairingRedeemRequestSchema.safeParse(redeemPairing).success, true);
const invalidCredential = { ...redeemPairing, credential: "not-a-host-credential" };
assert.equal(hostPairingRedeemRequestSchema.safeParse(invalidCredential).success, false);
const redeemResult = await fixture("host-pairing-redeem.result.json");
validateWith(`${pairingSchema}HostPairingRedeemResult`, redeemResult);
assert.equal(hostPairingRedeemResultSchema.safeParse(redeemResult).success, true);

const unknownConfigKey = await fixture("config.get.call.json");
unknownConfigKey.params.key = "arbitrary.database.key";
assert.equal(
  ajv.getSchema(localCallSchema)(unknownConfigKey),
  false,
  "configuration RPC only accepts known typed keys",
);

const parity = await fixture("remote-parity.json");
for (const name of parity.required) {
  assert.ok(name in hostV1Methods, `${name} is promised remotely but has no v1 parameters`);
  assert.ok(name in hostV1Results, `${name} is promised remotely but has no v1 result`);
}
for (const name of parity.planned) {
  assert.ok(!(name in hostV1Methods), `${name} exists: move it from planned to required in remote-parity.json and the Rust table`);
}

console.log(`Validated ${schemaNames.length} v1 schemas, pairing fixtures, and Workspace/Session invariants.`);
