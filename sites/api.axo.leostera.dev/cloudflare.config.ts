import { bindings, defineConfig, exports } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

// No public domain or legacy resource bindings: deployment/Access provisioning is separate.
export default defineConfig({
  accountId: "0f436d2aabf1f872be90b8dd9d5715e6",
  worker: {
    name: "axo-private-api",
    compatibilityDate: "2026-10-09",
    compatibilityFlags: ["nodejs_compat"],
    entrypoint,
    workersDev: false,
    previewUrls: false,
    observability: {
      enabled: true,
      redactQueryString: true,
      logs: { enabled: true },
      traces: { enabled: true, headSamplingRate: 0.01 },
    },
    exports: {
      MachineDirectory: exports.durableObject({ storage: "sqlite" }),
      MachineRelay: exports.durableObject({ storage: "sqlite" }),
    },
    env: {
      ACCESS_TEAM_URL: bindings.secret(),
      ACCESS_AUD: bindings.secret(),
      ACCESS_USER_EMAIL: bindings.secret(),
      ACCESS_HOST_CLIENT_ID: bindings.secret(),
    },
  },
});
