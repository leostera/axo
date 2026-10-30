// Writes assets/mascot/axo.riv. With --check, fails if the committed file is out of date.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { buildMascot } from "./mascot.ts";

const output = resolve(import.meta.dirname, "../../../assets/mascot/axo.riv");
const bytes = buildMascot();

if (process.argv.includes("--check")) {
  const committed = readFileSync(output);
  if (!Buffer.from(bytes).equals(committed)) {
    console.error(`${output} is out of date: run npm run build in packages/axo-mascot`);
    process.exit(1);
  }
} else {
  mkdirSync(dirname(output), { recursive: true });
  writeFileSync(output, bytes);
  console.log(`wrote ${output} (${bytes.length} bytes)`);
}
