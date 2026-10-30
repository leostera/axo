import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { publishThroughAxod } from "../src/share-command.js";
import type { SharedSnapshot } from "../src/share.js";

const snapshot: SharedSnapshot = {
  version: 1,
  title: "axo: share",
  publishedAt: "2026-10-30T00:00:00.000Z",
  messages: [{ id: "m", role: "user", text: "hi", timestamp: 1, tool: null, images: [] }],
};

/** A stand-in for Axod's socket that answers every request with `answer(request)`. */
async function fakeAxod(answer: (request: { method: string; params: unknown }) => object): Promise<{ socket: string; requests: unknown[]; close(): Promise<void> }> {
  const directory = await mkdtemp(join(tmpdir(), "pi-axo-share-"));
  const socket = join(directory, "axod.sock");
  const requests: unknown[] = [];
  const server: Server = createServer(connection => {
    let buffered = "";
    connection.on("data", chunk => {
      buffered += chunk.toString("utf8");
      const newline = buffered.indexOf("\n");
      if (newline < 0) return;
      const request = JSON.parse(buffered.slice(0, newline));
      requests.push(request);
      connection.end(`${JSON.stringify({ jsonrpc: "2.0", id: request.id, ...answer(request) })}\n`);
    });
  });
  await new Promise<void>(resolve => server.listen(socket, resolve));
  return {
    socket,
    requests,
    async close() {
      await new Promise(resolve => server.close(resolve));
      await rm(directory, { recursive: true, force: true });
    },
  };
}

test("a share is published by asking Axod, which answers with the cloud's ID and URL", async t => {
  const axod = await fakeAxod(() => ({ result: { shareId: "AAAAAAAAAAAAAAAAAAAAAA", url: "https://axo.leostera.dev/s/AAAAAAAAAAAAAAAAAAAAAA/axo-share" } }));
  t.after(() => axod.close());
  const published = await publishThroughAxod(axod.socket, snapshot);
  assert.deepEqual(published, { shareId: "AAAAAAAAAAAAAAAAAAAAAA", url: "https://axo.leostera.dev/s/AAAAAAAAAAAAAAAAAAAAAA/axo-share" });
  assert.deepEqual(axod.requests, [{ jsonrpc: "2.0", id: 1, method: "axo.session.share", params: { snapshot } }]);
});

test("Axod's refusal reaches the person verbatim", async t => {
  const axod = await fakeAxod(() => ({ error: { code: -32603, message: "this Mac is not connected to its Axo account" } }));
  t.after(() => axod.close());
  await assert.rejects(publishThroughAxod(axod.socket, snapshot), /not connected to its Axo account/);
});

test("an unexpected answer is not taken for a share", async t => {
  const axod = await fakeAxod(() => ({ result: { shareId: "../../etc", url: "http://example.com" } }));
  t.after(() => axod.close());
  await assert.rejects(publishThroughAxod(axod.socket, snapshot), /unexpected share/);
});

test("no Axod means no share", async () => {
  await assert.rejects(publishThroughAxod(join(tmpdir(), "no-such-axod.sock"), snapshot), /Could not reach Axo/);
});
