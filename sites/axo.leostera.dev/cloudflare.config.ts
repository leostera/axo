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
      runWorkerFirst: ["/api", "/api/*", "/install", "/cdn/*", "/s/*"],
    },
    observability: {
      enabled: true,
      // Telemetry is sampled at 1% across every Worker: logs and traces alike.
      headSamplingRate: 0.01,
      redactQueryString: true,
      logs: { enabled: true, headSamplingRate: 0.01 },
      // Every SQL statement in a Durable Object is a span (~16 per request): at 1.0 that was ~13 GB/day,
      // about $98/month under Observability pricing from 2026-12-01. 1% keeps traces for debugging.
      traces: { enabled: true, headSamplingRate: 0.01 },
    },
    // Sign-in with Cloudflare OAuth. The values are set on the Worker, never in this file.
    env: {
      // The site's own files, for the pages the Worker serves itself (a share's page is index.html).
      ASSETS: bindings.assets(),
      PUBLIC_SESSIONS: bindings.r2({ name: "axo-public-sessions" }),
      // The Mac app `/cdn/Axo.app` serves and `/install` downloads; `scripts/publish-mac.sh` uploads it.
      CDN: bindings.r2({ name: "axo-cdn" }),
      // Assets (RFD0030): every account's files, under accounts/<accountId>/<sha256>.
      AXO_ASSETS: bindings.r2({ name: "axo-assets" }),
      OAUTH_CLIENT_ID: bindings.secret(),
      OAUTH_CLIENT_SECRET: bindings.secret(),
      SESSION_SECRET: bindings.secret(),
      // Axo's Google OAuth client, for the Gmail app (codemode.apps.gmail.*). Optional: without it apps are unavailable.
      GOOGLE_CLIENT_ID: bindings.secret(),
      GOOGLE_CLIENT_SECRET: bindings.secret(),
      // Runs scripts in Dynamic Workers with no network of their own (RFD0016).
      LOADER: bindings.workerLoader(),
    },
    exports: {
      // The private fleet's relay and directory, before accounts; neither ever held an object.
      AxoHostDirectory: exports.durableObject({ state: "deleted" }),
      AxoHostRelay: exports.durableObject({ state: "deleted" }),
      AxoIdentityIndex: exports.durableObject({ storage: "sqlite" }),
      AxoAccountDirectory: exports.durableObject({ storage: "sqlite" }),
      AxoPairingIndex: exports.durableObject({ storage: "sqlite" }),
      AxoPairingRateLimit: exports.durableObject({ storage: "sqlite" }),
      AxoSessionDO: exports.durableObject({ storage: "sqlite" }),
      AxoHostDO: exports.durableObject({ storage: "sqlite" }),
      AxoClientDO: exports.durableObject({ storage: "sqlite" }),
      // One per account: the assets index and quota (RFD0030).
      AxoAssetsDO: exports.durableObject({ storage: "sqlite" }),
      // Workers Cache in front of the asset reads; the default entrypoint stays uncached.
      AxoAssetCache: exports.worker({ cache: { enabled: true } }),
    },
  },
}));
