import { build } from "esbuild";
import { lstat, mkdir, unlink, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export async function installLegacyEntrypoint(outputDirectory) {
  const legacyPath = join(outputDirectory, "extension.mjs");
  const existing = await lstat(legacyPath).catch(error => {
    if (error.code === "ENOENT") return undefined;
    throw error;
  });
  if (existing && !existing.isDirectory()) await unlink(legacyPath);
  await mkdir(legacyPath, { recursive: true });
  // Existing Pi processes retain this CLI path. Directory discovery selects
  // index.ts, escaping Node's cached .mjs URL without restarting the session.
  await writeFile(join(legacyPath, "index.ts"), 'export { default } from "../extension.ts";\n');
}

async function buildBridge() {
  const root = fileURLToPath(new URL("../", import.meta.url));
  const outputDirectory = join(root, "bridge/dist");
  // Pi/Jiti reloads .ts modules; moduleCache:false does not evict native .mjs.
  await build({
    entryPoints: [join(root, "bridge/extension.ts")],
    bundle: true, platform: "node", format: "esm", packages: "external",
    outfile: join(outputDirectory, "extension.ts"), logLevel: "info",
  });
  await build({
    entryPoints: [join(root, "bridge/host-main.ts")],
    bundle: true, platform: "node", format: "esm", packages: "external",
    outfile: join(outputDirectory, "host-broker.mjs"), logLevel: "info",
  });
  await installLegacyEntrypoint(outputDirectory);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await buildBridge();
}
