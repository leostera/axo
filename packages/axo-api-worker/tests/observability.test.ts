import { test } from "node:test";
import assert from "node:assert/strict";
import { clientKind, recordApiEvent } from "../src/observability";

test("an event is logged as its static fields alone, and its type admits no others", () => {
  const captured: string[] = [];
  const original = console.info;
  console.info = (value) => captured.push(String(value));
  try {
    recordApiEvent({ event: "host_call", outcome: "timeout" });
  } finally {
    console.info = original;
  }
  assert.deepEqual(JSON.parse(captured[0]), { event: "host_call", outcome: "timeout" });
  if (false) {
    // @ts-expect-error Credentials cannot be part of the event contract.
    recordApiEvent({ event: "host_registered", token: "must-not-log" });
    // @ts-expect-error A host call has no "executed" outcome: a reply is not proof the call ran.
    recordApiEvent({ event: "host_call", outcome: "executed" });
  }
});

test("a client's kind comes from its id's prefix, and the id itself is never kept", () => {
  assert.equal(clientKind("host-38b053a6-5b91-4dad-bbcf-2d2cbc9f0509"), "peer");
  assert.equal(clientKind("ios-0123456789abcdef"), "phone");
  assert.equal(clientKind("tab-0123456789"), "web");
  assert.equal(clientKind("0123456789ab"), "web");
});
