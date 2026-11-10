/** The Vite plugin that bundles WhatsApp's Baileys for Workers (bundling.mjs). */
export function whatsappVite(): import("vite").Plugin;
/** The esbuild plugin that does the same for the Worker tests, writing the WebAssembly to `wasmDir`. */
export function whatsappEsbuild(options: { wasmDir: string }): { name: string; setup(build: unknown): void };
export function bridge(path: string, wasmImport: string): Promise<{ code: string; wasm: Buffer }>;
