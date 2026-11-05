# RFD0029 - Axo: Ask the Person

- Feature Name: `axo-ask-the-person`
- Status: Partially implemented (steps 1 to 3: yes-or-no questions; the computer-use gate asks; the Mac app answers)
- Author: leostera
- Start Date: 2026-11-04
- Updated: 2026-11-05
- Document Type: Proposal
- Amends: [RFD0028](RFD0028-computer-use.md), [RFD0018](RFD0018-session-sync-and-client-delivery.md)

## Summary

When an agent needs the person, Axo asks the person directly, on their own clients, and only the person's answer counts. Agent and person stay separate parties, and the agent cannot answer for the person, whatever it is told or claims.

There are four kinds of request:

- **Confirm:** an action the computer-use gate flags, such as *click "Pay now" in Safari — checkout.example.com*. The person answers Allow once, Always allow, or Deny.
- **Input:** values the agent must not see, such as a login, a card or a one-time code. The person fills a small form, and the values go **past the agent**, straight into the app's fields on the Mac. The agent gets a receipt.
- **Open a link:** a sign-in a terminal command started, such as `wrangler login`, `codex login` or `gh auth login`, that wants the person to open a link in a browser. The person does the sign-in on whatever device they have, and the command on the Mac finishes as if they had used the Mac's browser.
- **Authenticate:** Face ID or Touch ID on the person's device unlocks an answer for steps that need more than a tap, such as paying, signing in, or anything the person marks.

A request appears on every client the person has open:
- as a card in the Session's transcript on the web, iOS and Mac;
- as a notification with buttons on the Mac;
- as a push notification on iOS.

The first answer wins, and the other clients dismiss their card. Only requests that block on the person notify; a new message never does.

**Tools ask; agents cannot approve.** A tool that needs the person's consent asks for it itself, for the exact action it is about to take, and acts only on the answer to that request. No tool takes consent as an argument. An agent may ask questions of its own, but their answers authorize nothing.

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

### Elicitations

A request to the person is an **elicitation**, the word MCP uses for the same idea. The protocol has two methods and two events:

| Name | Kind | Who |
|---|---|---|
| `axo.elicitation.request` | method, waits for the outcome | `axod mcp` (the gate, `request_input`) asks axod |
| `axo.elicitation.resolve` | method | the person answers, from Axo.app or a signed-in web or iOS client |
| `axo.elicitation.requested` | event | axod tells every client a card is needed |
| `axo.elicitation.resolved` | event | axod tells every client it is settled, so they dismiss the card |

The rest of this RFD says "request" for one elicitation.

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

**Who creates them:** tools, for consent (see the next section), and agents, for questions of their own.
- The computer-use gate creates a confirm request for every flagged action, and for every call that passes `confirm: true`, replacing RFD0028's refusal. `confirm: true` no longer approves: it asks.
- `request_input` is the agent asking for values, but the request is made by the computer tool, which fills them; the agent may *ask*, but nothing it sends can *answer*.
- `elicitation_request` is the agent's own question. Its answer is for the agent only.

**How `axod mcp` waits:** it calls `axo.elicitation.request` on the daemon and blocks until the request resolves. The call returns `allowed` (and the action runs), `denied`, `expired` or `filled` (with a receipt).

**Persistence:** requests live in `axo.db`. When axod restarts, pending requests expire, because the waiting tool call died with the old process.

### Tools ask; agents cannot approve

An agent must not be the one that says the person agreed, because whatever reaches the agent can be wrong, stale, or written by a web page. So consent is something tools get for themselves:

1. **A tool that needs consent asks for it itself.** It decides what it is about to do first (the app, the window and element, the page's origin; for other tools, the exact command or call), then creates the request with that, and runs only on its answer. Whether an action needs consent is the tool's decision: the gate's checks, or what a tool declares about itself, never something the agent says.
2. **Consent is never an argument; an argument can only ask for more.** No tool takes an elicitation id, an answer, or a claim that the person agreed, and a call that passes one is refused rather than ignored, so an agent that tries learns it cannot. What an agent may pass is a request to be asked: `computer`'s `confirm: true` means *ask the person before this*, and the tool asks without running the gate's check. Without it, or with `confirm: false`, the gate checks the action (RFD0028's text check, then Clef) and asks only if it flags it. Either way the action runs only on the person's answer or on the gate passing it; `confirm` can make a call ask, never skip asking.
3. **An answer goes back only to the call that asked.** axod returns the outcome on the connection that made the request and nowhere else, and keeps no record a tool could look up later. A request made by anything else, including the agent's own question or one a script makes on `axod.sock`, cannot be presented to a tool: there is no way to present one.
4. **An answer is for one action, once.** An *Allow once* runs the action it was asked for, a single time. If the action changed before it runs (the window changed, the element is gone, the arguments differ), the tool asks again. The only standing consent is an Always-allow rule, which only the person creates (see Always allow).
5. **The agent's own questions authorize nothing.** `elicitation_request` is for the agent to check with the person ("delete the old branches?"). Its answer comes back to the agent as information. A later tool call that depends on it is gated like any other.
6. **The person can tell them apart.** A tool's request shows what the tool will do and why it stopped, from the tool's own reading; an agent's question shows the agent's words, labelled as the agent's.

**Which tools ask:**
- **Computer use:** the gate, for flagged actions, and the computer tool, for `request_input`.
- **Apps and connections (planned):** an app tool that sends, pays or deletes (Gmail's send, a payment, removing files) is marked as needing consent, and the account asks before it runs it. The request is made by the account's runner, outside the agent's script, and is answered like any other.
- **Shell commands:** not gated. An agent's `bash` is the person's own user; this RFD does not try to stop what it can do (see Drawbacks).

**Labels are not proof.** The agent runs as the person, so a script can call `axo.elicitation.request` and word its question like a tool's. That can mislead the person about who is asking, but it cannot approve anything: the answer goes back to that script only (rule 3), and no tool takes it (rule 2). axod labels a request as a tool's only when the peer asking is its own signed binary (step 3), so a script's request always shows as the agent's. The agent can still start `axod mcp` itself and call `computer` with `confirm: true`; that request is truly the gate's, describes the real action, and runs only on the person's Yes.

### Delivery to clients

- **Local:**
  - The daemon emits `axo.elicitation.requested` and `axo.elicitation.resolved` as events on its socket.
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

1. **Local answers come only from Axo.app.** axod accepts `axo.elicitation.resolve` on `axod.sock` only from a peer whose code signature satisfies `identifier "dev.leostera.axo" and anchor apple generic and certificate leaf[subject.OU] = "RGH6S9S55G"`.
   - axod reads the peer's audit token (`LOCAL_PEERTOKEN`) and checks it with `SecCodeCopyGuestWithAttributes` and `SecCodeCheckValidity`.
   - A shell script, `node`, `osascript` or `axod mcp` all fail this check.
   - The hardened runtime keeps other processes from injecting code into Axo.app.
2. **Remote answers come only from a person:**
   - HostDO forwards an `answer` only from a ClientDO, which means a signed-in web or iOS session.
   - It never takes one from the host socket itself, so the Mac's own credential can't answer.
   - Session-scoped credentials, such as the codemode sandbox of `connections_execute`, have no route to answering at all.
3. **No method the agent can reach answers a request.** `axod mcp` offers `request_input` and the gate's confirm. It has no answer tool, and axod refuses `axo.elicitation.resolve` from MCP and Session connections whatever their signature.

**Every remote answer is signed.** Each phone and browser registers a device key (iOS: Secure Enclave; web: a non-extractable WebCrypto key in IndexedDB). It signs every answer over `requestId || reply`. axod refuses an answer whose signature is not for that request and that reply. So a relay that is compromised, or a bug in it, cannot replay an earlier answer for a new request, turn *Allow once* into *Always allow*, or bring back a revoked rule.

**Authenticate:** an answer that requires authentication is signed by a second device key that only Face ID unlocks (Secure Enclave, `.biometryCurrentSet`). The Mac app does the same with Touch ID.
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

### Opening a link for the person

Command-line sign-ins print a link, or open it with `open`, and wait. Sitting at the Mac, the person clicks it. Away from the Mac, the agent can see the link but must not open it itself: the page may ask for a passkey, a password or consent that only the person can give.

- **Catching the link:** two ways in, so neither the agent nor axod has to guess from terminal output:
  - **The agent asks:** `request_link({ url, why, code? })`, for a link it read in a command's output. `code` is a device code the page will ask for, such as `gh`'s `ABCD-1234`. axod accepts it only if the link appears in the output of a Session terminal axod runs, and the process that printed it is the one the callback may go to. Otherwise a listener the agent started could claim to be the command.
  - **The command opens it:** Session processes get `BROWSER=axod-open` and a `PATH` entry whose `open` is the same shim. A link opened that way becomes a request that names the process that opened it (`wrangler login`, pid, Session).
- **Where it goes:**
  - **The person is at the Mac** (unlocked, input in the last two minutes): the link opens in the default browser, as it does today. No request.
  - **The person is away:** a request of kind `link`. The card shows the link's site in large type (`dash.cloudflare.com`), the command that asked, the device code if any, and *Open*.
- **Opening it:**
  - **Web:** *Open* opens the link in a new tab.
  - **iOS:** *Open* slides up a browser sheet. The person signs in, and closes it, or it closes itself when the flow ends (below).
  - **Mac app:** opens the default browser.
- **Two kinds of sign-in flow:**
  - **Device code** (`gh`, `codex login --device-auth`, most `--device` flags): the command polls the provider. Signing in anywhere is enough. Nothing comes back through Axo.
  - **Loopback redirect** (`wrangler login`, `gcloud`, most OAuth CLIs): the provider sends the browser back to `http://localhost:<port>/callback?code=…&state=…`, where the command is listening. On the phone or another computer, that address is the wrong machine. So:
    - axod reads the `redirect_uri` from the link when it creates the request, and records the loopback port and path.
    - **iOS:** the sheet watches navigations. When it is sent to that loopback address, it does not load it: it seals the full callback URL to the Mac's request key (as for input), sends it, and closes.
    - **Web:** a page in another tab can't be watched. When the tab ends on a "can't connect to localhost" page, the person copies its address into the card's *Paste the address you ended on* field, which seals it the same way.
    - **axod** opens the sealed URL and checks that it is a loopback address. It connects to the port, and **on that connection** checks that the listener is the process that opened the link (by matching the connection's socket among that process's descriptors) before it sends a byte. A check made before connecting can be stale: the command may time out and the agent take its port in between. Then axod makes the GET itself. The command sees the callback it expected; PKCE and `state` work unchanged.
    - axod records that a request's callback was sent, in `axo.db`, before sending it. A duplicated message, a second sign-in on another device, or a restart sends nothing twice.
- **Restarts:** pending link requests nobody answered expire when axod starts again, since their deadlines were in memory.
- **Resolving:** `opened` when a loopback callback got a 2xx from the command, or when the person marks it done (device code). `expired` after 10 minutes, the length of most device codes. The agent's `request_link` returns the outcome, never the callback URL, which carries an authorization code.
- **What it protects against:**
  - **A link from the agent is untrusted.** A prompt-injected agent could ask the person to "sign in" to a look-alike site. The card leads with the site, says which command produced the link (or "the agent" for `request_link`), and marks links whose site doesn't match the command's known providers.
  - **Callbacks go only where the command listens.** axod forwards a callback only to the process that opened the link, and only once. A sealed callback can't be turned into a request to another local service, or to a listener the agent puts on the port after the command exits.
  - **What it does not hide.** The command stores the token it gets, such as wrangler's config file, where the agent's shell can read it. This flow gets the person's consent on the real site and routes the code to the right process; it does not keep credentials from an agent that runs as the person.

### Always allow

- **Rules:** answering Always allow creates a rule in `axo.db` covering an app (bundle id), an action kind, a target label, an origin for browsers, and a scope (this Session or all).
- **Effect:** a matching flagged action runs without a request, and is logged.
- **Limits:**
  - Rules never cover input; values are always asked for.
  - Categories marked *always ask* (money, by default) offer no Always allow, and axod creates no such rule whatever a client sends.
  - Rules are listed and revocable in the Mac app's settings, on the web and on iOS.
- **Revoking:** each rule has an id, and revocations and their confirmations name it. A client shows *Revoking…* until axod confirms that rule's revocation, and only then *Revoked*. Without the id, a late confirmation for an earlier revocation could mark a rule revoked while a newer rule for the same action is active.

### Logging

- Every request and its outcome goes in the computer-use log: who asked, what, where, the answer, which client answered, and whether it was authenticated. Values are never logged.
- Over the relay, the cloud's call log (RFD0016) gets the same record.

### Step 1: yes or no, answered remotely

The first step built, ahead of the gate and the Mac app, is the channel itself: an agent asks a yes-or-no question and only the person answers.

- **The agent's tool:** `axod mcp` offers `elicitation_request({ message })`. It calls `axo.elicitation.request` on `axod.sock` for its own Session, whatever the agent passes, and waits up to 5 minutes. It returns `{ id, action }`, where `action` is `accept`, `decline` or `cancel` (nobody answered in time).
- **axod** keeps pending elicitations in memory (at most 32), publishes `elicitation.requested` and `elicitation.resolved` events, and sends them over the relay as `axo.elicitation.requested` and `axo.elicitation.resolved`. It sends every pending one again on each new relay connection. The first answer it takes removes the elicitation, so later answers find nothing (`-32011`).
- **Answers come only through the relay.** `axod.sock` has no method that answers one. axod takes `axo.elicitation.resolve` only from HostDO, for its own host and generation.
- **HostDO** keeps the pending ones in memory, sends them to the ClientDOs following it, including in the listing a client gets on hello, and dismisses them all (`cancel`) when the Mac goes offline. It forwards an answer only for a pending elicitation.
- **ClientDO** takes `axo.elicitation.resolve` only from a person's client. A Mac following its peers (`host-…` clients) neither receives elicitations nor answers them (`-32012`).
- **Clients:** the web and iOS show a card in the chat, with the agent's words, Yes and No, and mark the chat as needing the person in the chat list. The card stays until the Mac says it is settled.

**Step 2, the gate asks (built):** the computer-use gate asks the person for every flagged action and for every call with `confirm: true`, as a yes-or-no request from `axod mcp` for the agent's Session, and runs the action only on Accept. `computer` refuses any argument but `tool`, `args` and `confirm`. The question lists each action with its window and why the gate stopped. Not yet: binding an Allow to the window it named, beyond element tokens dying with a newer read, and Always allow. Modelled in `specs/elicitations/tools-ask.ts`.

**Step 3, who is asking and answering on the Mac (built):**
- **Peers by code signature:** axod reads each `axod.sock` connection's audit token (`LOCAL_PEERTOKEN`) and, for the methods that care, checks the peer's running code against a requirement (`crates/axo-ipc/src/peer.rs`). *This binary* is axod's own designated requirement (same team and identifier; for an unsigned build, the same cdhash). *Axo.app* is the same certificate with Axo.app's identifier; an unsigned build has none.
- **Asked as a tool:** a request carries `askedBy`: `agent` or `computerUse`. axod refuses `computerUse` (`-32013`) unless the peer is this binary, so only `axod mcp`'s gate asks as Axo. `elicitation_request` passes only the agent's message, so an agent cannot ask as a tool through it. Clients title a tool's card *Axo asks before acting on your Mac*, an agent's *The agent asks you*.
- **Answered on the Mac:** `axo.elicitation.resolve` on `axod.sock` takes an answer only from Axo.app (`-32012` otherwise). `axo.elicitation.list` gives what is pending, for a client that just subscribed.
- **The Mac app:** a card over the Session's panes with Yes and No, and a time-sensitive notification with Yes (needs the Mac unlocked), No, and a click that opens the Session. Settled questions withdraw their notification.

Not yet built, in the order of this RFD: the gate's confirm requests, the Mac app's card and notification (with the code-signature check), push notifications, device-signed answers, input, links, Always allow and Face ID. Until answers are device-signed, the Worker is trusted not to forge one.

## Testing

- `specs/elicitations/ask-the-person.ts` (Feynman) models a confirm and an input request across the agent, its shell, axod, HostDO, the iPhone, the Mac app and Safari. As of 2026-11-04:
  - **Safety holds** on every path within depth 14 (463k states, one fault): only the person answers, the first answer wins, the card never reaches the agent or the cloud in the clear, values go only into the page whose address the person was shown, and no client keeps a card for a resolved request.
  - **Liveness:** every waiting tool call returns. This held on every path of up to 20 events (11.9M states); longer paths were not checked.
  - **Every rule is needed:** without `peerCheck`, `sealedValues`, `receiptOnly`, `boundTarget`, `oneCallPerWindow` or `redaction`, a property breaks.
  - **The checker found two flaws in the first draft**, now in this RFD:
    - a Deny arriving during a fill overrode the fill (fixed by claiming on the first answer);
    - a parallel read caught the value before its receipt (fixed by one call per window).
- **To add to `specs/elicitations/ask-the-person.ts`** for *Tools ask; agents cannot approve*: an agent that passes `confirm: true` hoping to skip the check (it asks instead), presents the answer to its own question, or reuses an answer for another action. The property: every gated action runs only on the person's answer to the request its tool made for that action.
- `specs/elicitations/open-a-link.ts` models `wrangler login`, the agent, a local admin service, the loopback interface, axod, HostDO, the iPhone and the web app, with a lost or duplicated callback and an axod restart. Safety held on every path of up to 25 events (13.4M states): the code reaches only the command that opened the link, never the cloud in the clear, no other local service, and once per request. It found:
  - a check of the port's owner made before connecting is stale if the command exits and the agent binds the port (fixed by checking on the connection);
  - a link the agent passes on must name its opener by who printed it, not by who holds the port when it asks;
  - pending requests had no deadline after a restart (fixed by expiring them at start).
- `specs/elicitations/ask-rules.ts` models Always allow, revocation and Face ID, with a relay that replays or rewrites answers. Every property held on every path of up to 30 events (612k states, exploration complete): no payment by rule, every run is the person's own answer to that request, Face ID for every payment, nothing runs by a rule the phone shows revoked. It found:
  - a replayed unsigned *Always allow* brought back a revoked rule (fixed by signing every answer);
  - two stale displays of revocation (fixed by rule ids and *Revoking…* until confirmed).
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
- **Words can be imitated:** an agent's question can be worded like a tool's. Its card is titled as the agent's, but the words inside are the agent's choice.
- **The gate's reach:** an agent can still drive apps through `osascript` or keystrokes in `bash`, outside the computer tool. This gate covers the computer tool, not every power an agent has over the Mac.
- **Passkeys at a distance:** a website's passkey ceremony (WebAuthn) cannot be answered from afar. It needs the Mac's Touch ID, or the phone within Bluetooth range for the hybrid transport. Requests can only offer "Touch ID is needed at the Mac", or use one-time codes or tokens instead.
- **Passkeys in the iOS sheet:** a sheet that can watch navigations (`WKWebView`) may not offer the person's passkeys for third-party sites; Apple's sign-in sheet (`ASWebAuthenticationSession`) offers them but can't catch a `http://localhost` redirect. To be settled with a spike; the fallback is Safari plus pasting the final address, as on the web.
- **Loopback on the web is manual:** copying an address from a failed page is clumsy. Device-code flags avoid it where a command has one, and the agent should prefer them when the person is away.

## Unresolved questions

- **Which app tools ask:** each app's tools that send, pay or delete need marking, and the account's runner needs a way to make a request outside a Mac. Is a list per app enough, or should a tool's annotations (MCP's `destructiveHint`) decide for third-party servers too?

- **Saved values:** should axod keep values the person chooses to save, in its own Keychain items, so a second login needs only a confirm?
- **Web Push:** should the web app get push too, or is it enough to show requests while it is open?
- **Other requests:** should the same channel carry other waits on the person, such as a connection needing sign-in (RFD0016), or an agent's question in `ask_user` style?
