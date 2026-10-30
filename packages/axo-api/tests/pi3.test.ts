import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { Pi3Transcript, pi3Entry } from "../src/pi3.ts";

const fixture = (name: string) => readFileSync(new URL(`../fixtures/pi3/${name}`, import.meta.url), "utf8");

test("the fixture transcript hashes to the shared vectors", async () => {
  const vectors = JSON.parse(fixture("vectors.json"));
  const [header, ...lines] = fixture("session.jsonl").trimEnd().split("\n");
  const transcript = await Pi3Transcript.start(header!);
  for (const line of lines) assert.ok(await transcript.push(line));
  assert.equal(transcript.headerHash, vectors.headerHash);
  assert.deepEqual(transcript.records.map(({ position, id, hash, chain }) => ({ position, id, hash, chain })), vectors.records);
  assert.equal(transcript.chain, vectors.chain);
  assert.deepEqual(transcript.heads, vectors.heads);
  assert.equal(transcript.chainAt(0), vectors.headerHash);
});

test("a record's hash covers its ancestry, so the same line under another parent differs", async () => {
  const a = await Pi3Transcript.start('{"type":"session","version":3}');
  const b = await Pi3Transcript.start('{"type":"session","version":3}');
  await a.push('{"id":"p","parentId":null,"n":1}');
  await b.push('{"id":"p","parentId":null,"n":2}');
  const child = '{"id":"c","parentId":"p"}';
  assert.notEqual((await a.push(child))!.hash, (await b.push(child))!.hash);
});

test("only JSON objects are records", () => {
  assert.equal(pi3Entry("[1]"), null);
  assert.equal(pi3Entry("{\"id\":"), null);
  assert.deepEqual(pi3Entry('{"id":"x","parentId":null,"targetId":"y"}'), { id: "x", refs: [["parentId", null], ["targetId", "y"]] });
});
