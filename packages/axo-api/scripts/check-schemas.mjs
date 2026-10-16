import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import {
  hostListResultSchema,
  hostNotificationSchema,
  hostRelayNotificationSchema,
  hostRegisterSchema,
  hostSnapshotSchema,
  hostPairingCreateResultSchema,
  hostPairingRedeemRequestSchema,
  hostPairingRedeemResultSchema,
} from "../dist/v1.js";

const schemaRoot = resolve(import.meta.dirname, "../../../schemas/axo.leostera.dev/v1");
const ajv = new Ajv2020({ allErrors: true, strict: true, strictTypes: false });
addFormats(ajv, { mode: "full" });

const schemaNames = [
  "common.schema.json",
  "events.schema.json",
  "local-rpc.schema.json",
  "host-relay.schema.json",
  "pairing.schema.json",
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

const fixture = async (name) =>
  JSON.parse(await readFile(resolve(schemaRoot, "fixtures", name), "utf8"));

const localCallSchema = "https://schemas.axo.leostera.dev/v1/local-rpc.schema.json#/$defs/Call";
validateWith(localCallSchema, await fixture("session-list.call.json"));
validateWith(localCallSchema, await fixture("negotiate.call.json"));
validateWith(localCallSchema, await fixture("events-next.call.json"));
validateWith(localCallSchema, await fixture("terminal-input.local.call.json"));
validateWith(localCallSchema, await fixture("terminal-resize.local.call.json"));
validateWith(localCallSchema, await fixture("remote-access-settings.call.json"));
validateWith(localCallSchema, await fixture("remote-access-status.call.json"));
validateWith(localCallSchema, await fixture("remote-access-connect.call.json"));
validateWith(localCallSchema, await fixture("remote-access-configure.call.json"));
validateWith(localCallSchema, await fixture("remote-access-disable.call.json"));
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
  "https://schemas.axo.leostera.dev/v1/local-rpc.schema.json#/$defs/SessionListResult",
  await fixture("session-list.result.json"),
);
validateWith(
  "https://schemas.axo.leostera.dev/v1/local-rpc.schema.json#/$defs/RemoteAccessSettingsResult",
  await fixture("remote-access-settings.result.json"),
);
validateWith(
  "https://schemas.axo.leostera.dev/v1/local-rpc.schema.json#/$defs/RemoteAccessStatusResult",
  await fixture("remote-access-status.result.json"),
);
validateWith(
  "https://schemas.axo.leostera.dev/v1/local-rpc.schema.json#/$defs/RemoteAccessConnectResult",
  await fixture("remote-access-connect.result.json"),
);
validateWith(
  "https://schemas.axo.leostera.dev/v1/local-rpc.schema.json#/$defs/RemoteAccessDisableResult",
  await fixture("remote-access-disable.result.json"),
);
const hostList = await fixture("host-list.result.json");
validateWith(
  "https://schemas.axo.leostera.dev/v1/host-relay.schema.json#/$defs/HostListResult",
  hostList,
);
assert.equal(hostListResultSchema.safeParse(hostList).success, true, "Zod must match the offline host fixture");
const register = await fixture("host-register.call.json");
assert.equal(hostRegisterSchema.safeParse(register.params).success, true, "registration fixture must satisfy runtime validation");
const hostEvent = await fixture("host-session-snapshot.event.json");
assert.equal(hostNotificationSchema.safeParse(hostEvent).success, true, "client host events must satisfy runtime validation");
const relayHostEvent = await fixture("host-session-snapshot.relay.event.json");
validateWith(
  "https://schemas.axo.leostera.dev/v1/events.schema.json#/$defs/HostRelayNotification",
  relayHostEvent,
);
assert.equal(hostRelayNotificationSchema.safeParse(relayHostEvent).success, true, "Axod host events must satisfy runtime validation");
const mismatchedOwner = structuredClone(hostList.hosts[0]);
mismatchedOwner.sessions[0].hostId = crypto.randomUUID();
assert.equal(hostSnapshotSchema.safeParse(mismatchedOwner).success, false, "host sessions must reference their owning host");
const falselyFresh = structuredClone(hostList.hosts[0]);
falselyFresh.status = "offline";
falselyFresh.stale = false;
assert.equal(hostSnapshotSchema.safeParse(falselyFresh).success, false, "offline hosts must be explicitly stale");
const remoteCreate = await fixture("host-session-create.call.json");
const hostCallSchema = "https://schemas.axo.leostera.dev/v1/host-relay.schema.json#/$defs/Call";
validateWith(hostCallSchema, remoteCreate);
validateWith(hostCallSchema, await fixture("host-register.call.json"));
validateWith(hostCallSchema, await fixture("terminal-input.call.json"));
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

const invalidRelayConfiguration = await fixture("remote-access-configure.call.json");
invalidRelayConfiguration.params.clientSecret = "unexpected";
assert.equal(
  ajv.getSchema(localCallSchema)(invalidRelayConfiguration),
  false,
  "relay configuration must not accept app-level Access credentials",
);

console.log(`Validated ${schemaNames.length} v1 schemas and pairing request/result fixtures.`);
