import { atMost, defineActor, defineProperty, defineSpec, defineZone } from "@leostera/feynman";

// RFD0056: bounded observations and owned permission requests, not OS grant accuracy,
// code-signature cryptography, process crashes, GUI timing or network-fault guarantees.
const ui = "apple/AxoMac/Sources/AxoMac/App/AppSetupModel.swift:91-123" as const;
const daemon = "crates/axo-server/src/permissions.rs:70-165" as const;
const zone = defineZone({ name: "This Mac", place: { column: 0 } });
const Setup = defineActor({
  name: "Setup", singleton: true, zone,
  initialState: () => ({ generation: 0, applied: 0, checking: false, granted: false,
    oldReply: false, owned: 0, receipt: true, untrustedStarted: 0 }),
  actions: {
    check: {
      label: "Check live state", description: "Start a newer generation without prompting.", with: [atMost(2)], sources: [ui],
      when: s => s.generation < 2,
      run(s) { if (s.checking) s.oldReply = true; s.generation++; s.checking = true; },
    },
    request: {
      label: "Person requests a fixed permission", description: "Admit only while the previous OS operation owns no slot.", with: [atMost(2)], sources: [daemon],
      when: s => s.owned === 0,
      run(s) { s.owned = 1; s.receipt = true; },
    },
    untrusted: { label: "Agent attempts a grant", description: "Signature admission rejects before effects.", with: [atMost(1)], sources: [daemon], run() {} },
    lostReceipt: {
      label: "App closes or receipt is lost", description: "Abandoning the receipt does not release owned work.", with: [atMost(2)], sources: [daemon],
      when: s => s.owned === 1 && s.receipt,
      run(s) { s.receipt = false; },
    },
  },
  transitions: {
    currentGranted: { description: "Apply only the newest observed grant.", sources: [ui], when: s => s.checking,
      run(s) { s.applied = s.generation; s.granted = true; s.checking = false; } },
    currentUnknown: { description: "An unverifiable observation remains ungranted.", sources: [ui], when: s => s.checking,
      run(s) { s.applied = s.generation; s.granted = false; s.checking = false; } },
    staleReply: { description: "Discard the retired generation without changing the UI.", sources: [ui], when: s => s.oldReply, run(s) { s.oldReply = false; } },
    finishRequest: { description: "Release ownership only after completion or kill/reap.", sources: [daemon], when: s => s.owned === 1, run(s) { s.owned = 0; } },
  },
});
export default defineSpec({
  name: "Startup readiness", description: "Current-generation read-only observations and single-owner explicit repairs.", actors: [Setup],
  properties: [
    defineProperty("onlyCurrentReportsAreFresh", { description: "A completed check never applies an older generation.", always: w => {
      const s = w.the(Setup).state; return s.checking || s.applied === s.generation;
    } }),
    defineProperty("onlyOneRequestIsOwned", { description: "Receipt loss does not create another request slot.", always: w => {
      const s = w.the(Setup).state; return s.owned >= 0 && s.owned <= 1;
    } }),
    defineProperty("agentsCannotRequestGrants", { description: "An untrusted caller starts no permission prompt.", always: w => w.the(Setup).state.untrustedStarted === 0 }),
    defineProperty("requestsRetire", { description: "The OS operation completes or its owned child is killed/reaped at deadline.", leadsTo: {
      whenever: w => w.the(Setup).state.owned === 1, then: w => w.the(Setup).state.owned === 0,
    } }),
  ],
});
