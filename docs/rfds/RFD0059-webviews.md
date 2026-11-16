# RFD0059 - Axo: Webviews

- Feature Name: `axo-webviews`
- Status: Draft
- Author: leostera
- Start Date: 2026-11-15
- Updated: 2026-11-15
- Document Type: Proposal
- Amends: [RFD0030](RFD0030-assets.md)

## Summary

An agent calls `webview({ html | path, title, alt })` to show the person a page it wrote: a diagram, a chart, a sketch of an idea. The page is stored as an asset. The web and the phone draw it inline in the transcript, where the tool call was, with no frame, border or scrollbar, sized to its content and in the app's colours, so it reads as part of the message. Pi's terminal shows a link.

- **The page never runs on `axo.leostera.dev`.** It is served from a separate content domain, as a sandboxed document with an opaque origin, so it can't act as the person.
- **Opening a page needs the person's sign-in.** The app asks the hub for a short-lived URL bound to one page of one account. The transcript holds the asset, never the URL.
- **Three phases:**
  1. Show the page inline, on the web and the phone. This RFD specifies it in full.
  2. Clicks in the page become messages to the agent. Outlined here; it gets its own spec first.
  3. Pages of several files, and updating a page in place. Outlined here.

## Motivation

- **Agents explain in text and ASCII art.** A data flow, a state machine, a layout or a comparison is clearer drawn. Models write good HTML, SVG and Mermaid, and today none of it is shown.
- **Showing is part of thinking together.** "Here are three layouts, which one?" is a page, not a paragraph. It is the first step towards pages the person can click to answer (phase 2).
- **The pieces exist:** assets store files by hash with Workers Cache in front (RFD0030), a Mac can upload with its credential (`crates/axo-relay/src/assets.rs`, `upload`), and the web and the phone render each tool call from Pi's records.

## Guide-level explanation

### The agent shows a diagram

Leo asks: *how does a prompt get from the phone to Pi?* The agent writes a page with an SVG sequence diagram and calls:

```js
webview({
  title: "A prompt from the phone to Pi",
  alt: "Sequence diagram: phone → ClientDO → HostDO → axod → pi-axo → Pi, with the receipt flowing back.",
  html: "<!doctype html><html>…</html>",
})
```

On his phone, the diagram appears in the agent's message, between two paragraphs, the width of the text, in the app's colours, light or dark. There is no box around it: it scrolls with the message. Tapping a link in it opens Safari. A long press offers *Open* and *Copy link*.

On the web it is the same, in the transcript column. Hovering shows a small *Open* button in the corner, which opens the page on its own.

In Pi's terminal on the Mac, the tool result reads:

```
Shown "A prompt from the phone to Pi" (14 KB): https://axo.leostera.dev/w/sha256:9f2c…
```

The link opens the page in the browser, through the same sign-in.

### A page built with tools

An agent can build the page with its tools and show the file: `webview({ path: "out/report.html", title, alt })`. The page's bytes then never pass through the model's context, which matters for a page generated from data.

## Reference-level explanation

### The tool

pi-axo registers `webview` (`packages/pi-axo/src/webview.ts`):

- **Parameters:** `{ html?: string, path?: string, title: string, alt: string, height?: number }`, exactly one of `html` or `path`.
  - `title`: 1 to 120 characters; the asset's name is `<title>.html`, with characters a name can't hold replaced.
  - `alt`: 1 to 2,000 characters. Clients show it while the page loads, to screen readers, where they can't draw the page, and on share pages.
  - `height`: the height in CSS pixels the client reserves before the page reports its own, 80 to 2,000; 320 if absent.
- **Size:** at most 1 MiB of HTML. A webview is one file: CSS and JavaScript inline, or from the CDNs the page may load (below).
- **What it does:** it reads `path` relative to the Session's working directory if given, asks axod to save the bytes as an asset of type `text/html` (`axo.assets.save`, below), and answers:
  - `content`: `Shown "<title>" (<size>): https://axo.leostera.dev/w/sha256:<hex>`.
  - `details`: `{ webview: 1, asset: "sha256:<hex>", title, alt, height, size }`. Clients render from `details`, never from the arguments, so `html` and `path` render alike.
- **Failures** are tool errors the agent sees: no `html` or `path`, both, too large, a file it can't read, or the Mac signed out or offline (*the page could not be stored: this Mac is not connected to Axo*). No page is shown with nothing stored behind it.
- **The brief** (`brief.ts`) gets one line: *To show the person a diagram, chart or sketch, write a self-contained HTML page and call `webview`; use the app's CSS variables to match its colours. Pages can't use storage or the network, except scripts and styles from cdn.jsdelivr.net and esm.sh.*

### axod: `axo.assets.save`

A new method on the local socket pi-axo already uses: `axo.assets.save({ bytes: base64, name, mimeType })` answers the `Attachment`. It calls `assets::upload` with the Mac's credential, as screenshots from computer use do (`crates/axo-relay/src/computer.rs`). It only takes `text/html` in this change.

### Assets

- `text/html` joins `ASSET_TYPES` (`packages/axo-api/src/assets.ts`).
- **The app's own origin never serves it as a page.** `GET /api/v1/account/assets/<hash>` keeps answering it with `Content-Disposition: attachment` and `Content-Security-Policy: default-src 'none'; sandbox`, as for every type outside `INLINE_ASSET_TYPES`. A test pins this.

### The content domain

A second host served by the same Worker, `axo-public-app`, and only for webviews. This RFD calls it `<content>`. Which domain it is is an unresolved question; the recommendation is a separate registrable domain.

- **Why separate:** a document on `axo.leostera.dev` could call the API with the person's cookie. The sandbox already gives each webview an opaque origin, which has no cookies and no storage, and makes requests cross-site. A different registrable domain also holds if a sandbox is ever dropped by mistake.
- **One host, no subdomain per page:** every sandboxed document has its own opaque origin, so pages already can't reach each other. That avoids wildcard DNS and certificates.
- **Routes:** `GET https://<content>/<hex>?t=<token>` and nothing else. Every other path answers `404`. The Worker's router dispatches on the `Host` header before any app route, so no app route answers on `<content>`.

### Opening a page: view tokens

1. **The client asks.** `POST /api/v1/account/webviews/<hex>/view`, signed in as any client is. The hub checks the asset is in the account and is `text/html`, and answers `{ url: "https://<content>/<hex>?t=<token>", expires }`.
2. **The token** is `base64url(accountId, hex, expiry) + "." + base64url(HMAC-SHA256(WEBVIEW_SECRET, …))`. It expires 5 minutes after it is made, and grants one page of one account. `WEBVIEW_SECRET` is a new secret, used for nothing else; it does not reuse `SESSION_SECRET`.
3. **The content host** checks the HMAC, the expiry, and that the path's hash is the token's, then reads the asset through `AxoAssetCache` with the token's account in `props`, exactly as the app's own read does. A bad token answers `403`, a missing asset `404`, both `Cache-Control: no-store`.
4. **The URL is never stored.** Not in the transcript, not in the tool result, not on disk. A client asks again each time it draws the page; a cached token is reused only until a minute before it expires.
5. **What a leaked token gives:** the one page, for at most 5 minutes. A page can read its own URL, and with it its own token, which only gives back itself.
6. **The app page** `/w/sha256:<hex>` is a route of the web app: signed in, it asks for a URL and shows the page full width, as it is shown inline. It is what Pi's link opens.

### What the content host answers

- **Body:** the asset's HTML, with a small script, the *bootstrap*, inserted at the start of `<head>` by `HTMLRewriter` (a whole `<html><head>` is added around a fragment).
- **Headers:**
  - `Content-Type: text/html; charset=utf-8`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `Cache-Control: private, no-store`.
  - `Content-Security-Policy`:
    - `sandbox allow-scripts allow-popups allow-popups-to-escape-sandbox`: the document has an opaque origin even when opened on its own, not in a frame.
    - `default-src 'none'`
    - `script-src 'unsafe-inline' https://cdn.jsdelivr.net https://esm.sh`
    - `style-src 'unsafe-inline' https://cdn.jsdelivr.net`
    - `img-src data: blob: https://cdn.jsdelivr.net`, `font-src data: https://cdn.jsdelivr.net`
    - `connect-src https://cdn.jsdelivr.net https://esm.sh`
    - `frame-ancestors https://axo.leostera.dev`
    - `form-action 'none'`, `base-uri 'none'`
  - No nonce: a nonce would make browsers ignore `'unsafe-inline'`, and the agent's own scripts are inline.
- **Why the CDN list:** Mermaid, D3, Chart.js and the like, which agents reach for. A page can't send anything anywhere else, so it can't send off what the agent put in it.
- **Not cached across people:** the asset is cached as an asset (RFD0030); the page with its bootstrap is made per request, which is cheap.

### The bootstrap

About 2 KB of script, the same for every page, in `packages/axo-api-worker/src/webviews/bootstrap.ts`.

- **Theme.** It reads the theme from the URL's fragment, `#axo=<base64url JSON>`, which never reaches the server: `{ scheme: "light" | "dark", vars: { "--fg": …, "--bg": "transparent", "--muted": …, "--accent": …, "--border": …, "--font": …, "--mono": …, "--radius": … } }`. It sets them on `:root`, sets `color-scheme`, and adds a base stylesheet before the page's own: transparent background, the app's font and colours, no margin on `body`, `img, svg, canvas { max-width: 100% }`. A page that uses the variables matches the app; one that doesn't still sits on the message's background.
- **Size.** A `ResizeObserver` on `document.documentElement` reports the height, rounded to whole pixels, at most once a frame: through `window.webkit.messageHandlers.axo` in the phone's webview, through `parent.postMessage({ axo: "size", height }, "*")` in an iframe.
- **Links.** A click on a link is sent the same way as `{ axo: "open", url }` (only `https:`), and the client opens it outside: a new tab on the web, Safari on the phone.
- **Theme changes.** The client sends `{ axo: "theme", … }` when the person switches light and dark; the bootstrap applies it without reloading.
- **Trust:** the bootstrap runs in the page's own context, so the page can change it or send these messages itself. Clients treat every message as untrusted: they only take these three kinds, clamp the height, and only open `https:` URLs. In phase 1 nothing a page sends reaches the agent.

### The web

`packages/axo-web-app/src/chat/webview.tsx`, used where the transcript renders a tool call named `webview` whose result has `details.webview === 1`, in place of the tool card:

- `<iframe sandbox="allow-scripts allow-popups allow-popups-to-escape-sandbox" referrerpolicy="no-referrer" allow="" loading="lazy">`, no `allow-same-origin`, `border: 0`, `background: transparent`, full width of the text column.
- **`color-scheme` matches the app's**, or the browser paints an opaque backdrop behind a transparent frame.
- **Height:** `details.height` until the page reports its own; then the reported one, from 40 to 4,000 pixels, with no animation. A page taller than 4,000 pixels scrolls inside itself. The last height is kept in memory for the Session, so scrolling back doesn't jump.
- **Messages** from the frame are taken only when `event.source` is that frame's `contentWindow`.
- **Before it loads, and if it fails:** the `alt` text in the reserved space, muted. A failed token or a missing asset shows *This page could not be loaded* with the `alt` text.
- **Off screen:** `loading="lazy"` delays it, and a frame more than three screens away is replaced by its last height, so a long transcript doesn't run every page at once.
- **Hover:** an *Open* button at the top right opens `/w/sha256:<hex>`.
- **Share pages** (`/s/*`): people viewing a share have no sign-in, so a webview shows as its `alt` text and title. Showing webviews on public shares is a separate decision.

### The phone

`apple/AxoPhone/Sources/AxoPhone/WebviewBlock.swift`, rendered in place of the tool card, as on the web:

- A `WKWebView` with `WKWebsiteDataStore.nonPersistent()`, `isOpaque = false`, clear background, scrolling off, no link previews, and a script message handler `axo` for the bootstrap's messages.
- **Navigation:** only the token's URL loads in the view. Every other navigation is cancelled; a link the page asks to open goes to `SFSafariViewController` if it is `https:`.
- **Height** works as on the web: the reserved height, then the reported one, clamped, kept in memory.
- **Lifecycle:** made when the row appears, released when it is far off screen, keeping its height.
- **Long press:** *Open* (the page full screen, in the same kind of view) and *Copy link* (the `/w/` link).
- **Theme:** from `ChatColors`, through the fragment, and `{ axo: "theme" }` when the appearance changes.
- **Preview mode** `AXO_PHONE_PREVIEW_LIVE=webview` shows a Session with one webview, for UI tests and snapshots.

### The Mac and Pi

Pi's terminal shows the tool result, with the link. The Mac app draws Pi's terminal, so it does too. Drawing pages inside the terminal is the "Inline graphics" item of `docs/future-work.md`, not part of this RFD.

### Logging

The Worker logs `webviews.view` (account, hash, outcome: `ok`, `forbidden`, `expired`, `missing`) on the content host and `webviews.token` on the app's. axod logs `assets.save` with the type and size. No page's content is logged.

### Phase 2: clicks become messages (outline)

- The bootstrap exposes `axo.send(text, data?)`; the client turns it into a message to the Session, from the person, *through the webview "<title>"*, with the page's hash.
- **Only on a real click:** the parent checks its own `navigator.userActivation.isActive`, which a click inside the frame activates. On the phone, which can't see activation in the page, the message shows as a chip the person taps to send.
- **Limits:** at most 2,000 characters; one message per click; at most 10 a minute per page.
- **The agent** sees it as the person's message, marked as coming from the page, which the agent wrote but the person clicked.
- It sends through the mailbox once it exists, and through today's remote prompt until then.
- Its own spec, `specs/webviews/clicks.ts`, comes before it is built: a page can't send without a click, one click sends at most once across reloads and reconnects, and a message names its page.

### Phase 3: sites and updates (outline)

- **Several files:** `webview({ dir })` stores a folder as assets plus a manifest asset. The content host serves `/<manifest>/<path>`, with a token per manifest.
- **Updating in place:** `webview_update({ id, html | path })`. `details` gains a stable `id`, and each update is a new asset. Clients show the latest version where the first one was, and keep earlier ones reachable.
- **Publishing** past the person's sign-in (unlisted or public links) is the "Artifacts" item of `docs/future-work.md`, and needs its own RFD.

## Testing

- **Worker** (`packages/axo-api-worker/tests/webviews.test.ts`):
  - A token opens its page; another hash, another account, an expired token, a changed signature or no token answers `403`, with `no-store`.
  - The content host answers nothing but `/<hex>`; the app's routes answer `404` on it.
  - Every header and CSP directive above, exactly.
  - The bootstrap is inserted into a whole document, a fragment, and a document with no `<head>`.
  - `GET /api/v1/account/assets/<hash>` of a `text/html` asset on the app's origin answers `attachment` with the sandbox CSP.
  - `POST …/view` refuses an asset of another type, or of another account.
- **axod:** `axo.assets.save` uploads with the host credential and answers the attachment; it refuses types other than `text/html`.
- **pi-axo** (`test/webview.test.ts`): `html` and `path` both store and answer the same `details`; both, neither, too large, an unreadable file and a disconnected Mac are tool errors.
- **Web:** the frame's attributes; height clamping; a message from another frame is ignored; `open` with a non-`https:` URL is ignored.
- **Phone:** a UI test and snapshot in `AXO_PHONE_PREVIEW_LIVE=webview`, light and dark; a model test of the height clamp and navigation policy.
- **A hostile page, end to end, in a real browser, before release:** a page that calls `fetch("https://axo.leostera.dev/api/auth/me", { credentials: "include" })`, reads `document.cookie` and `localStorage`, posts a form, navigates its parent, and loads a script from another host. None of them may succeed. Then the same page opened on its own, by its `/w/` link.

## Drawbacks

- **A second host to run**, with its own DNS and certificate, and a new secret.
- **Pages are opaque to search and to the model:** both see the `alt`, not the drawing. The `alt` has to be good.
- **The HTML is in the transcript twice** when the agent passes `html`: in the tool call, and as an asset. `path` avoids the first.
- **Pages can't use storage:** `localStorage` throws in an opaque origin, and some libraries expect it.

## Alternatives

- **Render SVG and Mermaid only.** Safer, with no scripts, but no interaction and no charts that need code. It can come first anyway: fenced `mermaid` blocks are the first step of "Inline graphics".
- **`srcdoc` iframes, with no content host.** The web could put the HTML straight into a sandboxed `srcdoc` frame. But its CSP comes from the app's page, the phone needs a URL anyway, and Pi's link needs a page to open. One host serves all three.
- **A subdomain per page.** Redundant with opaque origins, and it needs wildcard DNS and a certificate for a second-level wildcard.
- **Cloudflare Access in front of the content host.** Access signs in with a cookie on the content domain, which a frame inside `axo.leostera.dev` would send as a third-party cookie, and Safari blocks those. View tokens minted for a signed-in person do the same job without it.

## Unresolved questions

Before acceptance:

- **Which domain is `<content>`?** (a) A separate registrable domain, such as a new `axo-content.dev`: separate for cookies and SameSite even if a sandbox is dropped, and Universal SSL covers it. It has to be bought. (b) A host under `leostera.dev`, such as `axo-webviews.leostera.dev`: no purchase, and the sandbox already makes its requests cross-site, but it is the same site as the app. Recommendation: (a).
- **Access.** The content host is served without Cloudflare Access, behind view tokens minted for the signed-in person, as `axo.leostera.dev` is served behind its own sign-in. That is an exception to the rule that a Worker's domains sit behind Access, and it needs the person's explicit agreement.
- **The CDN list:** `cdn.jsdelivr.net` and `esm.sh`, or also `unpkg.com` and `fonts.googleapis.com`?

During implementation:

- Whether `HTMLRewriter` keeps a document byte for byte apart from the inserted script, on pages that are not well-formed.
- Whether a `WKWebView` reports a reliable height for a page whose content is laid out after fonts load. The bootstrap may need to report again after `document.fonts.ready`.
