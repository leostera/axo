import assert from "node:assert/strict";
import test from "node:test";
import { decodeJwt, decodeProtectedHeader, exportPKCS8, generateKeyPair, jwtVerify } from "jose";
import { ApnsProvider, ApnsRequestNotice, apnsDestinationSchema, type ApnsCredentials } from "../src/push/apns";

const NOW = 1_800_000_000_000;
const route = {
  accountId: "11111111-1111-4111-8111-111111111111",
  hostId: "22222222-2222-4222-8222-222222222222",
  sessionId: "33333333-3333-4333-8333-333333333333",
  requestId: "44444444-4444-4444-8444-444444444444",
};
const notice = () => new ApnsRequestNotice(route, NOW + 5 * 60_000);
const destination = () => apnsDestinationSchema.parse({ topic: "dev.leostera.axo.phone", environment: "sandbox", token: "aB".repeat(32) });
const keys = await generateKeyPair("ES256", { extractable: true });
const credentials: ApnsCredentials = {
  teamId: "TESTTEAM01", keyId: "TESTKEY001", privateKey: await exportPKCS8(keys.privateKey),
  environment: "sandbox", topics: ["dev.leostera.axo.phone"],
};

test("opaque token parsing is bounded without assuming Apple's current token length", () => {
  for (const bytes of [1, 16, 32, 64, 512, 1024]) {
    assert.equal(apnsDestinationSchema.parse({ ...destination(), token: "AB".repeat(bytes) }).token, "ab".repeat(bytes));
  }
  for (const token of ["", "a", "gg", "ab\n", "ab/../../", "ab".repeat(1025)]) {
    assert.equal(apnsDestinationSchema.safeParse({ ...destination(), token }).success, false);
  }
  assert.equal(apnsDestinationSchema.safeParse({ ...destination(), topic: "attacker.example" }).success, false);
  assert.equal(apnsDestinationSchema.safeParse({ ...destination(), environment: "staging" }).success, false);
});

test("the only payload is private generic attention and validated routing, with no answer action", () => {
  const value = notice();
  const parsed = JSON.parse(value.body);
  assert.deepEqual(parsed, {
    aps: { alert: { title: "Axo", body: "A request needs your attention." }, sound: "default", "thread-id": "axo.requests" },
    axo: { version: 1, ...route },
  });
  assert.ok(Buffer.byteLength(value.body) < 4096);
  assert.ok(Buffer.byteLength(value.collapseId) <= 64);
  assert.throws(() => new ApnsRequestNotice({ ...route, question: "secret" }, NOW));
  assert.throws(() => new ApnsRequestNotice({ ...route, requestId: "../other" }, NOW));
  assert.throws(() => new ApnsRequestNotice(route, Number.NaN));
});

test("one sandbox attempt has the correct headers and a verifiable ES256 provider JWT", async () => {
  const provider = await ApnsProvider.create(credentials, {
    now: () => NOW,
    transport: async (url, init) => {
      assert.equal(url, `https://api.sandbox.push.apple.com/3/device/${"ab".repeat(32)}`);
      assert.equal(init.method, "POST");
      assert.equal(init.redirect, "manual");
      assert.ok(init.signal instanceof AbortSignal);
      const headers = new Headers(init.headers);
      assert.equal(headers.get("apns-topic"), "dev.leostera.axo.phone");
      assert.equal(headers.get("apns-push-type"), "alert");
      assert.equal(headers.get("apns-priority"), "10");
      assert.equal(headers.get("apns-expiration"), String(Math.floor((NOW + 5 * 60_000) / 1000)));
      assert.equal(headers.get("apns-collapse-id"), route.requestId);
      assert.match(headers.get("apns-id")!, /^[a-f0-9-]{36}$/);
      assert.equal(init.body, notice().body);
      const jwt = headers.get("authorization")!.slice("bearer ".length);
      assert.deepEqual(decodeProtectedHeader(jwt), { alg: "ES256", kid: credentials.keyId });
      const verified = await jwtVerify(jwt, keys.publicKey, { issuer: credentials.teamId, algorithms: ["ES256"] });
      assert.deepEqual(verified.payload, { iss: credentials.teamId, iat: NOW / 1000 });
      return new Response(null, { status: 200 });
    },
  });
  assert.equal((await provider.send(destination(), notice())).kind, "accepted");
  assert.equal(JSON.stringify(provider), "{}", "the provider object must not serialize its signing key or JWT");
});

test("cancellation before dispatch sends nothing; an in-flight abort has an uncertain receipt", { timeout: 2000 }, async () => {
  let calls = 0;
  let started!: () => void;
  const dispatched = new Promise<void>((resolve) => { started = resolve; });
  const provider = await ApnsProvider.create(credentials, {
    now: () => NOW,
    transport: async (_url, init) => {
      calls++;
      started();
      return new Promise<Response>((_resolve, reject) => {
        init.signal!.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
      });
    },
  });
  const cancelled = new AbortController();
  cancelled.abort();
  assert.deepEqual(await provider.send(destination(), notice(), cancelled.signal), { kind: "cancelled" });
  assert.equal(calls, 0);
  const inFlight = new AbortController();
  const receipt = provider.send(destination(), notice(), inFlight.signal);
  await dispatched;
  inFlight.abort();
  assert.deepEqual(await receipt, { kind: "uncertain" });
  assert.equal(calls, 1);
});

test("aborted response reading releases its reader instead of waiting for a body forever", { timeout: 2000 }, async () => {
  let reading!: () => void;
  const started = new Promise<void>((resolve) => { reading = resolve; });
  let cancelled = false;
  const provider = await ApnsProvider.create(credentials, {
    now: () => NOW,
    transport: async () => new Response(new ReadableStream({
      pull() { reading(); },
      cancel() { cancelled = true; },
    }), { status: 410 }),
  });
  const controller = new AbortController();
  const receipt = provider.send(destination(), notice(), controller.signal);
  await started;
  controller.abort();
  assert.deepEqual(await receipt, { kind: "uncertain" });
  assert.equal(cancelled, true);
});

test("provider scope is snapshotted before async key import and parsed destinations are immutable", async () => {
  const mutable: ApnsCredentials = { ...credentials, topics: [...credentials.topics] };
  const creating = ApnsProvider.create(mutable, {
    now: () => NOW,
    transport: async (url) => { assert.match(url, /^https:\/\/api\.sandbox\.push\.apple\.com\//); return new Response(null, { status: 200 }); },
  });
  mutable.environment = "production";
  mutable.topics = ["dev.leostera.axo"];
  const provider = await creating;
  assert.equal((await provider.send(destination(), notice())).kind, "accepted");
  assert.equal(Object.isFrozen(destination()), true);
});

test("production is an explicit, separate scope and never a sandbox fallback", async () => {
  let calls = 0;
  const provider = await ApnsProvider.create({ ...credentials, environment: "production", topics: ["dev.leostera.axo"] }, {
    now: () => NOW,
    transport: async (url, init) => {
      calls++;
      assert.match(url, /^https:\/\/api\.push\.apple\.com\/3\/device\//);
      assert.equal(new Headers(init.headers).get("apns-topic"), "dev.leostera.axo");
      return new Response(null, { status: 200 });
    },
  });
  assert.deepEqual(await provider.send(destination(), notice()), { kind: "scope-mismatch" });
  assert.deepEqual(await provider.send(apnsDestinationSchema.parse({ ...destination(), environment: "production" }), notice()), { kind: "scope-mismatch" });
  assert.equal(calls, 0);
  await provider.send(apnsDestinationSchema.parse({ ...destination(), environment: "production", topic: "dev.leostera.axo" }), notice());
  assert.equal(calls, 1);
});

test("JWT reuse is single-flight, refreshed after 45 minutes, and safe after a backward clock step", async () => {
  let now = NOW;
  const jwts: string[] = [];
  const provider = await ApnsProvider.create(credentials, {
    now: () => now,
    transport: async (_url, init) => {
      jwts.push(new Headers(init.headers).get("authorization")!);
      return new Response(null, { status: 200 });
    },
  });
  const send = () => provider.send(destination(), new ApnsRequestNotice(route, now + 300_000));
  await Promise.all(Array.from({ length: 12 }, send));
  assert.equal(new Set(jwts).size, 1);
  now += 44 * 60_000;
  await send();
  assert.equal(jwts.at(-1), jwts[0]);
  now += 60_000;
  await send();
  assert.equal(decodeJwt(jwts.at(-1)!.slice(7)).iat, now / 1000);
  now = NOW - 60_000;
  await send();
  assert.equal(decodeJwt(jwts.at(-1)!.slice(7)).iat, now / 1000);
});

test("expired requests never reach transport, including expiry while obtaining the provider JWT", async () => {
  let calls = 0;
  let reads = 0;
  const provider = await ApnsProvider.create(credentials, {
    now: () => ++reads === 1 ? NOW : NOW + 600_000,
    transport: async () => { calls++; return new Response(null, { status: 200 }); },
  });
  assert.deepEqual(await provider.send(destination(), notice()), { kind: "expired" });
  assert.equal(calls, 0);
});

test("feedback distinguishes invalidation, deferred attempts, auth problems and unknown responses without retrying", async () => {
  const cases = [
    [410, "Unregistered", { kind: "invalid-token", reason: "Unregistered", invalidatedAt: NOW - 1000 }],
    [410, "ExpiredToken", { kind: "invalid-token", reason: "ExpiredToken", invalidatedAt: NOW - 1000 }],
    [400, "BadDeviceToken", { kind: "invalid-token", reason: "BadDeviceToken", invalidatedAt: NOW - 1000 }],
    [400, "DeviceTokenNotForTopic", { kind: "invalid-token", reason: "DeviceTokenNotForTopic", invalidatedAt: NOW - 1000 }],
    [429, "TooManyRequests", { kind: "deferred", reason: "TooManyRequests", notBefore: NOW + 60_000 }],
    [503, "ServiceUnavailable", { kind: "deferred", reason: "ServiceUnavailable", notBefore: NOW + 15 * 60_000 }],
    [500, "InternalServerError", { kind: "deferred", reason: "InternalServerError", notBefore: NOW + 15 * 60_000 }],
    [403, "ExpiredProviderToken", { kind: "rejected", status: 403, reason: "ExpiredProviderToken" }],
    [429, "TooManyProviderTokenUpdates", { kind: "rejected", status: 429, reason: "TooManyProviderTokenUpdates" }],
    [413, "PayloadTooLarge", { kind: "rejected", status: 413, reason: "PayloadTooLarge" }],
    [400, "a secret echoed by a broken server", { kind: "rejected", status: 400, reason: "Unknown" }],
  ] as const;
  for (const [status, reason, expected] of cases) {
    let calls = 0;
    const provider = await ApnsProvider.create(credentials, {
      now: () => NOW,
      transport: async () => { calls++; return Response.json({ reason, timestamp: NOW - 1000 }, { status }); },
    });
    assert.deepEqual(await provider.send(destination(), notice()), expected);
    assert.equal(calls, 1);
  }
});

test("malformed/oversized feedback and transport exceptions never expose arbitrary response text or token URLs", async () => {
  for (const body of ["null", "{", JSON.stringify({ reason: "Unregistered", timestamp: -1 }), "x".repeat(4097)]) {
    const provider = await ApnsProvider.create(credentials, { now: () => NOW, transport: async () => new Response(body, { status: 410 }) });
    const result = await provider.send(destination(), notice());
    assert.equal(JSON.stringify(result).includes("timestamp"), false);
    assert.equal(JSON.stringify(result).includes("xxxx"), false);
  }
  let calls = 0;
  const provider = await ApnsProvider.create(credentials, {
    now: () => NOW,
    transport: async (url) => { calls++; throw new Error(`connection failed: ${url}`); },
  });
  assert.deepEqual(await provider.send(destination(), notice()), { kind: "uncertain" });
  assert.equal(calls, 1);
  await assert.rejects(ApnsProvider.create({ ...credentials, privateKey: "secret-bad-key" }), (error: Error) => {
    assert.equal(error.message, "APNs provider key could not be imported");
    return true;
  });
});
