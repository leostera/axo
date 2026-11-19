import { atMost, defineActor, defineProperty, defineSpec, defineZone } from "@leostera/feynman";

type Phase = "awake" | "exiting" | "starting" | "dormant" | "unavailable" | "closed";
const Session = defineActor({
  name: "Pinned Session lifecycle", singleton: true,
  zone: defineZone({ name: "host-local axod", place: { column: 0 } }),
  initialState: () => ({ pinned: false, open: true, phase: "awake" as Phase, running: 1, candidate: false, restart: false }),
  actions: {
    pin: { label: "Local preference becomes pinned", with: [atMost(1)], run(s) { s.pinned = true; } },
    unpin: { label: "Unpin without stopping work", with: [atMost(1)], run(s) { s.pinned = false; } },
    selectIdle: { label: "Governor selects an idle candidate", with: [atMost(1)], run(s) {
      s.candidate = s.open && s.phase === "awake" && !s.pinned;
    } },
    admitSleep: { label: "Re-read pin before sleep admission", with: [atMost(1)], run(s) {
      if (s.open && s.candidate && !s.pinned && s.phase === "awake") s.phase = "exiting";
    } },
    reconcile: { label: "Reconcile a pinned open Session", with: [atMost(2)], run(s) {
      if (!s.open || !s.pinned) return;
      if (s.phase === "dormant" || s.phase === "unavailable") s.phase = "starting";
      else if (s.phase === "exiting") s.restart = true;
    } },
    exit: { label: "Old process exits before any replacement", with: [atMost(1)], run(s) {
      if (s.phase !== "exiting") return;
      s.running = 0;
      s.phase = s.restart ? "starting" : "dormant";
      s.restart = false;
    } },
    launch: { label: "One admitted launch completes", with: [atMost(2)], run(s) {
      if (s.phase !== "starting") return;
      s.running++;
      s.phase = "awake";
    } },
    crash: { label: "Agent becomes unavailable", with: [atMost(1)], run(s) {
      if (s.phase !== "awake") return;
      s.running = 0;
      s.phase = "unavailable";
    } },
    restore: { label: "Daemon restore starts old pins, not other old Sessions", with: [atMost(1)], run(s) {
      if (!s.open) return;
      s.running = 0;
      s.phase = s.pinned ? "starting" : "dormant";
      s.restart = false;
    } },
    close: { label: "Explicit Close removes the open Session", with: [atMost(1)], run(s) {
      s.open = false;
      s.phase = "closed";
      s.running = 0;
      s.restart = false;
    } },
  },
});
export default defineSpec({
  name: "Pinned Session process admission", actors: [Session],
  properties: [
    defineProperty("oneProcess", { description: "Reconciliation never creates a second writer.",
      always: w => w.the(Session).state.running <= 1 }),
    defineProperty("closeWins", { description: "Stale pins and late reconciliation cannot reopen an explicitly closed Session.",
      always: w => w.the(Session).state.open || (w.the(Session).state.phase === "closed" && w.the(Session).state.running === 0) }),
    defineProperty("launchWaitsForExit", { description: "Dormant, unavailable and starting states have no old process.",
      always: w => !["dormant", "unavailable", "starting"].includes(w.the(Session).state.phase) || w.the(Session).state.running === 0 }),
  ],
});
