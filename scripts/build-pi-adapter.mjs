import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import { writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

const outfile = process.argv[2];
if (!outfile) throw new Error("An adapter output path is required");
await build({
  entryPoints: [fileURLToPath(new URL("../pi-axo/index.ts", import.meta.url))],
  outfile,
  bundle: true,
  platform: "node",
  format: "esm",
  target: "es2022",
  // Public Pi imports are type-only today. Never bundle an execution engine.
  external: ["@earendil-works/*", "typebox"],
  metafile: true,
}).then(result => {
  if (Object.keys(result.metafile.inputs).some(path => path.includes("@earendil-works/") || path.includes("node_modules/typebox/"))) {
    throw new Error("A Pi runtime dependency entered the Axo adapter bundle");
  }
});
await writeFile(join(dirname(outfile), "package.json"), JSON.stringify({
  name: "pi-axo-control", private: true, type: "module",
  peerDependencies: { "@earendil-works/pi-coding-agent": "*", typebox: "*" },
}) + "\n");
