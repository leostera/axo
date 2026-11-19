import assert from "node:assert/strict";
import { test } from "node:test";
import { sessionMetadataSchema } from "../src/session-sync.ts";

const metadata = { name: null, emoji: null, folderName: null, hasAgent: true, createdAt: null, lastMessageAt: null, archived: false };
test("session agent is reported explicitly and old metadata remains unknown", () => {
  assert.equal(sessionMetadataSchema.parse(metadata).agent, undefined);
  for (const agent of ["pi", "codex", "opencode", "claude-code"])
    assert.equal(sessionMetadataSchema.parse({ ...metadata, agent }).agent, agent);
  assert.equal(sessionMetadataSchema.safeParse({ ...metadata, agent: "invented" }).success, false);
});
