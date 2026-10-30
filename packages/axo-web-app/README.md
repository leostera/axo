# Axo web application package

This package owns the React application, terminal UI, browser API/relay integration, styles, and browser acceptance test. The deployment shim, HTML document, and Cloudflare configuration remain in `sites/app.axo.leostera.dev`.

## Development and validation

From the repository root:

```sh
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-web-app install
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-web-app run typecheck
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-web-app test
```

The site currently uses `https://api.axo.leostera.dev` by default; set `VITE_AXO_API_BASE_URL` to target an isolated API during development. This package extraction does not change authentication or deployment configuration.
