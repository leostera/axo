# RFD0013 - Axo: Cloudflare sign-in and one-time host pairing

- Feature Name: `axo-cloudflare-sign-in-and-host-pairing`
- Status: Proposal
- Author: leostera
- Start Date: 2026-10-16
- Updated: 2026-10-16
- Document Type: Proposal

## Summary

I propose Cloudflare OAuth sign-in for any Cloudflare identity at `axo.leostera.dev`, with the landing page at `/`, the app at `/app`, and API/auth/relay routes under `/api`. Each identity maps to an isolated Axo account Durable Object. A signed-in user creates an eight-character, human-entered pairing code in `XXXX-YYYY` form; the Mac user can type or paste it in Settings → Remote Access. `axod` redeems the short-lived single-use code and receives a unique, revocable host credential. In v1, a signed-in account has full control of its own hosts and each linked host supports the full currently implemented Axo protocol; per-method and per-session capability restrictions are future work. The host credential remains limited to its one host. Worker, Durable Object, and web application logic belongs in packages under `packages/*`; `sites/*` contains only deployment configuration and thin entrypoint shims. This proposal does not create OAuth credentials, change production Access controls, deploy Workers, or link a live host.

## Motivation

Axo already has host registration, retained host/session metadata, outbound daemon relay connections, and a browser terminal. The API Worker currently treats Cloudflare Access as its edge perimeter and synthesizes `client` or `daemon` principals from route paths. Axod has no credential it can use when that edge perimeter returns an Access login redirect. A shared secret embedded in Axo would be extractable and would give every installation the same revocation boundary.

Users need a simple first-run path: sign in on the Axo website, authorize one host, then let that Mac reconnect in the background without retaining the user's browser session or Cloudflare OAuth grant. One-time pairing separates account authentication from device enrollment and gives each host its own revocable credential.

This changes the security model and storage ownership across the app, API, protocol, and daemon. It needs a reviewable contract before implementation.

### Current source boundary

The first implementation step has moved product code out of site directories:

- [`packages/axo-api-worker/src/access.ts`](../../packages/axo-api-worker/src/access.ts) still makes synthetic edge principals; the API does not yet verify an Axo account or device credential.
- Legacy `/v1/*` routes still use synthetic edge principals and the unassigned `private-fleet` directory. Account-scoped `/api/v1/*` routes use `AxoAccountManager`; they must never fall back to legacy ownership or principals.
- [`packages/axo-api-worker/src/axo-host-directory.ts`](../../packages/axo-api-worker/src/axo-host-directory.ts) remains only for legacy/unassigned host data; new account hosts and snapshots are stored in their owning account manager.
- The app and Worker implementations, their tests, and runtime dependencies now live in `packages/axo-web-app` and `packages/axo-api-worker`. The `sites/*` directories contain thin entrypoint shims and deployment configuration.
- The current production Access policies have not been changed or inspected as part of this implementation.

## Goals

- Let any Cloudflare identity establish an Axo account through the public `axo.leostera.dev` experience; keep every account's user data in its own account Durable Object.
- Serve the landing page at `/`, the app at `/app`, and authentication, API, and relay routes under `/api` on one public origin.
- Keep authorization-code exchange on the Worker and any confidential OAuth client secret in a Worker secret; never embed Cloudflare OAuth credentials in Axo binaries or hand them to `axod`.
- Link each host through a human-entered, eight-character, expiring, single-use pairing code.
- Give each `axod` instance a distinct credential, revocable independently and valid only for its enrolled host.
- Give an authenticated account full control of its own hosts, and linked hosts the full currently supported Axo protocol in v1; do not introduce per-method or per-session capabilities yet.
- Make the account the owner of persistent host records and terminal-free session metadata.
- Make authorization derive from validated credentials and account ownership, never a caller-selected URL role, host UUID, or email address.
- Keep Worker, Durable Object, and web application logic in `packages/*`, with `sites/*` limited to deployment config and thin shims.
- Preserve offline/stale host metadata, bounded relay behavior, and the rule that terminal bytes and commands are not persisted as account metadata.

## Non-goals

- A shared application-wide bearer secret, a shared per-user host token, or a Cloudflare Access service token embedded in the app.
- Broad Cloudflare account API access. Axo needs the OAuth permission required to identify the user, not permission to manage Cloudflare resources, deploy Workers, or use Workers AI.
- Sending Cloudflare OAuth access/refresh tokens to `axod` or using them as host credentials.
- Per-method or per-session Axo capability restrictions in v1; all current protocol capabilities are available for the user's own linked hosts.
- Team sharing, multi-user roles, host transfer, paid plans, account recovery, or multiple sign-in providers in the first slice.
- Storing terminal output, command input, shell history, or prompts in account or host Durable Objects.
- Changing production Cloudflare Access policies, OAuth client settings, DNS, or deployments as part of accepting this RFD.

## Guide-level explanation

### Mental model

There are three different credentials, with different owners and lifetimes:

| Credential | Held by | Purpose | Lifetime / revocation |
| --- | --- | --- | --- |
| Cloudflare OAuth grant | Axo Worker only | Prove the user signed in; obtain the Cloudflare subject | Cloudflare-managed; never used by `axod` |
| Axo web session | Browser cookie, validated by Axo Worker | List/manage the user's account and create/revoke host links | Axo-managed, expiring and server-revocable |
| Host credential | One `axod`, in macOS Keychain | Connect/register/heartbeat for exactly one linked host | Per-host; revoked by unlinking that host |

The pairing code is a fourth, temporary value: eight Crockford Base32 characters (40 random bits), shown as `XXXX-YYYY`. It authorizes exactly one redemption and is discarded after linking. It is not the credential used for normal relay connections.

### Example: sign in and link a Mac

1. The user opens `https://axo.leostera.dev/`, can view the landing page, and opens `/app` to choose **Sign in with Cloudflare**.
2. The browser navigates to `/api/auth/cloudflare/start`. The Worker creates `state` and PKCE values, then redirects to Cloudflare's consent/login page.
3. Cloudflare returns the authorization code to the fixed `/api/auth/cloudflare/callback` URL. The Worker verifies state, exchanges the code, calls userinfo, and maps the verified subject to an Axo account ID. It creates an Axo session and redirects to `/app`.
4. The user chooses **Link a Mac**. The Worker creates an eight-character Crockford Base32 code formatted `XXXX-YYYY`, tied to that account and expiring after ten minutes. The web app displays the code once with copy and **Open Axo on this Mac** actions; the latter uses `axo://pair/<code>`.
5. Axo registers the `axo` URL scheme and routes valid pairing links to Settings → Remote Access. The user can also type or paste the code there, then explicitly chooses **Link this Mac**. The app passes it to `axod` through local RPC. `axod` generates a unique random host credential, stores it in Keychain, and persists only its public credential ID and the pairing-time host generation in the private relay config before redeeming the code over TLS with host metadata.
6. The Worker locates the account from the code's short-lived pairing index. The account Durable Object atomically consumes the code, creates host membership, and stores only the host credential verifier. `axod` then authenticates its outbound WSS connection with that credential and receives the full currently supported protocol for that host.
7. The web app lists the host and retained terminal-free session metadata. The owner can revoke the host; revocation closes its active relay, rejects future reconnects, and retains last-known metadata as offline/stale.

```mermaid
sequenceDiagram
  actor User
  participant Web as axo.leostera.dev/app
  participant API as axo.leostera.dev/api
  participant CF as Cloudflare OAuth
  participant Account as AxoAccountManager DO
  participant Mac as Axo Settings
  participant Daemon as axod

  User->>Web: Sign in with Cloudflare
  Web->>API: Navigate to /api/auth/cloudflare/start
  API->>CF: Authorization Code + PKCE
  CF-->>API: Callback with code/state
  API->>CF: Exchange code; fetch userinfo
  API->>Account: Resolve subject; create Axo session
  API-->>Web: HttpOnly Axo session cookie; redirect to /app
  User->>Web: Link host
  Web->>API: Create pairing code (Axo session)
  API->>Account: Store pairing verifier + expiry
  API-->>Web: Display XXXX-YYYY once
  User->>Mac: Type or paste XXXX-YYYY; Link
  Mac->>Daemon: Local axo.relay.link(code)
  Daemon->>API: Redeem code + host credential verifier
  API->>Account: Route lookup; atomically redeem
  Account-->>Daemon: Linked host / success + account routing ID
  Daemon->>Account: WSS with per-host credential
  Account->>Account: Validate credential; host and route socket
```

## Reference-level explanation

### Architecture and boundaries

#### Cloudflare OAuth and Axo web session

The landing page and app are served from `https://axo.leostera.dev/` and `https://axo.leostera.dev/app`; the API, OAuth callback, and relay use `/api/*` on that same public origin. Configure the OAuth application for sign-in by any Cloudflare identity and perform the Authorization Code + PKCE (`S256`) flow at the Worker using the credential model Cloudflare supports for that audience. Keep any confidential client secret only in a Worker secret; never put it in browser code or a binary. Use the exact callback URI `https://axo.leostera.dev/api/auth/cloudflare/callback`. Do not derive callback/return URLs from an untrusted `Host` header. Validate `state`, the PKCE verifier, callback URI, and an allowlisted post-login destination. Validate the chosen Worker/assets path routing in isolated deployment tests before changing production routing.

At callback, Axo calls Cloudflare userinfo and uses the verified subject—not email—as the external identity. Map `(Cloudflare OAuth issuer, sub)` to one immutable, random Axo account ID. Store email/name only as mutable display metadata. Do not treat the selected Cloudflare account ID as Axo's account identity; no Cloudflare API account selection is needed for this feature.

Axo creates its own opaque, high-entropy browser session. Set it as a host-only, `Secure`, `HttpOnly`, `SameSite=Lax` cookie for `axo.leostera.dev`; store only a session digest and account ID with an expiry/revocation state. The app and API are same-origin, so product calls do not rely on cross-origin CORS. Mutating cookie-authenticated endpoints validate the exact `Origin` (`https://axo.leostera.dev`) and an anti-CSRF token. Logout revokes the Axo session. The Cloudflare OAuth token is not the Axo API session and is not sent to browser JavaScript.

Axo has no per-method or per-session authorization tiers in v1: a signed-in user has full control of their own Axo account and linked hosts. This is separate from Cloudflare OAuth permissions. Request only the Cloudflare OAuth scope necessary to resolve the identity; do not request Workers, AI Gateway, account-management, or `offline_access` scopes. The exact identity/userinfo scope must still be validated with the OAuth Client configuration before registration.

#### Account-scoped coordination

Accept any Cloudflare identity; no Cloudflare-account membership allowlist is required. Use a minimal global identity index from `(issuer, subject)` to a random internal Axo account ID. That index contains no profile, host, session, or terminal data. Store each user's account profile, sessions, pairings, hosts, host-owned metadata, bounded RPC correlation, presence, and live host/browser WebSockets in that user's SQLite-backed `AxoAccountManager` Durable Object. Keep the deployed Durable Object export name `AxoAccountDirectory` as a stable storage identity while evolving its implementation into the account manager, so existing profile/session rows are reused rather than abandoned. Relay tables are keyed by host ID inside the account object, so multiple hosts can share one account DO without sharing routes, pending calls, subscriptions, or delivery budgets. It is the single authority for credential checks, revocation, host metadata, and relay lifecycle.

Account and host IDs may be used as routing inputs, but are never authorization by themselves. A short-lived, sharded `AxoPairingIndex` maps a keyed pairing-code verifier to an account ID and pairing ID so an eight-character code can locate its account; it is only a routing index, not an owner of pairing state. It contains no account profile, host metadata, session data, or terminal content. The account manager remains authoritative: it atomically consumes the pairing and registers the host in one SQLite transaction. Account IDs and host IDs returned during redemption are public routing hints; the host credential remains the only daemon authority.

Every host-owned record is scoped to exactly one Axo account and references a persistent Host record. On disconnect, keep last-known metadata and derive offline/stale status. Do not persist terminal content.

#### Pairing code and host credential

- Generate eight characters using a cryptographic RNG from Crockford Base32 (`0123456789ABCDEFGHJKMNPQRSTVWXYZ`), displayed as `XXXX-YYYY`. This provides 40 bits of entropy while avoiding visually ambiguous characters.
- Expire codes after 10 minutes and permit one successful redemption. A short-code space is safe only with strict online throttling: rate-limit issuance and every failed lookup by source, apply a global abuse limit, and enforce per-account pending-code limits. Set exact thresholds before rollout and test them under distributed guessing assumptions.
- Store an HMAC-based verifier in the pairing index and account DO, never the raw code. The index maps verifier to account/pairing IDs and a bounded 24-hour retry horizon; the account DO enforces the 10-minute redemption expiry and owns pending/consumed state. Retaining the route briefly permits a same-host/credential retry after a lost response without allowing a new redemption. Detect collisions before displaying a code and regenerate on collision.
- Display the raw code once in the web app with a copy button. Redeem with TLS. The account DO atomically consumes the code and registers the host. An identical retry from the same host ID and credential verifier may return the same success after a lost response; a different host/credential must fail.
- Generate a fresh 256-bit random host credential per Mac in `axod`; save it to Keychain before attempting redemption. Send it once during redemption. Store only its digest server-side. Never place it in a URL, `relay.json`, logs, analytics, UI persistence, or source code.
- Bind the credential to one account and one host. It authorizes the daemon connection and host operations only for that host; it cannot list an account's hosts or operate another host. Within that boundary, v1 enables all currently supported Axo protocol capabilities, including existing session and terminal controls. Do not add per-method or per-session restrictions until a later capability-policy design.
- Include a token/key identifier or account/host routing hint so the Worker can reach the correct Account DO. The identifier is public and not sufficient to authenticate. Verify the secret against the stored hash and reject revoked credentials.
- An owner can revoke/rotate a host credential from the web app. Revocation rejects the old credential immediately, closes active daemon sockets, fences in-flight relay work, and leaves the Host record offline/stale. Re-linking an existing host in the same account replaces its credential while preserving its host identity and metadata. Cross-account transfer is out of scope.

The `axod` relay config contains endpoint and host metadata plus the public credential ID; the host credential itself remains in Keychain. The pending credential ID and pairing-time host generation are persisted before redemption so a retry after a lost response or daemon restart can reuse the identical Keychain secret and redemption tuple, even though the active daemon generation rotates on restart. Remote Access Settings accepts typed or pasted `XXXX-YYYY`, validates its shape locally, and submits it through local RPC; the `axo://pair/<code>` deep link opens that same settings section. The app and daemon keep the pairing code only in memory and never expose or persist the returned host credential outside Keychain.

#### Authorization and API behavior

Replace `edgePrincipal(role)` for product routes with two verified principal forms:

- **Account principal:** derived from a valid Axo web session; authorized for that account's host list, host/session snapshots, pairing creation, and host revocation.
- **Host principal:** derived from a valid per-host credential; authorized only for that host's daemon routes and host-owned publication methods.

The URL's `client`/`daemon` segment is a routing hint, never the source of role/identity. Reject a host credential on client routes, a browser session on daemon routes, cross-account host IDs, wrong host IDs, stale host generations, and revoked keys. Browser HTTP and WebSocket routes require the exact app Origin `https://axo.leostera.dev`; Axod daemon connections may omit Origin, but still require the host credential.

Host credentials go in an `Authorization` header on the WebSocket upgrade, never in a query string. Strip caller-supplied internal identity headers and forward only a newly constructed context to the account manager, which independently checks account membership, session state, and the host credential before upgrading. Recheck host-account ownership before dispatching remote controls. A route that merely names a UUID must never register a new user-owned host.

#### Proposed HTTP surface

Exact names and schema envelopes remain subject to the shared v1 schema review. The required operations are:

| Operation | Authentication | Effect |
| --- | --- | --- |
| `GET /api/auth/cloudflare/start` | Browser navigation | Start state/PKCE-bound Cloudflare OAuth flow |
| `GET /api/auth/cloudflare/callback` | OAuth callback + flow cookie/state | Resolve external identity and issue Axo web session |
| `POST /api/auth/logout` / `GET /api/auth/me` | Axo web session | Revoke session / report signed-in account |
| `POST /api/v1/account/host-pairings` | Axo web session + CSRF/Origin checks | Create and return one-time pairing code |
| `POST /api/v1/host-pairings/redeem` | Pairing code | Locate account, atomically consume code, register one host credential |
| `GET /api/v1/account/hosts`, `GET /api/v1/account/hosts/:host/sessions` | Axo web session | List only hosts/snapshots owned by account |
| `POST /api/v1/account/hosts/:host/revoke` | Axo web session | Revoke this account's host credential and close relay |
| `/api/v1/account/hosts/:host/client` WebSocket | Axo web session | Full current protocol control of an owned host |
| `/api/v1/accounts/:account/hosts/:host/daemon` WebSocket | Per-host credential | Route to the account manager, then authorize the exact host credential |

No endpoint accepts a caller-selected account ID as proof of authority. New or changed request/result objects are versioned in `@axo/protocol/v1` and canonical JSON schemas/fixtures before client implementation.

### Data model and interfaces

Conceptual records:

- Global identity index: `(issuer, subject) -> accountId`; contains only the identity key and internal account ID.
- In each `AxoAccountManager` Durable Object, `account`: internal Axo account ID, creation time, mutable display metadata.
- In each account manager, `sessions`: session ID digest, created/expiry/revoked timestamps.
- In each account manager, `pairings`: keyed verifier, creation/expiry, consumed host ID, consumed credential verifier for safe identical retry.
- In the short-lived pairing index, `codeVerifier -> accountId/pairingId/expiry`; no user profile or host/session data.
- In each account manager, `hosts`: host ID, label, kind, linked/revoked state, created/last-seen timestamps, credential ID/verifier, host generation.
- In each account manager, `host_sessions`: strict terminal-free snapshots, host ID/generation, updated time.
- In each account manager, `route`, `groups`, and `pending` tables plus hibernatable WebSocket attachments: per-host live relay state and transient correlation only; terminal bytes are never persisted.

Account membership is one Cloudflare identity per Axo account for v1. The design can later add members/roles without treating email as a primary key or sharing host credentials.

The daemon's local `axo.relay.link` operation accepts an eight-character pairing code and returns a redacted result with host/account status, never the host credential. The Rust daemon generates and stores its host credential in Keychain before redemption, sends it once over TLS so the Worker can store its keyed verifier, and cleans up the temporary pairing material from memory after redemption. Local RPC errors, tracing, crash reports, and test logs redact the pairing code.

### Lifecycle and failure semantics

- **Cloudflare denies login or OAuth fails:** create no Axo account/session. Return a safe error; do not persist a partial account identity.
- **Invalid state, stale callback, wrong verifier, or mismatched redirect:** reject; do not exchange the code or create a session.
- **Pair code expires or was already redeemed by another host:** reject without host creation. The user generates a fresh code.
- **Worker commits redemption but response is lost:** an identical retry with the same pairing code, host ID, and credential hash returns idempotent success. A changed host ID/hash is rejected.
- **Daemon crashes during link:** the private relay config retains the pending credential ID and pairing-time host generation, and Keychain retains the secret. The user can re-enter or re-open the still-valid code to retry the identical redemption tuple. If the pairing code has expired, the user creates a fresh code; the same pending credential may be used. Never retry with a different host credential under the same consumed code.
- **Host disconnects:** relay presence expires; retain host and snapshots as offline/stale.
- **Host credential is revoked:** reject reconnect and close existing socket; retain metadata as offline/stale. Do not infer that local PTYs stopped or delete Axod state.
- **Account session is revoked:** browser access stops; host credentials remain linked until separately revoked. Browser sign-out does not silently unlink Macs.
- **Account or host DO unavailable:** fail closed for auth/mutations; do not fall back to synthetic edge principals or a global shared token.
- **Cloudflare OAuth outage after a valid Axo session:** existing Axo session/host credentials continue until their own expiry/revocation. Reauthentication is needed only when the Axo web session expires or is revoked.

### Invariants

- OAuth credentials never leave the Worker; no Cloudflare OAuth credential is stored by Axod.
- Every pairing code is a 40-bit account-bound bearer capability, short-lived and single-use; strict per-source/global throttling, collision checks, and atomic consume are mandatory because the human-entered code is not relied on for entropy alone.
- Every host secret is random, unique, scoped to one account and host, stored in Keychain on the Mac, and revocable without affecting other hosts.
- Raw pairing codes and host credentials are absent from logs, URLs, persisted relay config, browser local storage, and analytics.
- Account identity is keyed by verified issuer + subject; email is display metadata only.
- Worker routes derive roles from verified session/credential, not route names or caller-controlled identity headers. Authenticated users have full control of their own accounts in v1; no per-method/per-session capability tiers are enforced.
- Every Host, session snapshot, relay, and credential is owned by one persistent Axo account.
- Disconnect, expiry, and revocation change presence/authorization but do not erase last-known metadata or imply that local work stopped.
- Terminal bytes and commands are not persisted server-side.

### Compatibility and migration

This replaces the current synthetic global principal and `private-fleet` ownership model; it is not wire-compatible with those role assumptions. Update canonical v1 schemas/fixtures, `RemoteAxoApi`, `HostRelayConnection`, and `axod` as one coordinated protocol transition. Do not add compatibility behavior that silently assigns old global hosts to the first account that signs in.

The existing deployed host directory has no trustworthy per-user owner. Keep it as legacy/unassigned data during migration; do not infer ownership from `hostId`, label, email, or a route. A migration/adoption procedure must be explicitly designed and tested before any old host/session metadata is made visible in the new account model. The new credential can preserve host identity only after an approved pairing flow; a host ID alone does not prove ownership.

The target `axo.leostera.dev` landing page, `/app`, and `/api/*` product endpoints are public and must be reachable without Cloudflare Access login; Axo OAuth sessions and host credentials provide product authorization inside the Worker. Access is not the Axo account or host authorization layer. Remove or bypass any existing Access gate for these public routes as an explicit rollout operation, and verify that routing does not reintroduce an Access gate in front of OAuth callbacks, one-time redemption, or WebSockets. This RFD chooses the public same-origin product surface; it does not itself change production Access controls, DNS, or deployments.

### Security, privacy, and observability

Use HTTPS/WSS only. Apply exact callback/return-origin allowlists, OAuth state + PKCE, CSRF/Origin defenses for cookie-authenticated mutations, bounded request bodies, pairing issuance/redeem limits, and no-store responses for secrets. Compute the pairing verifier as a keyed HMAC so a storage-only disclosure does not permit offline enumeration of the 40-bit code space; keep the HMAC key in a Worker secret. Compare verifiers with a constant-time primitive. The 256-bit host credential is stored as a cryptographic verifier; never log SQL parameter values.

Structured logs may record operation type, account/host opaque IDs, result category, bounded timing, host generation, and credential key ID. Do not log OAuth codes, OAuth tokens, pairing codes, host credentials, cookies, full request headers, terminal content, command bodies, paths, or raw request bodies. Error responses must not reveal whether another account owns a host.

The pairing code is intentionally a bearer capability during its short lifetime. Anyone who obtains it first can enroll one host into the account. Its 40-bit entropy is not relied on alone: ten-minute expiry, single-use atomic consumption, strict per-source and global lookup throttles, bounded issuance, explicit code display/copy and typed-or-pasted entry, immediate host listing/revocation, and audit metadata limit exposure. The code does not prove hardware identity. Per-host credentials provide independent post-enrollment revocation, not hardware-backed attestation.

### Rollout and validation

No production OAuth client, Access policy, DNS, Worker, host record, live daemon, or LaunchAgent is changed by this proposal. Before a rollout:

1. Make the package boundary the implementation starting point: move Worker/API/domain logic and tests to `packages/axo-api-worker`, and the React application/UI to `packages/axo-web-app`; leave `sites/*` as deployment configuration and thin shims. Keep `packages/axo-api` as protocol/schema contracts.
2. Register a public Cloudflare OAuth Client for `axo.leostera.dev` so any Cloudflare identity can sign in. Public visibility is permanent and requires verified domain ownership. Validate the minimal identity/userinfo permission and token lifecycle with a test client; do not request Cloudflare resource-management permissions.
3. Validate same-origin routing in an isolated Worker setup: landing `/`, app `/app`, API/auth/relay `/api/*`, OAuth callback, session cookie, and daemon WSS. Confirm the app and API paths are publicly reachable without Access while still enforcing Axo authorization.
4. Implement schema-first account, session, pairing-index, host-credential, and ownership contracts; test rate limits, code collision/replay/races, atomic account-DO consumption, and cross-account isolation in isolated Miniflare/workerd.
5. Implement the Worker OAuth callback and account identity mapping with credentials stored only as Worker secrets; implement `axod` Keychain storage, eight-character code entry/paste UI, and local pairing RPC in isolated tests. Do not use the production LaunchAgent or daemon.
6. Validate real OAuth consent/callback, account identity stability, 10-minute expiry, distributed lookup throttling, idempotent redemption, full v1 protocol access for an enrolled host, per-host revocation, relay `101`, offline/stale retention, and absence of token leakage in logs.
7. Plan legacy host metadata migration/adoption and rollback before enabling public auth or switching existing hosts.
8. Repackage `dist/Axo.app` after validated Mac changes. Do not launch or install it unless explicitly requested.

Rollback disables new pairing/session admission and fences API host routes; it does not delete host metadata or local credentials. Existing local Axod work continues. A rollback must not restore route-derived synthetic daemon authority or re-enable two simultaneous ownership paths.

## Drawbacks

- OAuth client creation, public-domain verification, identity permissions, cookie sessions, and identity mapping add infrastructure beyond the original edge-protected private relay.
- A public API has more reachable attack surface. Every Worker method must enforce its app-level principal correctly; Cloudflare Access is not relied on to authorize Axo product actions.
- An eight-character pairing code is user-friendly but has only 40 bits of entropy. It requires careful global and per-source rate limiting, collision handling, and short expiry.
- The one-time code remains a bearer capability until redeemed. Typed/pasted entry is convenient but retains a short race window.
- Moving application logic into packages adds package boundaries and build/test wiring that must remain simple for the thin site shims.
- Keychain integration and background-daemon access rules need Mac packaging/signing tests.
- Revocation, session expiry, host metadata migration, and account deletion need explicit product/operational behavior.

## Rationale and alternatives

### Proposed design

This best matches the user flow: login happens in the Axo web experience; a user explicitly authorizes each host; background Axod receives only a host-specific, revocable secret. Signed-in users have full control over their own Axo account and hosts in v1. The design borrows Coil's server-side OAuth code exchange and subject mapping while deliberately not retaining Cloudflare API grants in Axod or using them to operate Cloudflare resources.

### Global shared secret embedded in Axo

Rejected. Extraction from one app copy compromises every installation, and rotation requires synchronized app release and server changes. It is not per-user or per-host revocable.

### One permanent account token pasted into every Mac

Rejected as the normal design. It is easy to understand but gives all linked Macs the same authority; it is difficult to revoke one lost device without disrupting the others. A one-time code plus per-host credential keeps the UX almost as simple and isolates revocation.

### Direct native Cloudflare OAuth with PKCE

Cloudflare supports Authorization Code + PKCE for public native clients, but Axo's desired path starts and completes sign-in at the web app. It would also hand Cloudflare OAuth tokens to the Mac and couple host connectivity to user-grant lifecycle. Keep the native app's role to redeeming an Axo one-time pairing code.

### Cloudflare Access or Managed OAuth as the product identity

Access is appropriate as an edge perimeter for private tools; Managed OAuth lets a non-browser client access an Access-protected app. Neither is the same as Coil's Cloudflare OAuth Client sign-in or Axo's account/host-link model. Keeping Access as an outer gate for public product routes would add a second identity/authorization system and does not grant Axod a usable host identity. Access remains an optional additional control only if its behavior is explicitly designed and tested.

### Coil's full server-side Cloudflare API grant

Coil stores Cloudflare access/refresh grants server-side because it uses them to call Workers AI and AI Gateway on behalf of the user. Axo needs identity and host ownership, not account API power. Do not request Coil's AI/account scopes or store a refresh grant just because the UI says “Sign in with Cloudflare.”

### Do nothing

The Worker remains behind Access with synthetic route roles and the daemon cannot authenticate without an Access identity or service token. Host discovery remains effectively tied to the current private Access boundary, not an Axo-owned account and independently revocable hosts.

## Prior art

- **Coil** (`acoyfellow/coil`, inspected at `e142d668ccd43e4b3648a579c0318ad04d266e26`) uses a server-side Cloudflare OAuth Client, PKCE/state, userinfo subject as owner key, Worker-held Cloudflare grants and its own signed session cookie. It also has a separate Cloudflare Access mode. Axo adopts the Worker-side code exchange and subject-key lesson, but does not need Coil's AI/account API grants. See the [commit-pinned Coil auth source](https://github.com/acoyfellow/coil/tree/e142d668ccd43e4b3648a579c0318ad04d266e26/src/auth).
- The superseded [RFD0008](https://github.com/leostera/axo/blob/d885961eadd9853eb7a4be9fb2439344e8094f24/docs/rfds/RFD0008-private-multi-machine-control-plane.md) explicitly deferred accounts and pairing in favor of a private Access-only relay. This proposal revisits that boundary based on the user-selected account and host-link product flow; old RFD text is historical, not current behavior.
- Cloudflare's [OAuth Client docs](https://developers.cloudflare.com/fundamentals/oauth/create-an-oauth-client/) distinguish server-side clients with protected secrets from public desktop clients using PKCE, map scopes to Cloudflare API permissions, and require domain verification before a client can be made public. They also state that making a client public is permanent.
- Cloudflare's [SQLite Durable Object storage docs](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/) document `transactionSync` for synchronous SQLite operations; it rolls back on exception. This supports atomically consuming a pairing code and inserting the host record within the same account object, not across multiple objects.

## Unresolved questions

### Before acceptance

The product choices raised in review are incorporated: any Cloudflare identity may create an Axo account; each account's user data is stored in its own account Durable Object; `axo.leostera.dev` is the public landing/app/API origin; v1 grants full Axo functionality within the authenticated account/host boundary; host linking uses a typed-or-pasted `XXXX-YYYY` code; and site projects are thin deployment shims over packages.

- How should existing global `private-fleet` hosts/snapshots be preserved and optionally adopted without assigning them to whichever account signs in first?

### During implementation

- Validate Cloudflare's public-audience OAuth client requirements, server-side PKCE/token exchange, and the minimum identity/userinfo permission; do not request Cloudflare resource-management grants.
- Exact per-source/global pairing lookup thresholds, maximum pending codes per account, HMAC key rotation, and pairing-index sharding/collision handling.
- Exact Axod Keychain item access policy and credential rotation protocol.
- Exact `/app` and `/api` Worker/assets path-routing configuration and v1 API schema migration.
- Whether OAuth tokens should be revoked immediately after reading userinfo or left to expire; no token is needed for later Axo API requests.

### Out of scope

- Host-to-host sharing, organization accounts, multiple identity providers, billing, password recovery, hardware attestation, remote file transfer, and terminal-content persistence.

## Future possibilities

- Add team membership and host sharing using explicit account roles without sharing device credentials.
- Add verified HTTPS universal links for stronger domain-to-app association while retaining the typed/pasted fallback and the same pairing grant semantics.
- Add host public keys and proof-of-possession if the risk warrants more than a revocable bearer credential.
- Add multiple IdPs by mapping several issuer/subject pairs to one internal Axo account through an explicit account-linking confirmation flow.
