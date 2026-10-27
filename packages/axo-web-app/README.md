# Axo web application package

This package owns the React application (chats with Axo on your Macs, in the iPhone app's look), browser API/relay integration, styles, and tests. The unified deployment shim, HTML document, and Cloudflare configuration live in `sites/axo.leostera.dev`.

## Development and validation

From the repository root:

```sh
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-web-app install
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-web-app run typecheck
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-web-app test
```

The app targets `https://axo.leostera.dev` by default; set `VITE_AXO_API_BASE_URL` to target an isolated API during development. The `/app` path checks the same-origin `/api/auth/*` session and, when signed in, opens the chats: the iPhone app's layers (account, chats, conversation, chat info), side by side from 900px wide and stacked below that. The browser follows chats, not terminals: it reads history newest first, a page at a time, and sends messages, stops and answers as the phone does. `src/chat/{markdown,transcript,workbench}.ts` are ports of the phone's `AxoPhoneModel` and are tested directly with `npm run test:model`; `AXO_WEB_SHOTS=<dir> npm run test:browser` keeps a screenshot of each step. Set `VITE_AXO_AUTH_API_BASE_URL` only when testing against a separate isolated API origin.

Production Cloudflare consent, callback, session verification, account-scoped host routes, and host pairing have succeeded. The retired `app.axo.leostera.dev` and `api.axo.leostera.dev` Workers and site shims are not part of the product flow. Legacy global `private-fleet` host records remain unassigned and are not shown in account Workbench.
