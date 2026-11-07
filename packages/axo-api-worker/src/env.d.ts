/**
 * The bindings this Worker uses, for its own typecheck. The site that deploys it declares them in
 * its cloudflare.config.ts, and the site's typecheck reads this Worker's source with the Env
 * inferred from that file, so a binding used here and missing there fails it.
 */
interface Env {
  /** Every account's assets, under accounts/<accountId>/<sha256> (RFD0030). */
  AXO_ASSETS: R2Bucket;
  /** Shared conversations' snapshots. */
  PUBLIC_SESSIONS: R2Bucket;
  /** Runs scripts in Dynamic Workers (RFD0016). */
  LOADER: WorkerLoader;
  OAUTH_CLIENT_ID: string;
  OAUTH_CLIENT_SECRET: string;
  SESSION_SECRET: string;
  GOOGLE_CLIENT_ID: string;
  GOOGLE_CLIENT_SECRET: string;
}

declare namespace Cloudflare {
  /** `ctx.exports`: this Worker's module is the site's main module, which re-exports it. */
  interface GlobalProps {
    mainModule: typeof import("./index");
    durableNamespaces:
      | "AxoAccountDirectory"
      | "AxoAssetsDO"
      | "AxoClientDO"
      | "AxoHostDirectory"
      | "AxoHostDO"
      | "AxoHostRelay"
      | "AxoIdentityIndex"
      | "AxoPairingIndex"
      | "AxoPairingRateLimit"
      | "AxoSessionDO";
  }
}
