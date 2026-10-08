import { bindings, defineConfig, exports } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

export default defineConfig({
  accountId: "0f436d2aabf1f872be90b8dd9d5715e6",
  worker: {
    name: "axo-relay",
    domains: ["bridge.axo.leostera.dev"],
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
      // These identities must match the narrowly scoped Access user and Service Auth policies.
      ACCESS_TEAM_URL: bindings.text("https://abstractmachines.cloudflareaccess.com"),
      ACCESS_AUD: bindings.text("27aa272296036691edc586961cc73c335993ac5efdefa5040e69adbc77cb5a0a"),
      ACCESS_USER_EMAIL: bindings.text("leandro@abstractmachines.dev"),
      ACCESS_HOST_CLIENT_ID: bindings.text("c370495bb908a81be8d34b1856a51cd4.access"),
    },
  },
});
