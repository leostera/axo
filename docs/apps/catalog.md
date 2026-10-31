# Axo apps catalog (RFD0016)

Which services become Axo apps, how each one signs in, and which API it uses. This is the working
plan; RFD0016's app table lists what has shipped.

Kinds:

- **MCP**: the service has an official remote MCP server. Axo lists it in Apps as a suggested
  server and adds it by URL (RFD0016, third-party connections). No Axo code per service.
- **OAuth**: Axo registers its own OAuth client with the provider, like the Google apps.
- **Token**: the person pastes a key, token or password the service issues them. Axo seals it
  like an OAuth grant and never shows it again. Calls go to the service's REST API.
- **Mac**: only reachable from a paired Mac: a CLI or a local network device, through the
  existing `bash` connection. A thin app can wrap the commands later.
- **Browser**: no API for a personal account. Needs a browser on a Mac driven by Axo (later).
- **Phone**: only usable from the phone app (later).

## Framework

1. **Token apps** (`connections/apps/token.ts`). An app definition says how it signs in:
   `{ kind: "oauth", provider }` or `{ kind: "token", fields, auth }`.
   - `fields`: what the person pastes, each with a plain label and a link to where to find it
     (for example "API token" with Hetzner's page).
   - `auth`: how the credential goes on a request: `bearer`, `basic`, a named header, or a
     signing function for services that sign each request (Kraken, Backpack).
   - `identify(api)`: an optional call that names the account (Wise's profile email, Octopus's
     account number). Without it the person names the account, such as "personal".
   - Adding a token checks it with one read call before storing it. A refused token is not
     stored.
   - Storage is the existing `app_accounts` table, sealed with the same key. The generic
     `request` tool works unchanged, limited to `hosts`.
   - The web app gets an "Add account" form that posts the fields once. A token is never sent
     back.
2. **OAuth providers** (`connections/apps/oauth-provider.ts`). Google's settings become one
   provider config: endpoints, client secrets on the Worker, extra authorize parameters, how to
   learn the account's name, whether refresh tokens rotate, revocation. Spotify, GitHub, Slack,
   Strava, Withings and the rest are each a config.
3. **Device sign-in.** For providers whose client only allows a device code (ChatGPT): Apps shows
   a code and a link, and the gateway polls the provider until the person approves.
4. **Suggested MCP servers.** Catalog entries that add an official MCP server by URL with its
   logo.

Everything lands in `connections/apps/*` and the web app. The routes and RPC methods for adding a
token or starting a device sign-in go in once AxoGateway (RFD0020) is on main.

## Priorities

### 1. 1Password (built: `apps.onepassword`)

1Password has no OAuth for vaults, and Leo's items are in his default (Private) vault, which a
service account can never open. So the app runs `op` on his Macs (RFD0016, Other ways in).
Options considered:

| Route | Works from | Notes |
| --- | --- | --- |
| Service account token and the 1Password SDK | the Worker | Official. 1Password has no public REST API for service accounts; the SDKs (JS, Go, Python) wrap a WASM core (`@1password/sdk-core`, 14 MB, uses `fetch`). It is too large for the main Worker, so it runs in a small helper Worker behind a service binding. That Worker is given the token for each call and stores nothing. A service account only sees vaults it is granted, never Private or Personal. |
| 1Password Connect server | a server Leo runs | REST, but someone has to host Connect (Docker). No. |
| `op` CLI on a paired Mac | the Mac | Works today through `bash`. The desktop app asks for Touch ID per session, so it is not unattended, and the Mac must be online. |

**Choice:** `op` on the Macs, wrapped as an app. A service-account app for shared vaults (the SDK in
a helper Worker) can come later. **Leo:** in the 1Password app, turn on Settings, Developer,
Integrate with 1Password CLI, on each Mac.

### 2. Revolut (and Raiffeisen). Not built yet

Leo's Revolut is EU personal, and his Raiffeisen is Raiffeisenbank a.s. in the Czech Republic. He
wants first-party integrations first:

- Revolut has no first-party API for personal accounts, so first party means app.revolut.com in a
  browser on a Mac.
- Raiffeisenbank CZ has a first-party "Premium API" for personal clients: balances and
  transactions, with a client certificate generated in internet banking. The Worker can present
  the certificate (an mTLS binding uploaded once), or a Mac can call the API with it.
- Enable Banking is the fallback for both.

The options, as first researched:

- Personal Revolut has no public API. Its Open Banking API is only for licensed providers.
- GoCardless Bank Account Data, formerly Nordigen, stopped taking new customers in 2025.
- **Enable Banking** has a free "restricted mode" for linking your own accounts. It covers
  Revolut, Raiffeisen and about 2,500 other EU and UK banks. Each request is signed with a JWT
  (RS256) from the app's private key, which Workers can do with WebCrypto. Consent lasts up to
  180 days, then the person signs in to the bank again.
- The Revolut Business API takes a token and certificate. It only applies to a Business account.
- A browser fallback (app.revolut.com on a Mac) comes later.

**Choice:** `apps.banking`, a bank-connection app on Enable Banking, read-only. Its accounts are
bank consents ("Revolut", "Raiffeisen"). Tools: `list_accounts`, `get_balances`,
`list_transactions`. The person signs in through the bank's own consent page, which is an OAuth
redirect through Enable Banking, so it fits the existing callback. **Leo:** sign up at
enablebanking.com, create an application in restricted mode and link his own accounts. Is
Revolut personal UK or EU (Enable Banking says EU Revolut works; UK needs checking)? Which
country is the Raiffeisen account in?

### 3. ChatGPT, signed in as Codex (built: `apps.chatgpt`)

Codex (openai/codex, `codex-rs/login`) signs in as public client `app_EMoamEEZ73f0CkXaXp7hrann`
at `auth.openai.com` with PKCE. Its browser flow only redirects to `localhost:1455`. Its device
flow works from a server:

1. `POST https://auth.openai.com/api/accounts/deviceauth/usercode` with `{ client_id }` returns a
   user code.
2. The person enters the code at `https://auth.openai.com/codex/device`.
3. `POST .../deviceauth/token` is polled until it returns an authorization code and verifier.
4. `POST /oauth/token` redeems the code, with `redirect_uri` set to `.../deviceauth/callback`.

The tokens call `https://chatgpt.com/backend-api/codex/responses` (the Responses API) with a
`chatgpt-account-id` header, plus `/backend-api/wham/usage` for limits. Refresh tokens rotate.

**Choice:** `apps.chatgpt` with device sign-in. Tools: `respond` (one Responses call: model,
input, optional reasoning effort), `list_models`, `usage`, plus `request` limited to
`chatgpt.com/backend-api/codex`. **Leo:** device-code sign-in must be on in ChatGPT's security
settings. This uses Codex's client ID, as Pi does; OK?

## Catalog

In priority order. "Tools" lists the first named tools; every app also has `request`.

| App | Kind | API | Account named by | First tools |
| --- | --- | --- | --- | --- |
| Hetzner Cloud (+ DNS) (built: `apps.hetzner`) | Token, bearer | `api.hetzner.cloud/v1` (OpenAPI at docs.hetzner.cloud/cloud.spec.json); DNS zones are in the Cloud API now; storage boxes at `api.hetzner.com/v1` with the same token | person (a token is per project) | servers, zones and records, firewalls, volumes, storage boxes |
| Hetzner Robot | Token, basic (web service user) | `robot-ws.your-server.de` | the web service user | servers, reset, rDNS, firewall |
| 1Password | Token, SDK | see above | service account | see above |
| Banking (Revolut, Raiffeisen) | OAuth through Enable Banking | see above | bank and consent | see above |
| ChatGPT | Device OAuth (Codex) | see above | ChatGPT email | see above |
| Octopus Energy (built: `apps.octopus`) | Token, basic (key as user) | `api.octopus.energy/v1` + GraphQL | account number | consumption, tariffs, account |
| Wise (built: `apps.wise`) | Token, bearer (personal token) | `api.wise.com` (some EU/UK statement calls need SCA signing) | profile email | profiles, balances, transfers, rates |
| GitHub (suggested MCP server) | MCP (`api.githubcopilot.com/mcp/`, needs a registered OAuth app) or OAuth → REST | REST v3 / GraphQL | login | repos, issues, PRs, search |
| Slack | OAuth (user token) → Web API; the official MCP server is for approved apps only | `slack.com/api` | workspace and user | search, history, post, users |
| Stripe (suggested MCP server) | MCP (`mcp.stripe.com`, OAuth) | n/a | n/a | n/a |
| Telegram (built: `apps.telegram`, bots) | Token (bot token) → Bot API. A personal account needs MTProto: Mac (a CLI such as `tdl`) | `api.telegram.org` | bot username | send, updates, chats |
| WhatsApp | Browser (WhatsApp Web) or Mac. The Cloud API is for business numbers only | n/a | n/a | n/a |
| Kraken (built: `apps.kraken`) | Token, signed (API key + HMAC-SHA512) | `api.kraken.com` | person | balances, trades, orders |
| Spotify | OAuth (PKCE; development mode allows a few users) | `api.spotify.com/v1` | email | playback, search, playlists |
| Strava | OAuth | `www.strava.com/api/v3` | athlete name | activities, stats |
| Withings | OAuth (signed nonce on some calls) | `wbsapi.withings.net` | user ID | measures, sleep, activity |
| PayPal (suggested MCP server) | MCP (`mcp.paypal.com`) for business accounts; personal → Browser | n/a | n/a | n/a |
| Discord | Token (bot) → REST; a user's own DMs are not allowed by Discord | `discord.com/api/v10` | bot | messages, channels |
| Bluesky | Token (app password → AT Protocol session) | `bsky.social/xrpc` | handle | timeline, post, search |
| Plex | Token (X-Plex-Token, or the plex.tv PIN sign-in) | `plex.tv`, `*.plex.direct` | Plex username | libraries, search, sessions |
| LinkedIn | OAuth (only profile and posting are allowed) | `api.linkedin.com` | email | profile, post |
| Twitch | OAuth | `api.twitch.tv/helix` | login | streams, follows, chat |
| Starlink | Mac (the dish's local gRPC API at 192.168.100.1) | n/a | n/a | n/a |
| UniFi | Token (Site Manager API key); local controller → Mac | `api.ui.com` | person | hosts, sites, devices |

### The rest

| Service | Kind | Notes |
| --- | --- | --- |
| Google Authenticator | Phone | Secrets never leave the phone |
| Tricount | Phone / Browser | Now part of bunq, no public API |
| Raiffeisen | OAuth via Banking | Enable Banking |
| Backpack (exchange) | Token, signed (ED25519) | `api.backpack.exchange` |
| Phantom | Phone | A wallet. Public on-chain reads need no account |
| Avanza | Browser | No official API |
| Nordnet | Token, signed | "nExt API" for customers (key pair); check it still exists |
| E*TRADE | OAuth 1.0a | Official API |
| Signal | Mac | `signal-cli` as a linked device |
| X | OAuth 2 (PKCE) | Reading needs a paid API tier |
| Messenger | Browser | |
| Amazon | Browser | |
| Uber | Browser / Phone | The rider API is closed |
| Bolt | Phone | |
| Tesco Clubcard | Browser | |
| HMRC | Browser | The APIs are for registered tax software |
| NHS | Phone / Browser | NHS App |
| Honest Mobile | Browser / Phone | |
| Kiwi.com | Browser | The Tequila API is closed to new partners |
| Lovense Remote | Phone | Its developer API is for platforms |
| Luna events | ? | **Leo:** which service is this? |
| Navan | Browser | Its API is for company admins |
| Temu | Browser / Phone | |
| Transport for London | Token (free app key) | Unified API for status and journeys; journey history is Browser |
| Threads | OAuth (Meta) | Threads API: posts, replies, insights |
| Ticketmaster | Token (Discovery API key) | Events. Orders are Browser |
| Too Good To Go | Phone | |
| TipTapp | Phone | |
| Tradera | Token (app ID and key, SOAP) | Search and items. The account is Browser |
| Vinted | Browser / Phone | |
| Voy | ? | **Leo:** which service is this? |
| Wetherspoon | Phone | |
| Zalando | Browser | |
| Facebook | Browser | The Graph API gives little for a personal account |
| Instagram | OAuth for business or creator accounts, else Browser | |
| TikTok | OAuth (Display API: profile and videos) | |
| Lightroom | OAuth (Adobe; needs partner approval) | |
| TodayTix | Browser / Phone | |
| Booking.com | Browser | |
| Airbnb | Browser | |
| Ryanair | Browser | |
| Google Flights | Browser | |
| Skyscanner | Browser | The API is for partners |
| MANGA Plus | Browser | |
| Netflix | Browser | |
| Disney+ | Browser | |
| Crunchyroll | Browser | |

## Order of work

1. Token-app framework and Hetzner Cloud (+ Robot).
2. 1Password (helper Worker and SDK), Octopus Energy, Wise.
3. The OAuth provider config and ChatGPT device sign-in.
4. Banking (Enable Banking): Revolut, Raiffeisen.
5. The rest of the first table, in order. Suggested MCP entries (Stripe, PayPal, GitHub) are
   cheap, so they come early.
