import { defineConfig } from "astro/config";
import cloudflare from "@astrojs/cloudflare";
import react from "@astrojs/react";
import tailwindcss from "@tailwindcss/vite";
import { rewriteLinks } from "./src/lib/links.mjs";

// Fully prerendered and served as Workers Static Assets; the Worker is configured in cloudflare.config.ts.
export default defineConfig({
  site: "https://axp.leostera.dev",
  output: "static",
  trailingSlash: "always",
  // Prerender in Node: pages read the spec, schemas and examples from ../../axp at build time.
  // No sessions or image transforms, so the adapter adds no KV or Images bindings.
  adapter: cloudflare({ prerenderEnvironment: "node", imageService: "passthrough" }),
  session: false,
  integrations: [react()],
  markdown: {
    // The documents link to each other as files in the repository; on the site they are pages.
    remarkPlugins: [rewriteLinks],
    // Match Kumo's own code themes so prose code and example code look the same.
    shikiConfig: { themes: { light: "github-light", dark: "vesper" } },
  },
  vite: {
    plugins: [tailwindcss()],
    // The documents live in ../../axp.
    server: { fs: { allow: ["../.."] } },
  },
});
