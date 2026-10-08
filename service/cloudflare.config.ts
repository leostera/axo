import { bindings, defineConfig, exports } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

export default defineConfig({
  worker: {
    name: "axo-relay",
    compatibilityDate: "2026-10-08",
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
    exports: { Relay: exports.durableObject({ storage: "sqlite" }) },
    env: {
      // Fail closed until configured for the real Access application.
      ACCESS_TEAM_URL: bindings.text("https://unconfigured.cloudflareaccess.com"),
      ACCESS_AUD: bindings.text("unconfigured"),
      ACCESS_USER_EMAIL: bindings.text("unconfigured@example.invalid"),
      ACCESS_HOST_CLIENT_ID: bindings.text("unconfigured"),
    },
  },
});
