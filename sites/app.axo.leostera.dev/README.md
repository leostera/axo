# Axo Remote

This is the Access-protected browser interface for Axo sessions. It reads host/session/pane metadata from `api.axo.leostera.dev`, then opens one authenticated host relay subscription for live activity, terminal output, and remote controls. Axod owns the PTYs. The API stores only host/session/layout metadata; terminal output and input travel through the live relay and are not written to Cloudflare storage.

The page uses browser-managed Cloudflare Access cookies, not application API keys. Because the app and API are separate Access applications, opening **Open Axo API access** may be required once for the API hostname. Browser HTTP calls use credentialed CORS and WebSocket calls use the app Origin; no Access service token is shipped to the browser.

## Local development and validation

```sh
npm --prefix sites/app.axo.leostera.dev install
npm --prefix sites/app.axo.leostera.dev run dev
npm --prefix sites/app.axo.leostera.dev run typecheck
npm --prefix sites/app.axo.leostera.dev run build
```

`VITE_AXO_API_BASE_URL` may point to an isolated local API during development. It is a public URL, not a secret. With no override, the site uses `https://api.axo.leostera.dev`. SPA routes fall back to the built `index.html` asset.

## Deployment boundary

`cloudflare.config.ts` names only the requested app Worker and its `app.axo.leostera.dev` custom domain. It creates no application data bindings. Cloudflare Access policies are configured outside this Worker and must admit only the owner's personal identity. Deployment is an explicit separate step; `cf build` does not deploy.
