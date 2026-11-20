/** Set by the site's Vite build (sites/axo.leostera.dev/vite.config.ts); absent in tests. */
declare const __AXO_BUILD__: string | undefined;

/**
 * The exact source this Worker was built from: the full commit, "+" when the tree differed from
 * it, or "dev" when built outside the site (tests). Continuous delivery reads it back from
 * /api/health to check what is live (tools/cd).
 */
export const BUILD: string = typeof __AXO_BUILD__ === "string" ? __AXO_BUILD__ : "dev";
