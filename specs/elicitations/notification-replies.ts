import { atMost, defineActor, defineProperty, defineSpec, defineZone } from "@leostera/feynman";

const zone = defineZone({ name: "native inline text reply", place: { column: 0 } });
// Admission and dispatch fence only, not a proof of OS UI, encryption or APNs delivery.
const Reply = defineActor({
  name: "One text-input notification", singleton: true, zone,
  initialState: () => ({ eligible: true, preview: true, sent: false, actionable: false,
    unlocked: false, signedIn: true, pending: true, matches: true, claimed: false,
    dispatches: 0, unsafe: false }),
  actions: {
    unsupported: { label: "Secret, form or incomplete target", with: [atMost(1)], run(s) { if (!s.sent) s.eligible = false; } },
    optOut: { label: "Disable previews", with: [atMost(1)], run(s) { if (!s.sent) s.preview = false; } },
    notify: { label: "Choose reply or open-in-app category", with: [atMost(1)], run(s) {
      s.sent = true; s.actionable = s.eligible && s.preview;
    } },
    unlock: { label: "Person unlocks for native text reply", with: [atMost(1)], run(s) { s.unlocked = true; } },
    signOut: { label: "Sign-in ends", with: [atMost(1)], run(s) { s.signedIn = false; } },
    settle: { label: "Answered elsewhere or expired", with: [atMost(1)], run(s) { s.pending = false; } },
    change: { label: "Body, field, origin, submit or key changed", with: [atMost(1)], run(s) { s.matches = false; } },
    reply: { label: "Explicit Send or duplicated OS callback", with: [atMost(2)], run(s) {
      if (!s.actionable || !s.unlocked || !s.signedIn || !s.pending || !s.matches || s.claimed) return;
      s.claimed = true; // Persist before the only network dispatch.
      s.unsafe ||= !s.eligible || !s.preview;
      s.dispatches++;
      // The request may still be pending after uncertainty. Do not reset the fence.
    } },
    reconnect: { label: "App recreates after uncertainty; fence survives", with: [atMost(1)], run(_s) {} },
  },
});
export default defineSpec({
  name: "Text notification replies", actors: [Reply], properties: [
    defineProperty("atMostOneDispatch", { description: "Even an uncertain reply cannot be replayed by reconnect or OS redelivery.",
      always: w => w.the(Reply).state.dispatches <= 1 }),
    defineProperty("onlyEligibleReplies", { description: "Secrets, forms, disabled previews and incomplete targets never become reply actions.",
      always: w => !w.the(Reply).state.unsafe }),
    defineProperty("persistBeforeDispatch", { description: "Every dispatch has already claimed its persistent fence.",
      always: w => w.the(Reply).state.dispatches === 0 || w.the(Reply).state.claimed }),
  ],
});
