import { test } from "node:test";
import assert from "node:assert/strict";
import { harness, Peer } from "./harness";
import { accessHeaders } from "../testing/access-headers";
import { machineListResultSchema } from "@axo/protocol";

test("Hono machines GET needs no Worker JWT and reports live presence without caching", async t => {
  const h = await harness(); t.after(() => h.close());
  const endpoint = new URL("v1/machines/", h.url);
  assert.equal((await fetch(endpoint)).status, 200);
  assert.equal((await fetch(endpoint, { headers: accessHeaders(await h.token("daemon")) })).status, 200);
  const headers = accessHeaders(await h.token("client"));
  assert.equal((await fetch(endpoint, { method: "POST", headers })).status, 405);
  const machineId = crypto.randomUUID(), hostGeneration = crypto.randomUUID();
  const daemon = await Peer.connect(h.url, await h.token("daemon"), machineId, "daemon");
  await daemon.negotiate();
  const registered = await daemon.call("axo.machine.register", { protocolVersion: 1, machineId, hostGeneration, label: "Metadata-only HTTP fixture" });
  assert.ok("result" in registered);
  const response = await fetch(endpoint, { headers });
  assert.equal(response.status, 200);
  assert.match(response.headers.get("Cache-Control") ?? "", /no-store/);
  const result = machineListResultSchema.parse(await response.json());
  assert.deepEqual(result.machines, [{ machineId, hostGeneration, label: "Metadata-only HTTP fixture", online: true }]);
  await daemon.close();
  const offline = machineListResultSchema.parse(await (await fetch(endpoint, { headers })).json());
  assert.equal(offline.machines[0].online, false);
  assert.equal(offline.machines[0].hostGeneration, null);
});
