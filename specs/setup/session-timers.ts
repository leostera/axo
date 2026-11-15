import { atMost, defineActor, defineProperty, defineSpec, defineZone } from "@leostera/feynman";

// Bounded logical ownership model, not OS scheduling, network, clock or exactly-once proof.
const code = "crates/axo-server/src/timers.rs:117-185" as const;
const zone = defineZone({ name: "axod runtime", place: { column: 0 } });
const Timer = defineActor({
  name: "Timer", singleton: true, zone,
  initialState: () => ({ closed: false, claimed: false, slot: true, retired: false,
    delivered: 0, afterClose: 0, uncertain: false }),
  actions: {
    tick: { label: "Tick", description: "Claim one occurrence only while admission is open.", sources: [code], with: [atMost(3)],
      when: s => !s.closed && !s.claimed && !s.retired,
      run(s) { s.claimed = true; if (s.closed) s.afterClose++; } },
    cancel: { label: "Cancel", description: "Close admission without retracting or releasing an owned send.", sources: [code], with: [atMost(2)],
      run(s) { s.closed = true; } },
    deadline: { label: "Send receipt overdue", description: "Close recurrence but retain the send and slot.", sources: [code], with: [atMost(1)],
      when: s => s.claimed && !s.uncertain,
      run(s) { s.uncertain = true; s.closed = true; } },
  },
  transitions: {
    complete: { description: "A claimed send may complete after cancel; it remains owned until then.", sources: [code],
      when: s => s.claimed,
      run(s) { s.claimed = false; s.delivered++; } },
    retire: { description: "Release the slot only after closed admission and completed owned work.", sources: [code],
      when: s => s.closed && !s.claimed && !s.retired,
      run(s) { s.retired = true; s.slot = false; } },
  },
});
export default defineSpec({ name: "Session timer ownership", actors: [Timer],
  properties: [
    defineProperty("noClaimsAfterClose", { description: "Cancellation prevents new claims, not already claimed sends.", always: w => w.the(Timer).state.afterClose === 0 }),
    defineProperty("ownedSendRetainsSlot", { description: "Neither cancellation nor a receipt deadline frees an in-flight slot.", always: w => {
      const s = w.the(Timer).state; return !s.claimed || (s.slot && !s.retired);
    } }),
    defineProperty("retiredIsClosedAndEmpty", { description: "Retirement leaves no send or admission behind.", always: w => {
      const s = w.the(Timer).state; return !s.retired || (s.closed && !s.claimed && !s.slot);
    } }),
    defineProperty("closedTimersRetire", { description: "Assuming the admitted operation completes, closure reaches retirement.", leadsTo: {
      whenever: w => w.the(Timer).state.closed, then: w => w.the(Timer).state.retired,
    } }),
  ],
});
