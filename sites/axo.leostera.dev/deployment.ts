/**
 * Where each deployment of the site lives, and the buckets it may touch. Production serves
 * axo.leostera.dev; a preview shares nothing with it.
 *
 * No deployment has a workers.dev URL or preview URLs: an internal Worker is reached only on a
 * custom domain behind Cloudflare Access. The preview has no domain yet, so it is unreachable
 * until one is set up with an Access application in front of it.
 */
export type Deployment = {
  readonly name: string;
  readonly domains: readonly string[];
  readonly workersDev: false;
  readonly previewUrls: false;
  readonly buckets: {
    /** Published shares (`/s/<id>`). */
    readonly publicSessions: string;
    /** The Mac app `/cdn/*` serves and `/install` downloads. */
    readonly cdn: string;
    /** Every account's assets (RFD0030). */
    readonly assets: string;
  };
};

export function deployment({ isPreview }: { isPreview: boolean }): Deployment {
  return isPreview
    ? {
        name: "axo-public-app-preview",
        domains: [],
        workersDev: false,
        previewUrls: false,
        buckets: { publicSessions: "axo-public-sessions-preview", cdn: "axo-cdn-preview", assets: "axo-assets-preview" },
      }
    : {
        name: "axo-public-app",
        domains: ["axo.leostera.dev"],
        workersDev: false,
        previewUrls: false,
        buckets: { publicSessions: "axo-public-sessions", cdn: "axo-cdn", assets: "axo-assets" },
      };
}
