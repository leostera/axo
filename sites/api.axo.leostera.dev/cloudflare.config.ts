import { defineConfig, exports } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

// Cloudflare Access protects this Worker at the edge; the Worker does not validate Access JWTs.
export default defineConfig({
  accountId: "0f436d2aabf1f872be90b8dd9d5715e6",
  worker: {
    name: "axo-api",
    compatibilityDate: "2026-10-09",
    compatibilityFlags: ["nodejs_compat"],
    entrypoint,
    domains: ["api.axo.leostera.dev"],
    workersDev: false,
    previewUrls: false,
    observability: {
      enabled: true,
      redactQueryString: true,
      logs: { enabled: true },
      traces: { enabled: true, headSamplingRate: 1 },
    },
    exports: {
      AxoHostDirectory: exports.durableObject({ storage: "sqlite" }),
      AxoHostRelay: exports.durableObject({ storage: "sqlite" }),
    },
  },
});
