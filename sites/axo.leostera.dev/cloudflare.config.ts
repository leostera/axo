import { defineConfig, exports } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

export default defineConfig(({ isPreview }) => ({
  accountId: "0f436d2aabf1f872be90b8dd9d5715e6",
  worker: {
    name: isPreview ? "axo-public-app-preview" : "axo-public-app",
    compatibilityDate: "2026-10-16",
    compatibilityFlags: ["nodejs_compat", "enable_ctx_exports"],
    entrypoint,
    domains: isPreview ? [] : ["axo.leostera.dev"],
    workersDev: false,
    previewUrls: isPreview,
    assets: {
      notFoundHandling: "single-page-application",
      runWorkerFirst: ["/api", "/api/*"],
    },
    observability: {
      enabled: true,
      redactQueryString: true,
      logs: { enabled: true },
      traces: { enabled: true, headSamplingRate: 1 },
    },
    exports: {
      AxoHostDirectory: exports.durableObject({ storage: "sqlite" }),
      AxoHostRelay: exports.durableObject({ storage: "sqlite" }),
      AxoIdentityIndex: exports.durableObject({ storage: "sqlite" }),
      AxoAccountDirectory: exports.durableObject({ storage: "sqlite" }),
      AxoPairingIndex: exports.durableObject({ storage: "sqlite" }),
      AxoPairingRateLimit: exports.durableObject({ storage: "sqlite" }),
    },
  },
}));
