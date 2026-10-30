# Axo API Worker package

This package owns the API Worker handler, Durable Object implementations, routing/domain logic, and their tests. The deployment shim and Cloudflare configuration remain in `sites/api.axo.leostera.dev`. Shared request/result schemas live in [`@axo/protocol`](../axo-api/README.md).

The Worker currently trusts the configured Cloudflare Access perimeter and derives client/daemon roles from routes. This package move does not change that authorization behavior or any production Cloudflare resources.

## Development and validation

From the repository root:

```sh
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-api-worker install
npm --userconfig=/tmp/axo-npmrc --prefix sites/api.axo.leostera.dev run typecheck
npm --userconfig=/tmp/axo-npmrc --prefix sites/api.axo.leostera.dev test
npm --userconfig=/tmp/axo-npmrc --prefix sites/api.axo.leostera.dev run test:relay
```

The site typecheck generates Cloudflare binding types before checking this package. Tests run under Node's test runner with Miniflare/workerd; they do not contact a deployed API or use the production daemon or LaunchAgent.
