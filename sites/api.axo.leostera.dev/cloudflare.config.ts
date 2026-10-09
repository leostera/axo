import { bindings, defineConfig, exports } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

// Independent private API; no legacy relay or file-storage bindings.
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
    env: {
      // These identities must match the narrowly scoped Access user and Service Auth policies.
      ACCESS_TEAM_URL: bindings.text(
        "https://abstractmachines.cloudflareaccess.com",
      ),
      ACCESS_AUD: bindings.text(
        "b4ce8a1f58bff7fd09c1d2b64fdbbd7a2098df4a0e46850b78caa05783676073",
      ),
      ACCESS_USER_EMAIL: bindings.text("leandro@abstractmachines.dev"),
      ACCESS_HOST_CLIENT_ID: bindings.text(
        "e3a197012227e015be83ac05ccf201ed.access",
      ),
    },
  },
});
