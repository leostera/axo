import assert from "node:assert/strict";
import { test } from "node:test";
import { LIMITS } from "@axo/protocol";
import { hostListResultSchema } from "@axo/protocol/v1";
import { harness, signIn } from "./harness";

/** An account links at most LIMITS.machines Macs, and lists the ones it links now. */

type AccountStub = {
  createPairing(codeVerifier: string, pairingId: string, now: number, expiresAt: number): Promise<string>;
  redeemPairing(input: Record<string, unknown>): Promise<{ status: string }>;
  revokeHost(hostId: string, now?: number): Promise<void>;
};

test("a revoked Mac linked again takes a place among the account's Macs", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const session = await signIn(h);
  const namespace = await h.mf.getDurableObjectNamespace("TEST_ACCOUNTS") as unknown as { idFromName(name: string): unknown; get(id: unknown): AccountStub };
  const account = namespace.get(namespace.idFromName(session.accountId));

  // Each code is issued an hour after the last, within the account's issuance limit.
  let now = Date.now();
  const link = async (hostId: string) => {
    now += 2 * 60 * 60 * 1000;
    const codeVerifier = crypto.randomUUID();
    const pairingId = crypto.randomUUID();
    assert.equal(await account.createPairing(codeVerifier, pairingId, now, now + 60_000), "created");
    return (await account.redeemPairing({
      codeVerifier, pairingId, hostId, hostGeneration: crypto.randomUUID(), credentialId: crypto.randomUUID(),
      credentialVerifier: crypto.randomUUID(), label: "Mac", hostKind: "macos", now,
    })).status;
  };

  const hosts = Array.from({ length: LIMITS.machines }, () => crypto.randomUUID());
  for (const hostId of hosts) assert.equal(await link(hostId), "linked");
  await account.revokeHost(hosts[0]!, now);
  assert.equal(await link(crypto.randomUUID()), "linked", "the revoked Mac's place is free");
  assert.equal(await link(hosts[0]!), "invalid", "and is no longer the revoked Mac's");

  const listed = hostListResultSchema.parse(await (await fetch(new URL("api/v1/account/hosts", h.url), { headers: session.headers })).json()).hosts;
  assert.equal(listed.length, LIMITS.machines);
  assert.ok(!listed.some((host) => host.hostId === hosts[0]), "the revoked Mac is not listed");
});
