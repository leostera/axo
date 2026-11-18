import { bindings, defineConfig, exports } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };
import { deployment } from "./deployment.ts";

export default defineConfig(({ isPreview }) => {
  const target = deployment({ isPreview });
  return {
    accountId: "0f436d2aabf1f872be90b8dd9d5715e6",
    worker: {
      name: target.name,
      compatibilityDate: "2026-10-16",
      compatibilityFlags: ["nodejs_compat", "enable_ctx_exports"],
      entrypoint,
      domains: [...target.domains],
      workersDev: target.workersDev,
      previewUrls: target.previewUrls,
      assets: {
        notFoundHandling: "single-page-application",
        runWorkerFirst: ["/api", "/api/*", "/install", "/cdn/*", "/s/*"],
      },
      observability: {
        enabled: true,
        // Keep sampled structured logs; automatic traces are disabled below for token privacy.
        headSamplingRate: 0.01,
        redactQueryString: true,
        logs: { enabled: true, headSamplingRate: 0.01 },
        // APNs URLs necessarily contain private device tokens. Automatic fetch spans capture paths;
        // query redaction cannot protect them. Keep sampled structured logs, but no automatic traces.
        traces: { enabled: false },
      },
      // Sign-in with Cloudflare OAuth. The values are set on the Worker, never in this file.
      env: {
        // The site's own files, for the pages the Worker serves itself (a share's page is index.html).
        ASSETS: bindings.assets(),
        PUBLIC_SESSIONS: bindings.r2({ name: target.buckets.publicSessions }),
        // The Mac app `/cdn/Axo.app` serves and `/install` downloads; `bazel run //:publish` uploads it.
        CDN: bindings.r2({ name: target.buckets.cdn }),
        // Assets (RFD0030): every account's files, under accounts/<accountId>/<sha256>.
        AXO_ASSETS: bindings.r2({ name: target.buckets.assets }),
        OAUTH_CLIENT_ID: bindings.secret(),
        OAUTH_CLIENT_SECRET: bindings.secret(),
        SESSION_SECRET: bindings.secret(),
        // Optional: the current key and the one being rotated out (RFD0076). Without it, SESSION_SECRET is the only key.
        SECRET_KEYS: bindings.secret(),
        APNS_PRIVATE_KEY: bindings.secret(),
        APNS_KEY_ID: bindings.secret(),
        APNS_TEAM_ID: bindings.secret(),
        // Axo's Google OAuth client, for the Gmail app (codemode.apps.gmail.*). Optional: without it apps are unavailable.
        GOOGLE_CLIENT_ID: bindings.secret(),
        GOOGLE_CLIENT_SECRET: bindings.secret(),
        // Runs scripts in Dynamic Workers with no network of their own (RFD0016).
        LOADER: bindings.workerLoader(),
      },
      exports: {
        AxoIdentityIndex: exports.durableObject({ storage: "sqlite" }),
        AxoAccountDirectory: exports.durableObject({ storage: "sqlite" }),
        AxoPairingIndex: exports.durableObject({ storage: "sqlite" }),
        AxoPairingRateLimit: exports.durableObject({ storage: "sqlite" }),
        AxoPushRegistry: exports.durableObject({ storage: "sqlite" }),
        AxoSessionDO: exports.durableObject({ storage: "sqlite" }),
        AxoHostDO: exports.durableObject({ storage: "sqlite" }),
        AxoClientDO: exports.durableObject({ storage: "sqlite" }),
        // One per account: the assets index and quota (RFD0030).
        AxoAssetsDO: exports.durableObject({ storage: "sqlite" }),
        // One per linked WhatsApp device of an account's (RFD0016, Linked devices).
        AxoWhatsAppDO: exports.durableObject({ storage: "sqlite" }),
        // Workers Cache in front of the asset reads; the default entrypoint stays uncached.
        AxoAssetCache: exports.worker({ cache: { enabled: true } }),
      },
    },
  };
});
