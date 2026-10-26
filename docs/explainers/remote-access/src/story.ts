// The facts the explainer animates. Each scenario is a list of steps; each step may send one
// message between two actors and change what each side remembers.

export type Actor = "you" | "access" | "relay" | "mac";

export type ConnectionState = "not linked" | "connecting" | "connected" | "disconnected";

/** Everything the explainer shows, at one moment. */
export type World = {
  signedIn: boolean;
  code: { value: string; state: "valid" | "used" } | null;
  /** Secrets only this Mac knows, by credential ID. */
  keychain: string[];
  /** axod's `host_link` row. */
  link: { account: string | null; credential: string | null; pending: string | null };
  /** What the relay knows about this Mac. */
  relayHost: { credential: string; state: "online" | "offline" | "revoked" } | null;
  connection: ConnectionState;
  lastError: string | null;
  phoneAttached: boolean;
};

export type Message = {
  from: Actor;
  to: Actor;
  label: string;
  tone?: "request" | "reply" | "refused" | "stream";
};

export type Step = {
  title: string;
  /** For someone who has never heard of any of this. */
  plain: string;
  /** What actually goes over the wire or into storage. */
  detail: string;
  message?: Message;
  focus: Actor[];
  change?: (world: World) => World;
};

export type Scenario = {
  id: string;
  name: string;
  summary: string;
  start: World;
  steps: Step[];
};

const ACCOUNT = "acct-7f3a";
const OLD = "cred-old";
const NEW = "cred-9c41";

const empty: World = {
  signedIn: false,
  code: null,
  keychain: [],
  link: { account: null, credential: null, pending: null },
  relayHost: null,
  connection: "not linked",
  lastError: null,
  phoneAttached: false,
};

const linked: World = {
  ...empty,
  signedIn: true,
  keychain: [NEW],
  link: { account: ACCOUNT, credential: NEW, pending: null },
  relayHost: { credential: NEW, state: "online" },
  connection: "connected",
};

const link = (world: World, patch: Partial<World["link"]>): World => ({
  ...world,
  link: { ...world.link, ...patch },
});

export const scenarios: Scenario[] = [
  {
    id: "link",
    name: "Link this Mac",
    summary: "You start from nothing and end with your Mac online in your account.",
    start: empty,
    steps: [
      {
        title: "Nothing is linked yet",
        plain:
          "Your Mac runs axod, the little program that owns your terminals. It doesn't belong to any account yet, so it doesn't talk to the internet at all. Settings says \"not linked\".",
        detail:
          "axod's `host_link` table is empty. The relay worker loop sees no account, reports `This Mac is not linked to an Axo account.` and waits. It never opens a socket.",
        focus: ["mac"],
      },
      {
        title: "You sign in",
        plain:
          "In your browser you open axo.leostera.dev. Cloudflare Access asks who you are (Google, GitHub, email code…). Access is the bouncer: it decides who gets in. Axo doesn't keep passwords.",
        detail:
          "Access puts a signed token (JWT) on every request in `Cf-Access-Jwt-Assertion`. The Worker checks it itself: RS256 signature against the team's public keys, the issuer, the audience and a non-empty subject. The subject becomes your account.",
        message: { from: "you", to: "access", label: "who are you?" },
        focus: ["you", "access"],
        change: (w) => ({ ...w, signedIn: true }),
      },
      {
        title: "You ask for a pairing code",
        plain:
          "You click \"Pair a host\". The relay makes a short code, like ABCD-1234, that works once and only for 10 minutes. It's like a cloakroom ticket.",
        detail:
          "`POST /api/v1/account/host-pairings`, behind Access. The code uses Crockford base32. The relay stores only an HMAC of the code, never the code itself, and rate-limits issuing codes.",
        message: { from: "you", to: "relay", label: "new code please" },
        focus: ["you", "relay"],
        change: (w) => ({ ...w, code: { value: "ABCD-1234", state: "valid" } }),
      },
      {
        title: "You paste the code on your Mac",
        plain:
          "On the Mac you open Settings (⌘,) → Remote Access, paste the code and press Link. The app hands it to axod. This stays on your Mac; nothing has left it yet.",
        detail:
          "The app calls `axo.relay.link {code}` over axod's private Unix socket (mode 0600, only your user). axod rejects anything that isn't shaped like a code before doing any work.",
        message: { from: "you", to: "mac", label: "ABCD-1234" },
        focus: ["you", "mac"],
      },
      {
        title: "axod makes a fresh secret",
        plain:
          "axod invents a brand-new secret password for this Mac and locks it in your Keychain. In its database it writes a note: \"I'm in the middle of linking with this secret\", so a crash right now can't confuse it.",
        detail:
          "32 random bytes go to the Keychain under a new credential ID. The database stores only the ID, as `pending_credential_id` with the host generation. Storing the note before talking to the relay means a retry reuses the same secret.",
        focus: ["mac"],
        change: (w) => link({ ...w, keychain: [...w.keychain, NEW] }, { pending: NEW }),
      },
      {
        title: "axod trades the code for a place in your account",
        plain:
          "axod sends the code and the secret to the relay. The relay checks the ticket is real, unused and fresh, then says \"OK, this Mac belongs to your account now\". The ticket is torn up.",
        detail:
          "`POST /api/v1/host-pairings/redeem` with `{code, hostId, hostGeneration, credentialId, credential, label, hostKind}`. The relay keeps an HMAC of the secret (a verifier), not the secret. Redeeming is atomic and one-time; repeating the same redemption gives the same answer.",
        message: { from: "mac", to: "relay", label: "code + secret" },
        focus: ["mac", "relay"],
        change: (w) => ({
          ...w,
          code: w.code && { ...w.code, state: "used" },
          relayHost: { credential: NEW, state: "offline" },
        }),
      },
      {
        title: "axod writes down the link",
        plain:
          "axod updates its note: \"I belong to this account and I use this secret.\" If there was an older secret, it's thrown away.",
        detail:
          "`host_link` now has `account_id` and `credential_id`; the pending columns are cleared in the same write. The table only allows the ID columns in pairs.",
        message: { from: "relay", to: "mac", label: "account acct-7f3a", tone: "reply" },
        focus: ["mac"],
        change: (w) => link(w, { account: ACCOUNT, credential: NEW, pending: null }),
      },
      {
        title: "axod connects and stays connected",
        plain:
          "axod opens a phone line to the relay and keeps it open. Every time, it proves it's your Mac with the secret. Settings now says Connected.",
        detail:
          "WebSocket to `wss://axo.leostera.dev/api/v1/accounts/acct-7f3a/hosts/<host>/daemon` with `Authorization: Bearer <secret>` and `X-Axo-Credential-Id`. The relay checks the verifier and that the host isn't revoked. Then axod sends `axo.host.register` and its session list.",
        message: { from: "mac", to: "relay", label: "it's me (secret)", tone: "stream" },
        focus: ["mac", "relay"],
        change: (w) => ({
          ...w,
          connection: "connected",
          relayHost: w.relayHost && { ...w.relayHost, state: "online" },
        }),
      },
    ],
  },
  {
    id: "use",
    name: "Use it from your phone",
    summary: "Your Mac is linked. You open a terminal from somewhere else.",
    start: { ...linked, signedIn: false },
    steps: [
      {
        title: "Your Mac is waiting",
        plain:
          "Your Mac has its line to the relay open. It isn't sending your screen anywhere; it's just reachable.",
        detail: "One WebSocket from axod to the relay's per-host Durable Object.",
        focus: ["mac", "relay"],
      },
      {
        title: "You sign in on your phone",
        plain:
          "Same bouncer as before: Cloudflare Access. Your phone is never \"paired\". If you lose it, you sign it out in Access.",
        detail:
          "The browser gets the Access cookie. Native apps (next milestone) will send the Access token as `cf-access-token` and no cookies at all.",
        message: { from: "you", to: "access", label: "who are you?" },
        focus: ["you", "access"],
        change: (w) => ({ ...w, signedIn: true }),
      },
      {
        title: "The relay checks this Mac is yours",
        plain:
          "You pick your Mac from the list. The relay only lets you in if that Mac belongs to your account and hasn't been revoked.",
        detail:
          "`/api/v1/account/hosts/<host>/client`. The Worker maps your Access subject to your account, then checks the account owns the host.",
        message: { from: "you", to: "relay", label: "open my Mac" },
        focus: ["you", "relay"],
        change: (w) => ({ ...w, phoneAttached: true }),
      },
      {
        title: "You type, the Mac answers",
        plain:
          "Your keystrokes travel phone → relay → Mac. The terminal's output travels back the same way. The relay is a switchboard: it passes messages along.",
        detail:
          "`axo.terminal.input` goes to axod, which writes it to the PTY. Output comes back as events. Clients may send 30 frames/s and hosts 600 frames/s. Terminal bytes aren't stored today.",
        message: { from: "you", to: "mac", label: "ls -la ⏎", tone: "stream" },
        focus: ["you", "relay", "mac"],
      },
      {
        title: "Output streams back",
        plain: "And the result appears on your phone, as if you were sitting at the Mac.",
        detail: "Ordered output events per shell; the relay never parses terminal content.",
        message: { from: "mac", to: "you", label: "output…", tone: "reply" },
        focus: ["mac", "relay", "you"],
      },
    ],
  },
  {
    id: "drop",
    name: "The Wi-Fi drops",
    summary: "What happens when the line goes dead.",
    start: linked,
    steps: [
      {
        title: "Connected",
        plain: "All good.",
        detail: "Status `connected`.",
        focus: ["mac", "relay"],
      },
      {
        title: "The line dies",
        plain:
          "Your Wi-Fi drops. axod notices and shows Disconnected with the reason. Your terminals on the Mac keep running; only the remote line is gone.",
        detail: "The socket errors. Status becomes `disconnected` with `lastError`.",
        focus: ["mac"],
        change: (w) => ({
          ...w,
          connection: "disconnected",
          lastError: "network is unreachable",
          relayHost: w.relayHost && { ...w.relayHost, state: "offline" },
        }),
      },
      {
        title: "axod keeps trying, more and more patiently",
        plain:
          "It tries again after 1 second, then 2, 4, 8… and never waits more than 30 seconds. The Retry button in Settings skips the wait.",
        detail: "Exponential backoff capped at 30 s. Retry calls `axo.relay.connect`.",
        message: { from: "mac", to: "relay", label: "retry", tone: "refused" },
        focus: ["mac"],
        change: (w) => ({ ...w, connection: "connecting" }),
      },
      {
        title: "Back online",
        plain: "The Wi-Fi comes back; the next try works. Nothing had to be linked again.",
        detail: "Same account, same credential, same route.",
        message: { from: "mac", to: "relay", label: "it's me (secret)", tone: "stream" },
        focus: ["mac", "relay"],
        change: (w) => ({
          ...w,
          connection: "connected",
          lastError: null,
          relayHost: w.relayHost && { ...w.relayHost, state: "online" },
        }),
      },
    ],
  },
  {
    id: "fail",
    name: "Linking fails halfway",
    summary: "The network breaks right while you link a Mac that was already linked.",
    start: {
      ...linked,
      keychain: [OLD],
      link: { account: ACCOUNT, credential: OLD, pending: null },
      relayHost: { credential: OLD, state: "online" },
    },
    steps: [
      {
        title: "Already linked, linking again",
        plain:
          "This Mac already works with an older secret. You paste a new code anyway, maybe to move it to another account.",
        detail: "`host_link` has `cred-old`.",
        message: { from: "you", to: "mac", label: "EFGH-5678" },
        focus: ["you", "mac"],
        change: (w) => ({ ...w, code: { value: "EFGH-5678", state: "valid" } }),
      },
      {
        title: "New secret, noted as \"in progress\"",
        plain: "axod makes a new secret and writes \"linking in progress\" next to the old link, which it keeps.",
        detail: "`pending_credential_id = cred-9c41`; `credential_id` is still `cred-old`.",
        focus: ["mac"],
        change: (w) => link({ ...w, keychain: [...w.keychain, NEW] }, { pending: NEW }),
      },
      {
        title: "The request is lost",
        plain:
          "The network breaks while asking the relay. axod can't know if the relay got it. Settings shows an error, but your Mac stays connected with the old secret.",
        detail: "The redeem request times out. Nothing about the current link changed.",
        message: { from: "mac", to: "relay", label: "code + new secret", tone: "refused" },
        focus: ["mac", "relay"],
        change: (w) => ({ ...w, lastError: "could not link this Mac" }),
      },
      {
        title: "You press Link again",
        plain:
          "axod sees its note and reuses the same new secret instead of making another one. If the relay did get the first try, it recognises the repeat and answers the same way.",
        detail:
          "Same code, same host generation, same credential ID: the relay treats it as the same redemption, so it's safe to repeat.",
        message: { from: "mac", to: "relay", label: "same code + same secret" },
        focus: ["mac", "relay"],
        change: (w) => ({
          ...w,
          code: w.code && { ...w.code, state: "used" },
          relayHost: { credential: NEW, state: "online" },
          lastError: null,
        }),
      },
      {
        title: "Switched over; old secret gone",
        plain: "axod switches to the new link and throws the old secret away.",
        detail: "`credential_id = cred-9c41`, pending cleared, `cred-old` deleted from the Keychain.",
        message: { from: "relay", to: "mac", label: "linked", tone: "reply" },
        focus: ["mac"],
        change: (w) =>
          link({ ...w, keychain: w.keychain.filter((c) => c !== OLD) }, {
            credential: NEW,
            pending: null,
          }),
      },
    ],
  },
  {
    id: "revoke",
    name: "Revoke a Mac",
    summary: "You lost the laptop. Cut it off.",
    start: { ...linked, phoneAttached: true },
    steps: [
      {
        title: "Everything is connected",
        plain: "Your Mac is online and your phone is looking at it.",
        detail: "Host and client sockets are both attached to the host's relay object.",
        focus: ["you", "relay", "mac"],
      },
      {
        title: "You press Revoke",
        plain:
          "In the browser, you revoke that Mac. The relay hangs up on it and on everyone watching it, straight away.",
        detail:
          "`POST /api/v1/account/hosts/<host>/revoke` → 204. Host and client sockets close. The host stays in your list as offline and revoked.",
        message: { from: "you", to: "relay", label: "revoke" },
        focus: ["you", "relay"],
        change: (w) => ({
          ...w,
          phoneAttached: false,
          relayHost: w.relayHost && { ...w.relayHost, state: "revoked" },
        }),
      },
      {
        title: "The Mac is turned away",
        plain:
          "The Mac tries to reconnect like it always does, and the relay says no every time. Its secret is now worthless.",
        detail: "Reconnects get `HTTP 403`. Settings shows the error.",
        message: { from: "mac", to: "relay", label: "it's me (secret)", tone: "refused" },
        focus: ["mac", "relay"],
        change: (w) => ({ ...w, connection: "disconnected", lastError: "HTTP error: 403 Forbidden" }),
      },
    ],
  },
];

/** The world after `index` steps of a scenario (0 = before the first step's change). */
export function worldAt(scenario: Scenario, index: number): World {
  return scenario.steps
    .slice(0, index + 1)
    .reduce((world, step) => (step.change ? step.change(world) : world), scenario.start);
}
