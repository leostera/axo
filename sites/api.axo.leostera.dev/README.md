# Axo API Worker deployment

This site contains the Worker entrypoint shim, Cloudflare deployment configuration, and deployment-specific generated types. API behavior, Durable Objects, tests, and runtime dependencies live in [`@axo/api-worker`](../../packages/axo-api-worker/README.md).

`cf build` builds without deploying. Cloudflare Access and production resources remain unchanged by local development and tests.
