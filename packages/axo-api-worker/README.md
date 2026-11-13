# Axo API Worker package

This package owns the API Worker handler, Durable Object implementations, routing/domain logic, and their tests. The unified public deployment shim and Cloudflare configuration live in `sites/axo.leostera.dev`. Shared request/result schemas live in [`@axo/protocol`](../axo-api/README.md).

Every route is account-scoped, under `/api/v1/*`. Pairing, host records and revocation live in the per-account `AxoAccountManager`; its deployment export keeps the `AxoAccountDirectory` Durable Object name so existing account rows stay in the same SQLite namespace. A sharded pairing-code index is routing-only; it does not own account data. Each paired Mac has one `AxoHostDO`: its socket (`AxoHostRelay`, the base class: admission, lease, fragments, shares), its Session index, and protocol 3's client sockets (RFD0032).

## Sign-in: Cloudflare OAuth, sessions of our own

Anyone with a Cloudflare account can sign in; there is no allowlist. The Worker runs the OAuth authorization-code flow with PKCE (`src/auth/login.ts`, `oauth-cloudflare.ts`) and then issues its own session, so the same code serves the web app and the phone.

- **Start** (`GET /api/auth/cloudflare/start`): seals the PKCE verifier, a nonce and an expiry into the OAuth `state` (AES-GCM, bound to its purpose) and sets a flow cookie holding the nonce. The callback must present both, so a callback link an attacker started cannot sign anyone else in.
- **Callback** (`GET /api/auth/cloudflare/callback`): exchanges the code, reads the user's profile, maps the provider-qualified subject to a random account ID (`AxoIdentityIndex`; never by email) and answers by client. The web gets a session cookie and a redirect to `/app`. The phone (`?client=native&challenge=<S256 of a secret it keeps>`) gets a one-time code on `axo://auth/callback`; the redirect is fixed, not chosen by the caller.
- **Token** (`POST /api/auth/token`): the app trades `{code, verifier}` for a session token. The code lives 60 seconds in the account's Durable Object, works once, and a wrong verifier burns it.
- **Sessions** (`src/auth/session.ts`): `axo1.<account>.<secret>` with a 256-bit secret; only an HMAC of it is stored, per account (at most 20; the oldest make room). 30 days on the web, 90 on the phone. `POST /api/auth/logout` ends exactly that sign-in. `requireAccount` is the one place a request becomes an account: an `Authorization: Bearer` header decides alone (a bad one is refused, not replaced by a cookie), otherwise the `__Host-axo_session` cookie, which may only change state or open a relay from the app's own `Origin`.
- **Limits**: start, callback and token are rate limited per source and globally.

Bindings (declared in `sites/axo.leostera.dev/cloudflare.config.ts`; values are set on the Worker, never in the repo): `OAUTH_CLIENT_ID` and `OAUTH_CLIENT_SECRET` for the Cloudflare OAuth client (callback `https://axo.leostera.dev/api/auth/cloudflare/callback`, scope `user-details.read`), and `SESSION_SECRET` (at least 32 bytes) which keys session hashes, login codes, the sealed state, pairing codes and host credentials. Without them, sign-in answers 503.

## Apps: Google Workspace

Apps are services the Worker provides itself (RFD0016, Apps), reached from scripts as `codemode.apps.<app>.<tool>({ account, ... })` (`src/apps/builtin/`, one file per app): Gmail, Calendar, Drive, Docs, Sheets, Slides, Contacts, Tasks, Meet and Google Cloud, over Google's REST APIs, run in the account's `AxoAccountManager` with one sealed Google grant per app and Google account (`app_accounts`). Signing in reuses the apps start page and callback. The Google client is Axo's own, set as `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` on the Worker: a Web application client in the `axo-leostera-dev` Google Cloud project, Internal audience (ostera.io accounts only), redirect URI `https://axo.leostera.dev/api/v1/connections/oauth/callback`, with the Gmail, Calendar, Drive, Docs, Sheets, Slides, People, Tasks, Meet, Resource Manager and Service Usage APIs enabled and every scope the apps ask for on its consent screen (`openid`, `userinfo.email`, `https://mail.google.com/`, `gmail.settings.basic`, `gmail.settings.sharing`, `calendar`, `drive`, `documents`, `spreadsheets`, `presentations`, `contacts`, `contacts.other.readonly`, `directory.readonly`, `tasks`, `meetings.space.created`, `meetings.space.readonly`, `cloud-platform`). Without both secrets, no app is listed. A new tool is a `tool({ name, description, input, idempotent, run })` in its app's file; `idempotent: false` makes a call that got no answer may-have-run. Every app also gets `request` (`request.ts`), for any endpoint on its `hosts`; a new app lists its hosts, API reference, description and plain-words permissions in its `AppDefinition`.

Hosts never sign in: they pair. `/api/v1/host-pairings/redeem` and `/api/v1/accounts/:account/hosts/:host/daemon` authenticate with the pairing code and the per-host credential.

The public site at `axo.leostera.dev` serves the landing page and app from the same origin as `/api/auth/me` and the new `/api/v1/account/*` APIs. Other `/api/*` paths remain unavailable. The legacy `app.axo.leostera.dev` and `api.axo.leostera.dev` Workers and Access applications have been removed, and their site-shim code is deleted. No legacy host records have been migrated; this change did not issue Durable Object namespace tombstones.

## Local AI tools

`codemode.ai.list/install/load/unload/run` routes a script's request to a paired Mac
(`host`, default `self`). `run` lazily installs and loads the pinned Gemma 3 270M IT
GGUF; the Hugging Face MCP connection can help discover models but is not the downloader.
Only this reviewed model reference is accepted for now.

Definitions and receipts are in `@axo/protocol/src/ai.ts`; `AccountApps` resolves the target
for every call and sends `axo.apps.ai` on its authenticated relay. The daemon checks the
account again and admits bounded jobs independently of the relay's ordered requests.
Receipts must include the pinned artifact's provenance. Prompts/output are omitted from
the AI call log; call failures and disconnected outcomes are recorded without retrying.
The model runs locally, but inputs and outputs still traverse the cloud script/relay.

See [the inference service](../../crates/axod-infer/README.md) for examples, limits and testing.
Both the Worker and target Mac need this version; an older Mac returns an update instruction.

## Development and validation

From the repository root:

```sh
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-api-worker install
npm --userconfig=/tmp/axo-npmrc --prefix sites/axo.leostera.dev run typecheck
npm --userconfig=/tmp/axo-npmrc --prefix sites/axo.leostera.dev test
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-api-worker run test:relay
```

The site typecheck generates Cloudflare binding types before checking this package. Tests run under Node's test runner with Miniflare/workerd; they do not contact a deployed API or use the production daemon or LaunchAgent.
