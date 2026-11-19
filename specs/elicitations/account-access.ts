import { atMost, defineActor, defineProperty, defineSpec, defineZone } from "@leostera/feynman";

// RFD0079 admission model. The authenticated relay is trusted; device enrollment is not a state.
const zone = defineZone({ name: "account-scoped human answers", place: { column: 0 } });
const Request = defineActor({
  name: "One host request", singleton: true, zone,
  initialState: () => ({ signedIn: true, sameAccount: true, human: true, activeHost: true,
    currentGeneration: true, pending: true, accepted: 0, unauthorized: false }),
  actions: {
    signOut: { label: "Session expires or is revoked", with: [atMost(1)], run(s) { s.signedIn = false; } },
    foreignAccount: { label: "Another account targets the host", with: [atMost(1)], run(s) { s.sameAccount = false; } },
    machineCaller: { label: "Host or agent credential, not a person", with: [atMost(1)], run(s) { s.human = false; } },
    revokeHost: { label: "Host is disconnected", with: [atMost(1)], run(s) { s.activeHost = false; } },
    replaceHost: { label: "The displayed host generation is stale", with: [atMost(1)], run(s) { s.currentGeneration = false; } },
    expire: { label: "Question expires or is answered elsewhere", with: [atMost(1)], run(s) { s.pending = false; } },
    answer: { label: "Signed-in human explicitly answers without enrollment", with: [atMost(2)], run(s) {
      if (!s.signedIn || !s.sameAccount || !s.human || !s.activeHost || !s.currentGeneration || !s.pending) return;
      s.unauthorized ||= !s.signedIn || !s.sameAccount || !s.human || !s.activeHost || !s.currentGeneration;
      s.accepted++; s.pending = false;
    } },
  },
});
export default defineSpec({
  name: "Account-based client access", actors: [Request], properties: [
    defineProperty("accountAndHumanBoundary", { description: "Foreign, revoked, machine and stale-host callers never settle a request.",
      always: w => !w.the(Request).state.unauthorized }),
    defineProperty("settleOnce", { description: "Late and repeated answers never reauthorize an action.",
      always: w => w.the(Request).state.accepted <= 1 }),
  ],
});
