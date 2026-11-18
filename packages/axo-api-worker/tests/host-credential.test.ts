import assert from "node:assert/strict";
import { test } from "node:test";
import { randomToken } from "../src/auth/crypto";
import { Peer } from "../testing/client";
import { hostListResultSchema, hostPairingCreateResultSchema } from "@axo/protocol/v1";
import { harness, signIn } from "./harness";

// RFD0074: a Mac revokes the credential it stops using, proving it with that credential.
test("a Mac revokes only its current credential, with that credential", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const session = await signIn(h);
  const { accountId } = session;
  const hostId = crypto.randomUUID();
  const link = async () => {
    const pairing = await fetch(new URL("api/v1/account/host-pairings", h.url), { method: "POST", headers: session.headers });
    const code = hostPairingCreateResultSchema.parse(await pairing.json()).code;
    const credential = { credentialId: crypto.randomUUID(), credential: randomToken() };
    const redeemed = await fetch(new URL("api/v1/host-pairings/redeem", h.url), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code, hostId, hostGeneration: crypto.randomUUID(), label: "Studio", hostKind: "macos", ...credential }),
    });
    assert.equal(redeemed.status, 200);
    return credential;
  };
  const revoke = (credential: { credentialId: string; credential: string }, extra: Record<string, string> = {}) =>
    fetch(new URL(`api/v1/accounts/${accountId}/hosts/${hostId}/credential/revoke`, h.url), {
      method: "POST",
      headers: { Authorization: `Bearer ${credential.credential}`, "X-Axo-Credential-Id": credential.credentialId, ...extra },
    });
  const listed = async () => hostListResultSchema.parse(await (await fetch(new URL("api/v1/account/hosts", h.url), { headers: session.headers })).json())
    .hosts.find(host => host.hostId === hostId);

  const replaced = await link();
  const current = await link();
  assert.equal((await revoke(replaced)).status, 401, "a credential a later link replaced revokes nothing");
  assert.equal((await revoke({ credentialId: current.credentialId, credential: randomToken() })).status, 401, "a wrong secret");
  assert.equal((await revoke(current, { Origin: "https://axo.leostera.dev" })).status, 403, "never from a page");
  const daemon = await Peer.connectHostDaemon(h.url, accountId, hostId, {
    Authorization: `Bearer ${current.credential}`,
    "X-Axo-Credential-Id": current.credentialId,
  });
  daemon.close();
  assert.ok(await listed(), "none of those revoked the Mac");

  assert.equal((await revoke(current)).status, 204);
  await assert.rejects(Peer.connectHostDaemon(h.url, accountId, hostId, {
    Authorization: `Bearer ${current.credential}`,
    "X-Axo-Credential-Id": current.credentialId,
  }));
  assert.equal((await revoke(current)).status, 401, "once revoked, it is done");
});
