import { defineConfig } from "cf/config";

export default defineConfig({
  accountId: "0f436d2aabf1f872be90b8dd9d5715e6",
  worker: {
    name: "axo-app",
    compatibilityDate: "2026-10-16",
    domains: ["app.axo.leostera.dev"],
    workersDev: false,
    previewUrls: false,
    assets: {
      notFoundHandling: "single-page-application",
    },
    observability: {
      enabled: true,
      redactQueryString: true,
      logs: { enabled: true },
      traces: { enabled: true, headSamplingRate: 1 },
    },
  },
});
