import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { pathToFileURL } from "node:url";
import { Peer } from "../testing/client";
import { harness, signIn } from "./harness";
import { FakeTranscript, connectClient, connectHost, pairHost, userMessage } from "./account-support";

/**
 * The Worker as built now, answering the clients people have installed: the Mac (axod) and the
 * phone and web clients of the shipped release. `SHIPPED_PROTOCOL` names a copy of that release's
 * `packages/axo-api/src` (tools/cd/build.sh extracts it from the commit cdn/latest.json names).
 *
 * Every request here must be one the shipped schemas accept, so it is one a shipped client could
 * send; every answer must parse with the shipped schemas. A field the shipped schemas don't know
 * is allowed: axod's serde and the apps' decoders ignore unknown fields. Anything else (a field
 * gone, renamed, or of another type; an outcome the shipped client can't read) fails.
 *
 * Without `SHIPPED_PROTOCOL` the test is skipped, except in Workers Builds (`WORKERS_CI=1`).
 */

const shipped = process.env.SHIPPED_PROTOCOL;

type Schema = { safeParse(value: unknown): { success: true } | { success: false; error: { issues: Array<{ code: string; path: PropertyKey[]; message: string }> } } };

/** Parses `value` as the shipped client would: unknown keys are fine, anything else is not. */
function readsAs(schema: Schema, value: unknown, what: string): void {
  const parsed = schema.safeParse(value);
  if (parsed.success) return;
  const real = parsed.error.issues.filter((issue) => issue.code !== "unrecognized_keys");
  if (real.length === 0) return;
  assert.fail(`${what}: the shipped client can't read this answer: ${JSON.stringify(real)}\n${JSON.stringify(value)}`);
}

/** Checks that `value` is a request the shipped client could send: its schemas accept it as it is. */
function sentBy(schema: Schema, value: unknown, what: string): unknown {
  const parsed = schema.safeParse(value);
  assert.ok(parsed.success, `${what}: not a request the shipped client sends: ${parsed.success ? "" : JSON.stringify(parsed.error.issues)}`);
  return value;
}

// Continuous delivery never skips it (tools/cd/build.sh): there, no shipped protocol is a failure.
const required = process.env.WORKERS_CI === "1";

test("the shipped Mac and apps read every answer of a sync, a cut and a client's reads", { skip: !shipped && !required ? "SHIPPED_PROTOCOL is not set" : false }, async (t) => {
  assert.ok(shipped && existsSync(join(shipped, "index.ts")), `SHIPPED_PROTOCOL must name the shipped release's packages/axo-api/src, not ${shipped}`);
  const s = (await import(pathToFileURL(join(shipped!, "index.ts")).href)) as Record<string, Schema>;
  const h = await harness();
  t.after(() => h.close());
  const session = await signIn(h);
  const host = await pairHost(h, session);
  const daemon = await connectHost(h, session, host);
  t.after(() => daemon.close());
  const transcript = await FakeTranscript.create();
  for (let n = 0; n < 4; n++) await transcript.write(userMessage(`line ${n}`));

  const ask = async (peer: Peer, method: string, params: unknown, request: string, result: string) => {
    sentBy(s[request]!, params, method);
    const reply = await peer.call(method, params);
    assert.ok("result" in reply, `${method}: ${JSON.stringify(reply)}`);
    readsAs(s[result]!, reply.result, method);
    return reply.result as Record<string, unknown>;
  };
  const sync = (round: number) => ask(daemon, "axo.host.sync", { hostId: host.hostId, hostGeneration: host.hostGeneration, round, sessions: [transcript.manifestRow()] }, "hostSyncParamsSchema", "hostSyncResultSchema");

  await sync(1);
  await ask(daemon, "axo.host.session.append", { sessionId: transcript.sessionId, epoch: 1, from: 1, header: transcript.transcript.header, records: transcript.records(1) }, "appendParamsSchema", "appendResultSchema");
  await sync(2);
  await ask(daemon, "axo.host.session.chainAt", { sessionId: transcript.sessionId, round: 2, positions: [0, 2, 4] }, "chainAtParamsSchema", "chainAtResultSchema");
  await ask(daemon, "axo.host.session.meta", { sessionId: transcript.sessionId, metadataVersion: 2, metadata: transcript.manifestRow(2, { name: "Renamed" }).metadata }, "metaParamsSchema", "metaResultSchema");
  const cut = await ask(daemon, "axo.host.session.truncate", { sessionId: transcript.sessionId, round: 2, keep: 2, expectedChain: transcript.transcript.chainAt(2) }, "truncateParamsSchema", "truncateResultSchema");
  assert.equal(cut.outcome, "truncated");
  await sync(3);

  // The phone and the browser: hello, open, and a page back.
  const { client, clientId } = await connectClient(h, session);
  t.after(() => client.close());
  await ask(client, "axo.client.hello", { protocolVersion: 2, clientId }, "clientHelloParamsSchema", "clientHelloResultSchema");
  const opened = await ask(client, "axo.client.session.open", { hostId: host.hostId, sessionId: transcript.sessionId }, "clientOpenParamsSchema", "clientOpenResultSchema");
  assert.ok(Array.isArray(opened.records));
});
