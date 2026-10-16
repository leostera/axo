import { test } from "node:test";
import assert from "node:assert/strict";
import { recordApiEvent } from "../src/observability";
import { accessHeaders } from "../testing/access-headers";

test("diagnostics contain only static metadata and never infer execution from replies", () => {
  const captured: string[] = [];
  const original = console.info;
  console.info = (value) => captured.push(String(value));
  try {
    recordApiEvent({
      event: "relay_reply",
      method: "axo.runtime.startApproved",
      outcome: "unknown",
    });
  } finally {
    console.info = original;
  }
  assert.deepEqual(JSON.parse(captured[0]), {
    event: "relay_reply",
    method: "axo.runtime.startApproved",
    outcome: "unknown",
  });
  if (false) {
    // @ts-expect-error Credentials cannot be part of the event contract.
    recordApiEvent({ event: "host_registered", token: "must-not-log" });
    recordApiEvent({
      event: "relay_reply",
      method: "axo.runtime.list",
      // @ts-expect-error Replies are not execution confirmations.
      outcome: "executed",
    });
  }
});

test("native Access headers supply the edge cookie and reject cookie/header injection", () => {
  assert.deepEqual(accessHeaders("header.payload.signature"), {
    Cookie: "CF_Authorization=header.payload.signature",
    "Cf-Access-Jwt-Assertion": "header.payload.signature",
  });
  for (const value of [
    "not-a-jwt",
    "header.payload.signature; other=value",
    "header.payload.signature\r\nSecret: value",
    "x".repeat(8193),
  ])
    assert.throws(() => accessHeaders(value), /Invalid Access/);
});
