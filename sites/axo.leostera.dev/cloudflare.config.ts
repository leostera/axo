import { bindings, defineConfig, exports } from "cf/config";
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
      runWorkerFirst: ["/api", "/api/*", "/install", "/cdn/*"],
    },
    observability: {
      enabled: true,
      redactQueryString: true,
      logs: { enabled: true },
      traces: { enabled: true, headSamplingRate: 1 },
    },
    // Sign-in with Cloudflare OAuth. The values are set on the Worker, never in this file.
    env: {
      PUBLIC_SESSIONS: bindings.r2({ name: "axo-public-sessions" }),
      // The Mac app `/cdn/Axo.app` serves and `/install` downloads; `scripts/publish-mac.sh` uploads it.
      CDN: bindings.r2({ name: "axo-cdn" }),
      OAUTH_CLIENT_ID: bindings.secret(),
      OAUTH_CLIENT_SECRET: bindings.secret(),
      SESSION_SECRET: bindings.secret(),
      // Axo's Google OAuth client, for the Gmail app (codemode.apps.gmail.*). Optional: without it apps are unavailable.
      GOOGLE_CLIENT_ID: bindings.secret(),
      GOOGLE_CLIENT_SECRET: bindings.secret(),
      // Runs connections scripts in Dynamic Workers with no network of their own (RFD0016).
      LOADER: bindings.workerLoader(),
    },
    exports: {
      AxoHostDirectory: exports.durableObject({ storage: "sqlite" }),
      AxoHostRelay: exports.durableObject({ storage: "sqlite" }),
      AxoIdentityIndex: exports.durableObject({ storage: "sqlite" }),
      AxoAccountDirectory: exports.durableObject({ storage: "sqlite" }),
      AxoPairingIndex: exports.durableObject({ storage: "sqlite" }),
      AxoPairingRateLimit: exports.durableObject({ storage: "sqlite" }),
      AxoSessionDO: exports.durableObject({ storage: "sqlite" }),
      AxoHostDO: exports.durableObject({ storage: "sqlite" }),
      AxoClientDO: exports.durableObject({ storage: "sqlite" }),
    },
  },
}));
