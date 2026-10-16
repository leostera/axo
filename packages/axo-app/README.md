# `@axo/app`

Browser-safe client helpers for Axo's Access-protected host/session API and v1 host relay. HTTP requests use browser-managed credentials (`credentials: include`) and do not carry tokens from application code. WebSocket subscriptions negotiate protocol v1, subscribe to one host generation, validate event envelopes, and acknowledge each relay frame to maintain bounded delivery credits.

The package deliberately has no terminal transcript or command persistence. Terminal bytes are dispatched to the caller only as live `terminal.output` events; controls are sent directly over the authorized host relay.

## Development

```sh
npm --prefix packages/axo-app install
npm --prefix packages/axo-app test
```

`RemoteAxoApi` accepts an API origin, with optional fetch and WebSocket factories for isolated tests. The canonical public origin is `https://axo.leostera.dev`. The client uses the same-origin account-scoped host and relay endpoints at `/api/v1/account/hosts`; browser-managed Axo session cookies authorize host discovery, session metadata, and relay connections. The retired app/API subdomains and the legacy global `private-fleet` host routes are not used by this product client.
