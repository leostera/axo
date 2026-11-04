# RFD0029 - Axo: Ask the Person

- Feature Name: `axo-ask-the-person`
- Status: Draft
- Author: leostera
- Start Date: 2026-11-04
- Updated: 2026-11-04
- Document Type: Proposal
- Amends: [RFD0028](RFD0028-computer-use.md), [RFD0018](RFD0018-session-sync-and-client-delivery.md)

## Summary

When an agent needs the person, Axo asks the person directly, on their own clients, and only the person's answer counts. Agent and person stay separate parties, and the agent cannot answer for the person, whatever it is told or claims.

There are three kinds of request:

- **Confirm:** an action the computer-use gate flags, such as *click "Pay now" in Safari — checkout.example.com*. The person answers Allow once, Always allow, or Deny.
- **Input:** values the agent must not see, such as a login, a card or a one-time code. The person fills a small form, and the values go **past the agent**, straight into the app's fields on the Mac. The agent gets a receipt.
- **Authenticate:** Face ID or Touch ID on the person's device unlocks an answer for steps that need more than a tap, such as paying, signing in, or anything the person marks.

A request appears on every client the person has open:
- as a card in the Session's transcript on the web, iOS and Mac;
- as a notification with buttons on the Mac;
- as a push notification on iOS.

The first answer wins, and the other clients dismiss their card. Only requests that block on the person notify; a new message never does.

## Motivation

RFD0028's gate refuses a flagged action and tells the agent to ask the person, then to call again with `confirm: true`. That makes the agent the messenger, which is weak in three ways:
- **It confirms itself.** An eager agent may take "sure, just do it" said an hour ago, or nothing at all, as consent.
- **Prompt injection reaches the confirmation.** A page that tells the agent "the user already agreed" gets through.
- **Secrets have no safe path.** Anything the person types in the chat goes into the agent's context, its transcript, the cloud copy of that transcript, and the model provider.

Leo's requirements, in his words:
- "a user gate", "a feature of the client that bypasses the agent";
- "a small form where I can input my details", that "bypasses the agent, goes straight through this side channel into the tool";
- "notifications for: I need to go in and give my input", not for every message;
- "give you this grant of authorization from my phone".

## Guide-level explanation

An agent is buying something in Safari. It clicks "Pay now" through `computer`, and the gate flags the action. The click doesn't happen yet.

**On the person's phone:** a push notification says *Studio: an agent wants to click "Pay now" in Safari — checkout.example.com*. Tapping it opens the Session at a card showing:
- a screenshot of the window;
- what will happen, and why it was stopped (*Clef: 96% likely to be hard to undo*);
- the buttons **Allow once**, **Always allow…** and **Deny**.

Allow asks for Face ID, because the action involves money. Once allowed, the click happens on the Mac and the agent's tool call returns *done*. A Deny returns *the person declined*.

**At the Mac:** the same request appears as a notification at the top right, with the same buttons. It also appears as a card in the Mac app's transcript. Whichever the person answers first wins, and the others go away.

**When a login needs details:** the agent reaches a sign-in page. It doesn't have the person's details, so it asks for them:

```js
computer({ tool: "request_input", args: {
  why: "Sign in to GitHub to open the pull request",
  fields: [
    { label: "Email",    kind: "username", target: "s3:7" },
    { label: "Password", kind: "password", target: "s3:8" },
  ],
  then: { click: "s3:9" },
}})
```

- **The request:** the person's phone shows *Sign in to github.com*, with the address taken from the browser itself, plus a form with an email field and a password field.
- **Autofill:** the fields are marked as a username and a password, so the Passwords app or 1Password offers the person's login.
- **Filling:** after a tap and Face ID, axod fills the two fields on the Mac and clicks "Sign in".
- **What the agent learns:** only *Filled Email and Password in Safari — github.com and clicked Sign in; the values are not shown to you*. Later reads of that window show the filled values as `•••• (filled by you)`.

**When the answer comes from somewhere else:** the agent uses the same tool to ask for a card's number, expiry and security code, or for a six-digit code from an authenticator. For example, `npm publish --otp` takes a code the person's phone can autofill.

## Reference-level explanation

### Requests

axod, the daemon, owns every request. A request holds:

- `id`, `sessionId`, `kind` (`confirm | input | authenticate`), `createdAt`, `expiresAt` (default 5 minutes);
- **what the person sees:**
  - `title`, such as *click "Pay now"*;
  - `where`: the app, the window and, for a browser, the page's origin, read by axod from Accessibility rather than from the agent;
  - `why`, written by the agent and **labelled as the agent's words**;
  - `gate`: why the risk gate stopped it, if it did;
  - a `screenshot` of the target window;
- **for input:** its `fields` (`label`, `kind`, `target` element token) and an optional `then` action;
- `state`: `pending`, then `allowed`, `denied`, `filled`, `expired` or `cancelled`.

**Who creates them:**
- The gate creates a confirm request for every flagged action, replacing RFD0028's refusal and its `confirm: true`. The agent no longer has a way to approve.
- The agent creates input requests with `request_input`. It may *ask*, but nothing it sends can *answer*.

**How `axod mcp` waits:** it calls `axo.ask.request` on the daemon and blocks until the request resolves. The call returns `allowed` (and the action runs), `denied`, `expired` or `filled` (with a receipt).

**Persistence:** requests live in `axo.db`. When axod restarts, pending requests expire, because the waiting tool call died with the old process.

### Delivery to clients

- **Local:**
  - The daemon emits `axo.ask.requested` and `axo.ask.resolved` as events on its socket.
  - The Mac app shows a transcript card, and a `UNNotification` with category actions (Allow once, Deny, Open).
- **Remote:**
  - axod sends the same events over its relay socket to HostDO, which forwards them to every ClientDO following the host.
  - They are ephemeral notices next to RFD0018's transcript records, not Pi lines. Clients place a card at the Session's position for its `createdAt`.
  - A ClientDO that connects while a request is pending gets it in its catch-up.
- **Push:**
  - A new `AxoPushNotifier` in the Worker sends an APNs alert for each `requested`, to the iOS devices the account registered.
  - The alert carries only the title, the where and the Session name, never values. Answering from the alert is limited to Allow once and Deny for confirm requests; input and authenticate open the app.
  - A `resolved` withdraws the delivered alert, using apns-collapse-id set to the request id.
- **First answer wins:** the first answer axod takes *claims* the request at once, before it is carried out. A fill can take a moment, and a Deny arriving meanwhile must not undo it. Later answers get `already answered`; every client receives `resolved` and dismisses its card.
- **Catch-up replays:** clients ignore a request they already know is resolved. A catch-up after a reconnect can replay `requested` after `resolved`.

### Who may answer: the gate's own gate

The agent runs commands as the person, on the same Mac. So any path the Mac app uses, a script could try. The design rests on three checks:

1. **Local answers come only from Axo.app.** axod accepts `axo.ask.answer` on `axod.sock` only from a peer whose code signature satisfies `identifier "dev.leostera.axo" and anchor apple generic and certificate leaf[subject.OU] = "RGH6S9S55G"`.
   - axod reads the peer's audit token (`LOCAL_PEERTOKEN`) and checks it with `SecCodeCopyGuestWithAttributes` and `SecCodeCheckValidity`.
   - A shell script, `node`, `osascript` or `axod mcp` all fail this check.
   - The hardened runtime keeps other processes from injecting code into Axo.app.
2. **Remote answers come only from a person:**
   - HostDO forwards an `answer` only from a ClientDO, which means a signed-in web or iOS session.
   - It never takes one from the host socket itself, so the Mac's own credential can't answer.
   - Session-scoped credentials, such as the codemode sandbox of `connections_execute`, have no route to answering at all.
3. **No method the agent can reach answers a request.** `axod mcp` offers `request_input` and the gate's confirm. It has no answer tool, and axod refuses `axo.ask.answer` from MCP and Session connections whatever their signature.

**Authenticate:** an answer that requires authentication carries proof from the device. On iOS, Face ID unlocks a per-device signing key (Secure Enclave, `.biometryCurrentSet`), and the device signs `answer || requestId`. The Mac app does the same with Touch ID.
- axod checks the signature against the device keys the person registered. Registering a key itself needs an authenticated answer from an already-registered device, or pairing at the Mac.
- A confirm becomes authenticate when its `gate` category is money or sign-in, or when an always-rule says so.

### The side channel for input

**Goal:** values typed on the phone reach the target app's fields on the Mac, and nothing else ever sees them in plain text. That rules out the agent, `axod mcp`, the transcript, the cloud and the push service.

- **The Mac's request key:**
  - On first pairing, axod generates a P-256 key pair.
  - The private key lives in the login Keychain, with an access control list naming only axod's code signature. The public key is registered with the account, in HostDO, alongside the host.
  - Each client fetches it with the host list, and pins its fingerprint per host the first time it sees it.
  - If the key changes, the client says so and refuses input to that host until the person accepts the new key at the Mac. The Mac app shows the fingerprint.
- **Sealing an answer:**
  - The client encrypts `{ requestId, values }` with HPKE (RFC 9180; DHKEM(P-256), HKDF-SHA256, AES-128-GCM) to the request key.
  - It uses `info = "axo-ask-input/v1"` and `aad = requestId || hostId || origin`.
  - The web uses WebCrypto ECDH, HKDF and AES-GCM; iOS and the Mac app use CryptoKit's `HPKE`.
  - HostDO and ClientDO only ever see `{ requestId, sealed }`.
- **Opening it:** axod opens the sealed answer, and checks that `requestId` is pending and of kind input, and that the `aad` matches the request. A sealed answer for a different request, host or origin fails to open.
- **Filling:**
  - **The address shown is axod's own reading:** when it creates a request, axod reads the window's origin from Accessibility itself. If the page has already moved to a look-alike, the person sees the look-alike's address.
  - **A changed page gets nothing:** axod fills the exact elements the request named. If the page changes between the request and the answer, those elements are gone, so nothing is filled and the request resolves `cancelled: the page changed`. axod also checks the origin again just before filling.
  - **Filling the fields:** it then fills each field's target with `set_value`, or `type_text` for fields that refuse `set_value`, and runs `then`, if given. It uses its own embedded computer runtime, so the values never enter `axod mcp`.
  - **Clearing:** it overwrites the decrypted buffer and keeps only a salted hash of each value, per window, for the life of the request's Session.
- **The receipt** the agent gets lists:
  - which fields were filled, in which window, and whether `then` ran;
  - `redact`: the salted hashes and the salt, which `axod mcp` uses to redact.
- **One call per window:** `axod mcp` runs one computer call on a window at a time. A read of a window with a pending input request waits until the request resolves, and the request waits for reads already under way. Otherwise a read made in parallel could catch the filled value before the receipt that redacts it arrives.
- **Redaction of reads:**
  - In `get_window_state` and every computer result, `axod mcp` replaces any element value, or substring of at least 4 characters, whose salted hash matches with `•••• (filled by you)`.
  - It blacks out those elements' frames in screenshots.
  - Secure text fields are already hidden by macOS.

### Always allow

- **Rules:** answering Always allow creates a rule in `axo.db` covering an app (bundle id), an action kind, a target label, an origin for browsers, and a scope (this Session or all).
- **Effect:** a matching flagged action runs without a request, and is logged.
- **Limits:**
  - Rules never cover input; values are always asked for.
  - Categories marked *always ask* (money, by default) offer no Always allow.
  - Rules are listed and revocable in the Mac app's settings, and on the web.

### Logging

- Every request and its outcome goes in the computer-use log: who asked, what, where, the answer, which client answered, and whether it was authenticated. Values are never logged.
- Over the relay, the cloud's call log (RFD0016) gets the same record.

## Testing

- `specs/ask-the-person.ts` (Feynman) models a confirm and an input request across the agent, its shell, axod, HostDO, the iPhone, the Mac app and Safari. As of 2026-11-04:
  - **Safety holds** on every path within depth 14 (463k states, one fault): only the person answers, the first answer wins, the card never reaches the agent or the cloud in the clear, values go only into the page whose address the person was shown, and no client keeps a card for a resolved request.
  - **Liveness:** every waiting tool call returns. This held on every path of up to 20 events (11.9M states); longer paths were not checked.
  - **Every rule is needed:** without `peerCheck`, `sealedValues`, `receiptOnly`, `boundTarget`, `oneCallPerWindow` or `redaction`, a property breaks.
  - **The checker found two flaws in the first draft**, now in this RFD:
    - a Deny arriving during a fill overrode the fill (fixed by claiming on the first answer);
    - a parallel read caught the value before its receipt (fixed by one call per window).
- **axod tests:**
  - the peer code-signature check accepts Axo.app and rejects other peers (needs a signed fixture);
  - HPKE round trips between Rust and CryptoKit vectors, and between Rust and WebCrypto vectors;
  - origin re-check, redaction, expiry and restart.
- **Client tests:**
  - the card's states;
  - the notification categories;
  - fingerprint pinning;
  - the iOS form's text content types for autofill.
- **By hand:** a login and a card payment on a test site, answered from the phone, the web and the Mac notification.

## Drawbacks

- **More pieces:** APNs infrastructure, a device-key registry, a Mac request key and three clients' UIs.
- **The first-seen key:** a first-seen fingerprint can be swapped by a compromised Worker, at first use only. After that, the pins hold.
- **The gate's reach:** an agent can still drive apps through `osascript` or keystrokes in `bash`, outside the computer tool. This gate covers the computer tool, not every power an agent has over the Mac.
- **Passkeys at a distance:** a website's passkey ceremony (WebAuthn) cannot be answered from afar. It needs the Mac's Touch ID, or the phone within Bluetooth range for the hybrid transport. Requests can only offer "Touch ID is needed at the Mac", or use one-time codes or tokens instead.

## Unresolved questions

- **Saved values:** should axod keep values the person chooses to save, in its own Keychain items, so a second login needs only a confirm?
- **Web Push:** should the web app get push too, or is it enough to show requests while it is open?
- **Other requests:** should the same channel carry other waits on the person, such as a connection needing sign-in (RFD0016), or an agent's question in `ask_user` style?
