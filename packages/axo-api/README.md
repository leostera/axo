# Axo API protocol package

This package is the TypeScript runtime and type layer used by the Cloudflare API Worker and remote clients. The canonical, versioned wire format is the JSON Schema source under [`schemas/axo.leostera.dev/v1`](../../schemas/axo.leostera.dev/v1), not hand-maintained TypeScript-only descriptions.

`src/v1.ts` exports strict Zod validators for host identity, sanitized session/layout snapshots, host relay calls/results, and host-scoped events. Runtime parsing at API boundaries must use these validators. The package's framing/RPC utilities are shared with the existing bounded Worker relay.

Host registration may advertise a versioned capability manifest (`agent.pi`, `terminal.pty`, and `workspace.filesystem`). The account API persists that manifest and returns it with host metadata. Omitted capabilities mean the host has not declared a manifest; an explicit empty array means it declares no capabilities. These are availability claims for host selection, **not authorization grants**. A client must not infer that a Session has permission to use every advertised capability; per-Workspace/per-Session grants are a separate future contract.

Run `npm run schema:check` to validate the canonical schemas and cross-language fixtures, and `npm run build` to type-check it. There is no build output: consumers import the TypeScript source (`src/index.ts`, `src/v1.ts`) directly.
