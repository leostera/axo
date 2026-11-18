import { atMost, defineActor, defineProperty, defineSpec, defineZone } from "@leostera/feynman";

const zone = defineZone({ name: "request push admission", place: { column: 0 } });
// Registration/claim safety only: this does not model Apple's transport or OS delivery policy.
const Push = defineActor({
  name: "One installation and one request", singleton: true, zone,
  initialState: () => ({ revision: 0, enabled: false, pending: true, live: true,
    claimed: false, attempts: 0, approvals: 0, unsafeAttempt: false }),
  actions: {
    enable: { label: "Enable revision one", with: [atMost(1)], run(s) {
      if (s.revision < 1) { s.revision = 1; s.enabled = true; }
    } },
    disable: { label: "Disable revision two", with: [atMost(1)], run(s) {
      if (s.revision < 2) { s.revision = 2; s.enabled = false; }
    } },
    delayedEnable: { label: "Old enable arrives late", with: [atMost(1)], run(s) {
      if (s.revision < 1) { s.revision = 1; s.enabled = true; }
    } },
    resolve: { label: "Request ends", with: [atMost(1)], run(s) { s.pending = false; } },
    revoke: { label: "Sign-in ends", with: [atMost(1)], run(s) { s.live = false; } },
    dispatch: { label: "Atomic attempt claim", with: [atMost(2)], run(s) {
      if (s.enabled && s.live && s.pending && !s.claimed) {
        s.claimed = true;
        s.attempts++;
        s.unsafeAttempt ||= !s.enabled || !s.live || !s.pending;
      }
    } },
    crash: { label: "Crash preserves durable claim", with: [atMost(1)], run(_s) {} },
    notificationTap: { label: "Open inbox only", with: [atMost(1)], run(_s) {} },
  },
});

export default defineSpec({
  name: "Native push registration and durable claim", actors: [Push],
  properties: [
    defineProperty("lateEnableCannotUndoDisable", { description: "The revision-two tombstone fences revision one.",
      always: world => world.the(Push).state.revision !== 2 || !world.the(Push).state.enabled }),
    defineProperty("uncertainAttemptIsNotReplayed", { description: "Concurrent dispatch or a crash cannot re-send a claimed attempt.",
      always: world => world.the(Push).state.attempts <= 1 }),
    defineProperty("admissionUsesCurrentAuthority", { description: "A settled request or revoked registration cannot admit a new attempt.",
      always: world => !world.the(Push).state.unsafeAttempt }),
    defineProperty("notificationNeverApproves", { description: "Push and taps cannot grant execution authority.",
      always: world => world.the(Push).state.approvals === 0 }),
  ],
});
