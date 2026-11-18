import { atMost, defineActor, defineProperty, defineSpec, defineZone } from "@leostera/feynman";

const zone = defineZone({ name: "native notification admission", place: { column: 0 } });
// Admission model, not a proof of iOS UI/authentication or network delivery.
const Request = defineActor({
  name: "One displayed notification", singleton: true, zone,
  initialState: () => ({ previews: false, kind: "confirm", complete: true, sent: false, actionable: false,
    unlocked: false, signedIn: true, signer: true, pending: true, hashMatches: true,
    answers: 0, unsafe: false }),
  actions: {
    optIn: { label: "Person enables rich previews", with: [atMost(1)], run(s) { if (!s.sent) s.previews = true; } },
    sensitive: { label: "Sensitive input", with: [atMost(1)], run(s) { if (!s.sent) s.kind = "input"; } },
    information: { label: "Informational notify", with: [atMost(1)], run(s) { if (!s.sent) s.kind = "information"; } },
    longQuestion: { label: "Preview would be truncated", with: [atMost(1)], run(s) { if (!s.sent) s.complete = false; } },
    send: { label: "Server chooses category", with: [atMost(1)], run(s) {
      s.sent = true; s.actionable = s.previews && s.kind === "confirm" && s.complete;
    } },
    unlock: { label: "OS authenticates the person", with: [atMost(1)], run(s) { s.unlocked = true; } },
    signOut: { label: "Account revoked", with: [atMost(1)], run(s) { s.signedIn = false; } },
    signerUnavailable: { label: "No enrolled key", with: [atMost(1)], run(s) { s.signer = false; } },
    settle: { label: "Answered elsewhere or expired", with: [atMost(1)], run(s) { s.pending = false; } },
    changedDisplay: { label: "Display or current question hash differs", with: [atMost(1)], run(s) { s.hashMatches = false; } },
    defaultTap: { label: "Open current inbox, never answer", with: [atMost(1)], run(_s) {} },
    answer: { label: "Explicit Yes or No through the existing signer", with: [atMost(2)], run(s) {
      if (s.actionable && s.unlocked && s.signedIn && s.signer && s.pending && s.hashMatches) {
        s.unsafe ||= s.kind !== "confirm" || !s.complete || !s.previews;
        s.answers++; s.pending = false;
      }
    } },
  },
});
export default defineSpec({
  name: "Rich notification action authority", actors: [Request], properties: [
    defineProperty("onlyCompleteOptedInConfirmationsHaveActions", { description: "Informational, sensitive, generic and truncated payloads cannot grant answer actions.",
      always: w => !w.the(Request).state.actionable || (w.the(Request).state.previews && w.the(Request).state.complete && w.the(Request).state.kind === "confirm") }),
    defineProperty("atMostOneAnswer", { description: "An explicit answer cannot be replayed after settlement.", always: w => w.the(Request).state.answers <= 1 }),
    defineProperty("noUnsafeAdmission", { description: "A banner or informational message never becomes approval authority.", always: w => !w.the(Request).state.unsafe }),
  ],
});
