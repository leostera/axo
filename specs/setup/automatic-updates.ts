import { atMost, defineActor, defineProperty, defineSpec, defineZone } from "@leostera/feynman";

const zone = defineZone({ name: "Mac app", place: { column: 0 } });
// Consent/commit admission model only; no filesystem, network or OS fault proof.
const Updater = defineActor({
  name: "Automatic updater", singleton: true, zone,
  initialState: () => ({
    enabled: false, generation: 0, ticket: -1, pending: false,
    committed: false, restarted: false, unauthorized: false,
  }),
  actions: {
    enable: {
      label: "Opt in", description: "New consent cannot revive an old attempt.", with: [atMost(2)],
      run(s) { if (!s.enabled) { s.enabled = true; s.generation++; } },
    },
    disable: {
      label: "Revoke pending consent", description: "Do not retract a committed replacement.", with: [atMost(2)],
      run(s) { if (s.enabled) { s.enabled = false; s.generation++; } },
    },
    download: {
      label: "Admit one verified-release download", description: "Own the attempt until it retires.", with: [atMost(2)],
      run(s) {
        if (s.enabled && !s.pending && !s.committed) {
          s.pending = true; s.ticket = s.generation;
        }
      },
    },
    commit: {
      label: "Authorize and atomically replace", description: "Consent and generation are checked at commit.", with: [atMost(2)],
      run(s) {
        if (s.pending && s.enabled && s.ticket === s.generation) {
          s.unauthorized ||= !s.enabled || s.ticket !== s.generation;
          s.committed = true;
        }
      },
    },
    finish: {
      label: "Retire; committed replacement finishes handover", description: "Successful replacement must not be stranded by revocation.", with: [atMost(2)],
      run(s) {
        if (s.pending) {
          s.pending = false;
          if (s.committed) s.restarted = true;
        }
      },
    },
  },
});
export default defineSpec({
  name: "Automatic update consent and commit",
  actors: [Updater],
  properties: [
    defineProperty("authorizedAtCommit", {
      description: "Revoked or superseded consent never authorizes a replacement.",
      always: w => !w.the(Updater).state.unauthorized,
    }),
    defineProperty("retiredCommitHasHandover", {
      description: "Revoking consent after commit cannot strand a retired replacement.",
      always: w => {
        const s = w.the(Updater).state;
        return !(s.committed && !s.pending) || s.restarted;
      },
    }),
    defineProperty("restartRequiresCommit", {
      description: "No automatic handover occurs before successful replacement.",
      always: w => !w.the(Updater).state.restarted || w.the(Updater).state.committed,
    }),
  ],
});
