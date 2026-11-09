import assert from "node:assert/strict";
import { test } from "node:test";
import { metaParamsSchema } from "../src/session-sync.ts";

const metadata = {
  name: "Relay backoff", emoji: null, folderName: "axo",
  hasAgent: true, createdAt: 1, lastMessageAt: 2, archived: false,
};

test("a Mac that has not read its workspace yet, or an older one, sends no workspaceState", () => {
  assert.ok(metaParamsSchema.safeParse({ sessionId: "8f8f8f8f-0000-4000-8000-000000000001", metadataVersion: 1, metadata }).success);
});

test("the workspace state axod reads is taken as it is sent (RFD0022)", () => {
  // As crates/axo-relay serializes WorkspaceState.
  const workspaceState = {
    path: "/Users/leo/src/axo/crates", repoRoot: "/Users/leo/src/axo", remote: "https://github.com/leostera/axo.git",
    branch: "feat/relay-backoff", head: "3f2c1aa0c0ffee3f2c1aa0c0ffee3f2c1aa0c0ff", upstreamHead: null,
    dirty: ["crates/axo-relay/src/relay.rs"], dirtyMore: 0, at: 1_762_000_000,
  };
  const parsed = metaParamsSchema.parse({ sessionId: "8f8f8f8f-0000-4000-8000-000000000001", metadataVersion: 2, metadata: { ...metadata, workspaceState } });
  assert.deepEqual(parsed.metadata.workspaceState, workspaceState);
  const outside = { ...workspaceState, repoRoot: null, remote: null, branch: null, head: null, dirty: [] };
  assert.ok(metaParamsSchema.safeParse({ sessionId: "8f8f8f8f-0000-4000-8000-000000000001", metadataVersion: 3, metadata: { ...metadata, workspaceState: outside } }).success);
  assert.equal(metaParamsSchema.safeParse({ sessionId: "8f8f8f8f-0000-4000-8000-000000000001", metadataVersion: 3, metadata: { ...metadata, workspaceState: { ...workspaceState, head: "HEAD" } } }).success, false);
});
