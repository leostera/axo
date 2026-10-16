# Axo API protocol package

This package is the TypeScript runtime and type layer used by the Cloudflare API Worker and remote clients. The canonical, versioned wire format is the JSON Schema source under [`schemas/axo.leostera.dev/v1`](../../schemas/axo.leostera.dev/v1), not hand-maintained TypeScript-only descriptions.

`src/v1.ts` exports strict Zod validators for host identity, sanitized session/layout snapshots, host relay calls/results, and host-scoped events. Runtime parsing at API boundaries must use these validators. The package's framing/RPC utilities are shared with the existing bounded Worker relay.

Run `npm run schema:check` to validate the canonical schemas and cross-language fixtures, and `npm run build` to compile the package.
