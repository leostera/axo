import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { localMethods, remoteMethods, results } from "@axo/protocol";

test("host health is a closed local-only observation, not execution or cloud authority", () => {
  const target = { machineId: randomUUID(), hostGeneration: randomUUID() };
  assert.ok(!Object.hasOwn(remoteMethods, "axo.host.get"));
  assert.ok(localMethods["axo.host.get"].safeParse({ target }).success);
  assert.ok(!localMethods["axo.host.get"].safeParse({ target, restart: true }).success);
  const metadata = { ...target, hostname: "Test Mac", machineType: "Mac Studio", daemonVersion: "0.1.0 (test)", cloud: { kind: "notConfigured" } };
  assert.ok(results["axo.host.get"].safeParse(metadata).success);
  assert.ok(results["axo.host.get"].safeParse({ ...metadata, cloud: { kind: "online", leaseId: randomUUID(), expiresAt: Date.now() + 30000 } }).success);
  assert.ok(!results["axo.host.get"].safeParse({ ...metadata, cloud: { kind: "online" } }).success);
  assert.ok(!results["axo.host.get"].safeParse({ ...metadata, cloud: { kind: "offline", leaseId: randomUUID() } }).success);
  assert.ok(!results["axo.host.get"].safeParse({ ...metadata, credentials: "not authority" }).success);
});
