// How the WhatsApp app's Baileys is bundled for Workers (RFD0016, Linked devices), for the site's
// Vite build and the Worker tests' esbuild alike:
//
// - `ws`, which Baileys connects with, is ws.ts: the same API over the Workers WebSocket.
// - Its optional media packages (sharp, jimp, link-preview-js, audio-decode) are unavailable.ts;
//   Baileys imports them only when it makes thumbnails and link previews, and catches the failure.
// - whatsapp-rust-bridge, its Signal crypto, compiles WebAssembly it carries as base64 when it
//   loads. Workers never compile WebAssembly at run time, so the module is taken out into a .wasm
//   file the bundle imports, which Workers compile when the Worker is deployed.
// - Its `derivePairingCodeKey` is pairing-key.ts: Baileys asks Web Crypto for more PBKDF2
//   iterations than Workers allow.
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const WS_SHIM = fileURLToPath(new URL("./src/apps/whatsapp/workers/ws.ts", import.meta.url));
const UNAVAILABLE = fileURLToPath(new URL("./src/apps/whatsapp/workers/unavailable.ts", import.meta.url));
const PAIRING_KEY = fileURLToPath(new URL("./src/apps/whatsapp/workers/pairing-key.ts", import.meta.url));
const OPTIONAL = new Set(["sharp", "jimp", "link-preview-js", "audio-decode"]);

/**
 * The bridge, beside Baileys in its node_modules: where `vite dev`'s pre-bundled Baileys imports
 * it from, which the site (in Bazel's node_modules, holding only what it declares) cannot find.
 */
function bridgePath() {
  let directory = dirname(fileURLToPath(import.meta.resolve("baileys")));
  while (!directory.endsWith(`${"/"}baileys`) && dirname(directory) !== directory) directory = dirname(directory);
  const path = join(directory, "..", "whatsapp-rust-bridge", "dist", "index.js");
  if (!existsSync(path)) throw new Error(`whatsapp-rust-bridge is not beside Baileys (${path}); update packages/axo-apps/bundling.mjs`);
  return path;
}

const isBaileysCrypto = (id) => /[\\/]baileys[\\/]lib[\\/]Utils[\\/]crypto\.js(\?|$)/.test(id);
const PAIRING_KEY_DEFINITION = "export async function derivePairingCodeKey(";

/** Baileys' Utils/crypto.js with its `derivePairingCodeKey` taken from pairing-key.ts. */
export function withPairingKey(source, path) {
  if (!source.includes(PAIRING_KEY_DEFINITION)) throw new Error(`Baileys changed derivePairingCodeKey (${path}); update packages/axo-apps/bundling.mjs`);
  return `export { derivePairingCodeKey } from ${JSON.stringify(PAIRING_KEY)};\n${source.replace(PAIRING_KEY_DEFINITION, "async function baileysDerivePairingCodeKey(")}`;
}

const inBaileys = (importer) => /[\\/]baileys[\\/]/.test(importer ?? "");
const isBridge = (id) => /[\\/]whatsapp-rust-bridge[\\/]dist[\\/]index\.js(\?|$)/.test(id);

/** What an import from Baileys resolves to instead, if anything. */
function replaced(source, importer) {
  if (!inBaileys(importer)) return null;
  if (source === "ws") return WS_SHIM;
  if (OPTIONAL.has(source)) return UNAVAILABLE;
  return null;
}

/**
 * The bridge's code without its base64 WebAssembly, importing it from `wasmImport` instead, and
 * the WebAssembly itself (the SIMD build: Workers' V8 has SIMD).
 */
export async function bridge(path, wasmImport) {
  const source = await readFile(path, "utf8");
  const start = source.indexOf("var forceNoSimd");
  const end = source.indexOf("var __wasmSimdActive");
  const simd = start >= 0 && end > start ? /tryInit\("([A-Za-z0-9+/=]+)"\)/.exec(source.slice(start, end)) : null;
  if (!simd) throw new Error(`whatsapp-rust-bridge changed how it loads its WebAssembly (${path}); update packages/axo-apps/bundling.mjs`);
  const wasm = Buffer.from(simd[1], "base64");
  const code = `import __axoBridgeWasm from ${JSON.stringify(wasmImport)};\n${source.slice(0, start)}initSync({ module: __axoBridgeWasm });\nvar simdUsed = true;\n${source.slice(end)}`;
  return { code, wasm };
}

/**
 * The Vite plugin, for the site's build: the .wasm file goes where Cloudflare's plugin uploads it
 * from. In `vite dev` the Worker's dependencies are pre-bundled first, without the site's plugins:
 * there Baileys' imports are replaced too, and the bridge is left out, to load as in the build.
 */
export function whatsappVite() {
  return {
    name: "axo-whatsapp",
    enforce: "pre",
    configEnvironment(name) {
      if (name === "client") return;
      return {
        optimizeDeps: {
          exclude: ["whatsapp-rust-bridge"],
          rolldownOptions: { plugins: [{ name: "axo-whatsapp-prebundle", resolveId: (source, importer) => replaced(source, importer) }] },
        },
      };
    },
    resolveId(source, importer) {
      if (source === "whatsapp-rust-bridge") return bridgePath();
      return replaced(source, importer);
    },
    async load(id) {
      if (isBaileysCrypto(id)) {
        const path = id.split("?")[0];
        return withPairingKey(await readFile(path, "utf8"), path);
      }
      if (!isBridge(id)) return null;
      const directory = join(tmpdir(), "axo-whatsapp-bridge");
      const path = id.split("?")[0];
      const { wasm } = await bridge(path, "");
      const file = join(directory, `${createHash("sha256").update(wasm).digest("hex").slice(0, 16)}.wasm`);
      await mkdir(directory, { recursive: true });
      await writeFile(file, wasm);
      return (await bridge(path, file)).code;
    },
  };
}

/** The esbuild plugin, for the Worker tests: the .wasm file is written to `wasmDir`, beside the bundle, as `whatsapp-bridge.wasm`. */
export function whatsappEsbuild({ wasmDir }) {
  return {
    name: "axo-whatsapp",
    setup(build) {
      build.onResolve({ filter: /^(ws|sharp|jimp|link-preview-js|audio-decode)$/ }, (args) => {
        const path = replaced(args.path, args.importer);
        return path ? { path } : undefined;
      });
      build.onResolve({ filter: /^\.\/whatsapp-bridge\.wasm$/ }, (args) => ({ path: args.path, external: true }));
      build.onLoad({ filter: /[\\/]baileys[\\/]lib[\\/]Utils[\\/]crypto\.js$/ }, async (args) => ({
        contents: withPairingKey(await readFile(args.path, "utf8"), args.path),
        loader: "js",
      }));
      build.onLoad({ filter: /whatsapp-rust-bridge[\\/]dist[\\/]index\.js$/ }, async (args) => {
        const { code, wasm } = await bridge(args.path, "./whatsapp-bridge.wasm");
        await mkdir(wasmDir, { recursive: true });
        await writeFile(join(wasmDir, "whatsapp-bridge.wasm"), wasm);
        return { contents: code, loader: "js" };
      });
    },
  };
}
