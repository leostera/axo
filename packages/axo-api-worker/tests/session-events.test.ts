import assert from "node:assert/strict";
import { test } from "node:test";
import { randomToken } from "../src/auth/crypto";
import { Peer } from "../testing/client";
import { hostDataEventSchema, hostPairingCreateResultSchema, hostPairingRedeemResultSchema } from "@axo/protocol/v1";
import { harness, signIn } from "./harness";

const hostId = "d9b73fd0-c826-43fd-8d95-459fb9a7267f";
const hostGeneration = "104f1de4-6b07-4278-a23b-1e1ee1fe9fd5";
const sessionId = "00000017-0000-4000-8000-000000000017";

test("Pi host events reach account-private durable history and the authenticated owner route", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const owner = await signIn(h);
  const { accountId, headers } = owner;

  const pairingResponse = await fetch(new URL("api/v1/account/host-pairings", h.url), {
    method: "POST",
    headers,
  });
  assert.equal(pairingResponse.status, 200);
  const pairingCode = hostPairingCreateResultSchema.parse(await pairingResponse.json()).code;
  const credential = randomToken();
  const credentialId = crypto.randomUUID();
  const redeemResponse = await fetch(new URL("api/v1/host-pairings/redeem", h.url), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      code: pairingCode,
      hostId,
      hostGeneration,
      credentialId,
      credential,
      label: "Pi event test host",
      hostKind: "macos",
    }),
  });
  assert.equal(redeemResponse.status, 200);
  assert.equal(hostPairingRedeemResultSchema.parse(await redeemResponse.json()).hostId, hostId);

  const daemon = await Peer.connectAccountHost(h.url, accountId, hostId, "daemon", {
    Authorization: `Bearer ${credential}`,
    "X-Axo-Credential-Id": credentialId,
  });
  t.after(() => daemon.close());
  await daemon.negotiate();
  const session = {
    hostId,
    sessionId,
    shells: [],
    layout: null,
    updatedAt: new Date().toISOString(),
  };
  const registration = await daemon.call("axo.host.register", {
    protocolVersion: 2,
    hostId,
    hostGeneration,
    label: "Pi event test host",
    hostKind: "macos",
    sessions: [session],
  });
  assert.ok("result" in registration);

  const piPayload = {
    type: "host.data",
    hostId,
    hostGeneration,
    event: {
      type: "pi.event",
      sessionId,
      piSessionId: "pi-session-bound-to-one-file",
      streamId: crypto.randomUUID(),
      sequence: 1,
      name: "message_end",
      data: { role: "assistant", text: "stored without redaction", toolInput: { path: "/private/example" } },
    },
  };
  const validPiEvent = hostDataEventSchema.parse(piPayload);
  daemon.send({ jsonrpc: "2.0", method: "axo.host.event", params: validPiEvent });

  const eventsUrl = new URL(`api/v1/account/hosts/${hostId}/sessions/${sessionId}/events`, h.url);
  let eventsResponse: Response | undefined;
  for (let attempt = 0; attempt < 40; attempt += 1) {
    eventsResponse = await fetch(eventsUrl, { headers });
    if (eventsResponse.status === 200 && (await eventsResponse.clone().json() as { events: unknown[] }).events.length > 0) break;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  assert.equal(eventsResponse?.status, 200);
  assert.equal(eventsResponse?.headers.get("Cache-Control"), "private, no-store");
  const page = await eventsResponse!.json() as { events: Array<{ data: unknown; hostGeneration: string; sequence: number }>; next: number | null };
  assert.equal(page.events.length, 1);
  assert.equal(page.events[0]!.hostGeneration, hostGeneration);
  assert.equal(page.events[0]!.sequence, 1);
  assert.deepEqual(page.events[0]!.data, piPayload.event.data);
  assert.equal(page.next, null);

  const unauthenticated = await fetch(eventsUrl);
  assert.equal(unauthenticated.status, 401);
  const invalidPage = await fetch(new URL(`${eventsUrl}?before=01`, h.url), { headers });
  assert.equal(invalidPage.status, 400);

  const other = await signIn(h);
  const crossAccount = await fetch(eventsUrl, { headers: other.headers });
  assert.equal(crossAccount.status, 404);
});
