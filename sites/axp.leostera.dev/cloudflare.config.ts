import { defineConfig } from "cf/config";

// Static assets only: every page is prerendered, so the Worker has no code and no bindings.
export default defineConfig({
  accountId: "0f436d2aabf1f872be90b8dd9d5715e6",
  worker: {
    name: "axp-www",
    compatibilityDate: "2026-11-02",
    workersDev: false,
    previewUrls: false,
    observability: { enabled: true, headSamplingRate: 0.01, logs: { enabled: true, headSamplingRate: 0.01 }, traces: { enabled: true, headSamplingRate: 0.01 } },
    assets: { notFoundHandling: "404-page" },
    domains: ["axp.leostera.dev"],
  },
});
