// Regenerates schemas/axo.leostera.dev/v1/fixtures/pi3-vectors.json from pi3-session.jsonl: `npx tsx scripts/pi3-vectors.ts`.
import { readFileSync, writeFileSync } from "node:fs";
import { Pi3Transcript } from "../src/pi3.ts";

const [header, ...lines] = readFileSync(new URL("../../../schemas/axo.leostera.dev/v1/fixtures/pi3-session.jsonl", import.meta.url), "utf8").trimEnd().split("\n");
const transcript = await Pi3Transcript.start(header!);
for (const line of lines) if (!(await transcript.push(line))) throw new Error(`invalid line: ${line}`);
const vectors = {
  headerHash: transcript.headerHash,
  records: transcript.records.map(({ position, id, hash, chain }) => ({ position, id, hash, chain })),
  count: transcript.count,
  chain: transcript.chain,
  heads: transcript.heads,
};
writeFileSync(new URL("../../../schemas/axo.leostera.dev/v1/fixtures/pi3-vectors.json", import.meta.url), `${JSON.stringify(vectors, null, 2)}\n`);
