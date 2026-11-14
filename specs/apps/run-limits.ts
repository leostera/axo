import { atMost, defineActor, defineProperty, defineSpec, defineZone } from "@leostera/feynman";

// RFD0050: scale two admitted calls and one active slot down from the configurable budgets.
// Cleanup completing means owned work stopped, not merely that its caller stopped waiting.
const zone = defineZone({ name: "Account and owned host work", place: { column: 0 } });
const Run = defineActor({
  name: "Run", zone, singleton: true,
  initialState: () => ({ phase: "open" as "open" | "closing" | "closed", admitted: 0, queued: 0, active: 0, owned: 0, started: 0, startsAtClose: 0 }),
  actions: {
    admit: {
      label: "Admit a tool call", sources: ["packages/axo-api-worker/src/apps/runner.ts#ToolDispatcher.call"], description: "Account-side admission charges even queued calls.", with: [atMost(2)],
      when: s => s.phase === "open" && s.admitted < 2,
      run(s) { s.admitted++; s.queued++; },
    },
    end: {
      label: "End or time out", sources: ["packages/axo-api-worker/src/apps/run-scope.ts#RunScope.close"], description: "Close admission and reject queued calls before cancelling work.", with: [atMost(1)],
      when: s => s.phase === "open",
      run(s) { s.phase = "closing"; s.queued = 0; s.startsAtClose = s.started; },
    },
  },
  transitions: {
    dispatch: {
      description: "Recheck closure after waiting for a slot; never start work after end.", sources: ["packages/axo-api-worker/src/apps/runner.ts#ToolDispatcher.call"],
      when: s => s.phase === "open" && s.queued > 0 && s.active < 1,
      run(s) { s.queued--; s.active++; s.owned++; s.started++; },
    },
    complete: {
      description: "The owned operation completes normally or finishes cancellation/kill/reap.", sources: ["crates/axo-relay/src/bash.rs#run_cancellable", "crates/axod-infer/src/service.rs#execute_cancellable"],
      when: s => s.active > 0,
      run(s) { s.active--; s.owned--; },
    },
    closed: {
      description: "Cleanup finishes only when no operation remains owned.", sources: ["packages/axo-api-worker/src/apps/run-scope.ts#RunScope.close"],
      when: s => s.phase === "closing" && s.owned === 0,
      run(s) { s.phase = "closed"; },
    },
  },
});
export default defineSpec({
  name: "Codemode run limits", description: "Bounded admission, concurrency, closure and ownership during cleanup.", actors: [Run],
  properties: [
    defineProperty("budgetsHold", { description: "Admission and active work remain within the requested budgets.", always: w => {
      const s = w.the(Run).state; return s.admitted <= 2 && s.active <= 1 && s.owned === s.active;
    } }),
    defineProperty("noDispatchAfterEnd", { description: "Closing a run permanently closes dispatch.", always: w => {
      const s = w.the(Run).state; return s.phase === "open" || s.started === s.startsAtClose;
    } }),
    defineProperty("closedOwnsNothing", { description: "A closed run has no queued or still-owned work.", always: w => {
      const s = w.the(Run).state; return s.phase !== "closed" || (s.owned === 0 && s.queued === 0);
    } }),
    defineProperty("cleanupFinishes", { description: "Cancellation keeps ownership until cleanup completes.", leadsTo: {
      whenever: w => w.the(Run).state.phase === "closing", then: w => w.the(Run).state.phase === "closed",
    } }),
  ],
  finalState: { description: "The run and its owned work are finished.", when: w => w.the(Run).state.phase === "closed" },
});
