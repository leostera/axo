import { atMost, defineActor, defineProperty, defineSpec, defineZone } from "@leostera/feynman";

// The daemon owns one admitted link mutation, independently of the CLI's receipt. A committed
// unlink closes relay admission before success; deletion failures leave only unused secrets.
// This logical model does not claim revocation/rollback of already-dispatched external work.
const zone = defineZone({ name: "Local pairing and relay", place: { column: 0 } });
const Link = defineActor({
  name: "Link", zone, singleton: true,
  initialState: () => ({ linked: true, phase: "idle" as "idle" | "unlinking" | "committed" | "closing" | "done", admission: true, credential: true, receipt: true, ack: false }),
  actions: {
    unlink: {
      label: "Admit unlink", description: "Only one mutation owns the coordinator; callers cannot race a link against unlink.",
      sources: ["crates/axo-server/src/lib.rs#add_relay_methods"], with: [atMost(1)],
      when: s => s.phase === "idle", run(s) { s.phase = "unlinking"; },
    },
    loseReceipt: {
      label: "CLI disconnects", description: "Losing the requester does not drop the daemon-owned operation.",
      sources: ["crates/axo-server/src/lib.rs#add_relay_methods"], with: [atMost(1)],
      when: s => s.phase !== "idle" && s.phase !== "done", run(s) { s.receipt = false; },
    },
  },
  transitions: {
    commit: {
      description: "Persist the empty link before revocation or secret cleanup.", sources: ["crates/axo-relay/src/link.rs#unlink_host"],
      when: s => s.phase === "unlinking", run(s) { s.linked = false; s.phase = "committed"; },
    },
    closeAdmission: {
      description: "Notify the relay; frames and queued commands cannot enter the old connection.", sources: ["crates/axo-relay/src/relay/session.rs#take_message", "crates/axo-relay/src/relay/session.rs#answer_requests"],
      when: s => s.phase === "committed", run(s) { s.admission = false; s.phase = "closing"; },
    },
    orphan: {
      description: "An OS deletion failure leaves an unused secret, never a restored pairing.", sources: ["crates/axo-relay/src/link.rs#unlink_host"],
      when: s => s.phase === "closing", run(s) { s.phase = "done"; s.ack = s.receipt; },
    },
    cleanup: {
      description: "Delete the unused credential.", sources: ["crates/axo-relay/src/link.rs#unlink_host"],
      when: s => s.phase === "closing", run(s) { s.credential = false; s.phase = "done"; s.ack = s.receipt; },
    },
  },
});
export default defineSpec({
  name: "Relay link lifecycle", description: "Durable unlink, single-owner completion and closed admission before success.", actors: [Link],
  properties: [
    defineProperty("successMeansUnlinked", { description: "A successful receipt never leaves a saved link or open old admission.", always: w => { const s = w.the(Link).state; return !s.ack || (!s.linked && !s.admission); } }),
    defineProperty("deleteAfterCommit", { description: "Credential cleanup cannot destroy a still-linked credential.", always: w => { const s = w.the(Link).state; return s.credential || !s.linked; } }),
    defineProperty("ownerFinishesWithoutReceipt", { description: "A disconnected CLI cannot strand the admitted mutation halfway.", leadsTo: { whenever: w => w.the(Link).state.phase === "unlinking", then: w => w.the(Link).state.phase === "done" } }),
  ],
  finalState: { description: "The daemon completed unlink whether or not its CLI still waits.", when: w => w.the(Link).state.phase === "done" },
});
