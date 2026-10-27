import react from "@vitejs/plugin-react";
import { cloudflare } from "@cloudflare/vite-plugin";
import { execSync } from "node:child_process";
import { defineConfig } from "vite";

/** The commit this build is from, shown on the sign-in page: "91ef481", or "91ef481+" with changes. */
function webBuild(): string {
  try {
    const commit = execSync("git rev-parse --short HEAD", { encoding: "utf8" }).trim();
    const dirty = execSync("git status --porcelain -- ../../packages/axo-web-app ../../sites/axo.leostera.dev", { encoding: "utf8" }).trim();
    return dirty ? `${commit}+` : commit;
  } catch {
    return "dev";
  }
}

export default defineConfig({
  plugins: [react(), cloudflare()],
  define: { __AXO_WEB_BUILD__: JSON.stringify(webBuild()) },
  build: {
    target: "es2022",
  },
  server: {
    host: "127.0.0.1",
    port: Number(process.env.PORT ?? 5173),
    strictPort: true,
    // The wordmark's font is shared with the apps, in the repository's assets/.
    fs: { allow: ["../.."] },
  },
});
