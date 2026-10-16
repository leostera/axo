# `@axo/app`

Browser-safe client helpers for Axo's Access-protected host/session API and v1 host relay. HTTP requests use browser-managed credentials (`credentials: include`) and do not carry tokens from application code. WebSocket subscriptions negotiate protocol v1, subscribe to one host generation, validate event envelopes, and acknowledge each relay frame to maintain bounded delivery credits.

The package deliberately has no terminal transcript or command persistence. Terminal bytes are dispatched to the caller only as live `terminal.output` events; controls are sent directly over the authorized host relay.

## Development

```sh
npm --prefix packages/axo-app install
npm --prefix packages/axo-app test
```

`RemoteAxoApi` accepts an API origin, with optional fetch and WebSocket factories for isolated tests. Production pages should use `https://api.axo.leostera.dev`. Configure the app site's Cloudflare Access policy separately; API browser requests also require the personal Access identity for the API hostname.
