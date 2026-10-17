import assert from "node:assert/strict";
import { test } from "node:test";
import { randomToken, hmac, sealCookie } from "../src/auth/crypto";
import { Peer } from "../testing/client";
import { hostDataEventSchema, hostPairingCreateResultSchema, hostPairingRedeemResultSchema } from "@axo/protocol/v1";
import { harness } from "./harness";

const secret = "isolated-session-events-secret-at-least-32-bytes";
const accountId = "01a414a4-cc2b-4f3c-a7c4-15fd6f13b885";
const hostId = "d9b73fd0-c826-43fd-8d95-459fb9a7267f";
const hostGeneration = "104f1de4-6b07-4278-a23b-1e1ee1fe9fd5";
const sessionId = 23;

async function createAccountSession(h: Awaited<ReturnType<typeof harness>>, ownerId: string) {
  const sessionId = randomToken();
  const csrf = randomToken();
  const expiresAt = Date.now() + 60 * 60 * 1000;
  const cookie = `__Host-axo_session=${await sealCookie(secret, "web-session", { accountId: ownerId, sessionId, csrf, expiresAt })}`;
  const initialized = await fetch(new URL("api/v1/account/hosts", h.url), { headers: { Cookie: cookie } });
  assert.equal(initialized.status, 401);
  const storage = await h.mf.unsafeGetDurableObjectStorage("api-test", "AxoAccountDirectory", { name: ownerId });
  await storage.exec("INSERT INTO profile (singleton, email, name) VALUES (1, ?, ?)", "test@example.test", "Test account");
  await storage.exec(
    "INSERT INTO web_sessions (session_digest, created_at, expires_at, revoked_at) VALUES (?, ?, ?, NULL)",
    await hmac(secret, `session\0${sessionId}`), Date.now(), expiresAt,
  );
  return { cookie, csrf };
}

test("Pi host events reach account-private durable history and the authenticated owner route", async (t) => {
  const h = await harness({ bindings: { SESSION_SECRET: secret } });
  t.after(() => h.close());
  const owner = await createAccountSession(h, accountId);
  const headers = { Cookie: owner.cookie, Origin: "https://axo.leostera.dev" };

  const pairingResponse = await fetch(new URL("api/v1/account/host-pairings", h.url), {
    method: "POST",
    headers: { ...headers, "X-Axo-CSRF": owner.csrf },
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
    protocolVersion: 1,
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
  const invalidPage = await fetch(new URL(`${eventsUrl}?after=01`, h.url), { headers });
  assert.equal(invalidPage.status, 400);

  const otherAccountId = "51f820e6-4dd9-46d4-84bc-9cd7414fdceb";
  const other = await createAccountSession(h, otherAccountId);
  const crossAccount = await fetch(eventsUrl, { headers: { Cookie: other.cookie } });
  assert.equal(crossAccount.status, 404);
});
