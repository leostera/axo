import assert from "node:assert/strict";
import { test } from "node:test";
import { requestSource } from "../src/auth/rate-limit";
import { harness, signIn } from "./harness";

/**
 * Sign-in and pairing limits count per source, so that no one can use them up for everyone: an
 * IPv6 /64 is one source, sign-in has no global limit, issuing a pairing code is limited per
 * account, and only a well-formed redemption counts against a limit.
 */

const from = (address: string) => new Request("https://axo.leostera.dev/", { headers: { "CF-Connecting-IP": address } });

test("a request's source is its IPv4 address or its IPv6 /64", () => {
  assert.equal(requestSource(from("203.0.113.9")), "203.0.113.9");
  assert.equal(requestSource(from("2001:db8:1:2:aaaa::1")), "2001:db8:1:2::/64");
  assert.equal(requestSource(from("2001:0DB8:0001:0002:ffff:ffff:ffff:ffff")), "2001:db8:1:2::/64");
  assert.equal(requestSource(from("2001:db8::1")), "2001:db8:0:0::/64");
  assert.equal(requestSource(from("::1")), "0:0:0:0::/64");
  assert.equal(requestSource(from("::ffff:192.0.2.1")), "0:0:0:0::/64");
  assert.equal(requestSource(from("2001:db8:1:2::3:4:5:6:7")), "unknown");
  assert.equal(requestSource(from("2001:db8::1::2")), "unknown");
  assert.equal(requestSource(new Request("https://axo.leostera.dev/")), "unknown");
});

test("addresses in one IPv6 /64 share a sign-in limit", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const start = (address: string) =>
    fetch(new URL("api/auth/cloudflare/start", h.url), { redirect: "manual", headers: { "CF-Connecting-IP": address } });
  const statuses: number[] = [];
  for (let i = 0; i < 21; i++) statuses.push((await start(`2001:db8:5:6:${(i + 1).toString(16)}::1`)).status);
  assert.deepEqual(statuses.slice(0, 20), Array(20).fill(302), statuses.join());
  assert.equal(statuses[20], 429, "the 21st address of the /64 is the same source");
  assert.equal((await start("2001:db8:5:7::1")).status, 302, "the next /64 is not");
});

test("one account's pairing codes do not use up another's", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const accounts = await Promise.all(Array.from({ length: 8 }, () => signIn(h)));
  for (const session of accounts) {
    for (let i = 0; i < 3; i++) {
      const created = await fetch(new URL("api/v1/account/host-pairings", h.url), { method: "POST", headers: session.headers });
      assert.equal(created.status, 200, `account ${session.accountId}, code ${i}`);
    }
  }
});

test("a malformed redemption counts against no limit", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const headers = { "Content-Type": "application/json", "CF-Connecting-IP": "198.51.100.7" };
  const redeem = (body: string) => fetch(new URL("api/v1/host-pairings/redeem", h.url), { method: "POST", headers, body });
  for (let i = 0; i < 20; i++) assert.equal((await redeem("{}")).status, 400);
  const wellFormed = JSON.stringify({
    code: "ABCD-EFGH",
    hostId: crypto.randomUUID(),
    hostGeneration: crypto.randomUUID(),
    credentialId: crypto.randomUUID(),
    credential: "a".repeat(43),
    label: "Test Mac",
    hostKind: "macos",
  });
  const answer = await redeem(wellFormed);
  assert.notEqual(answer.status, 429, "the source's limit is untouched");
  assert.deepEqual(await answer.json(), { error: "Pairing code is invalid or expired" }, "it was looked up");
});
