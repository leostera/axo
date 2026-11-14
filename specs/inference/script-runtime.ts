import { atMost, defineActor, defineProperty, defineScenario, defineSpec, defineZone } from "@leostera/feynman";

// RFD0046/RFD0047: the shared MLX/Core ML ownership protocol, not a claim that dropping a future cancels native work.
// This bounded abstraction keeps the coordinator and its one owned process in one actor;
// killAndReap is the completion of the OS process wait, not merely sending a signal.
const mac = defineZone({ name: "Target Mac", place: { column: 0 } });
const ScriptRuntime = defineActor({
  name: "ScriptRuntime",
  zone: mac,
  singleton: true,
  initialState: () => ({ phase: "idle" as "idle" | "ready" | "loading" | "running" | "retiring", owned: false, computing: false, operations: 0, retired: 0 }),
  actions: {
    start: {
      label: "Start inference",
      sources: ["crates/axod-infer/src/service.rs#prepare", "crates/axod-infer/src/native_process.rs#ensure_running"],
      description: "Admit one operation with a new worker, or reuse the same initialized model; never admit during retirement.",
      with: [atMost(2)],
      when: (s) => (s.phase === "idle" && !s.owned) || s.phase === "ready",
      run(s) {
        if (s.phase === "ready") { s.phase = "running"; s.computing = true; }
        else { s.phase = "loading"; s.owned = true; }
        s.operations++;
      },
    },
    complete: {
      label: "Finish computation",
      sources: ["crates/axod-infer/src/mlx_worker.rs#generate", "crates/axod-infer/src/coreml.rs#predict", "crates/axod-infer/src/service.rs#execute"],
      description: "The native call completed; retain the owned model for another compatible operation.",
      with: [atMost(2)],
      when: (s) => s.phase === "running",
      run(s) { s.computing = false; s.phase = "ready"; },
    },
    deadline: {
      label: "Deadline expires",
      sources: ["crates/axod-infer/src/service.rs#execute"],
      description: "Cancel the caller's wait, not the native computation or process ownership.",
      with: [atMost(2)],
      when: (s) => s.phase === "running" || s.phase === "loading",
      // Native computation may continue after the caller's deadline. Ownership stays held.
      run(s) { s.phase = "retiring"; },
    },
    unload: {
      label: "Unload resident model",
      sources: ["crates/axod-infer/src/service.rs#perform"],
      description: "Unload or switching selects retirement, never releasing ownership before reaping.",
      with: [atMost(2)],
      when: (s) => s.phase === "ready",
      run(s) { s.phase = "retiring"; },
    },
    loadFailure: {
      label: "Model loading fails",
      sources: ["crates/axod-infer/src/mlx_worker.rs#load", "crates/axod-infer/src/coreml.rs#load"],
      description: "Failed initialization still requires the owned process to retire.",
      with: [atMost(2)],
      when: (s) => s.phase === "loading",
      run(s) { s.phase = "retiring"; },
    },
  },
  transitions: {
    loaded: {
      description: "Initialization completed; the owned process starts native computation.",
      sources: ["crates/axod-infer/src/native_process.rs#ensure_running"],
      when: (s) => s.phase === "loading",
      run(s) { s.phase = "running"; s.computing = true; },
    },
    killAndReap: {
      description: "Termination and wait completed; only now is a new operation admissible.",
      sources: ["crates/axod-infer/src/native_process.rs#stop"],
      when: (s) => s.phase === "retiring",
      run(s) { s.computing = false; s.owned = false; s.phase = "idle"; s.retired++; },
    },
  },
});

const Judge = defineActor({
  name: "Judge",
  zone: mac,
  singleton: true,
  initialState: () => ({ model: "clef", independentlyOwned: true }),
  transitions: {},
});

const ownershipUntilQuiescence = defineProperty("ownershipUntilQuiescence", {
  description: "Native computation always has an owner, even after a deadline; admission is closed until the process is reaped.",
  always: (w) => {
    const s = w.the(ScriptRuntime).state;
    return (!s.computing || s.owned) && (s.phase !== "idle" || (!s.owned && !s.computing));
  },
});
const failuresRecover = defineProperty("failuresRecover", {
  description: "Retirement eventually completes before another operation can start.",
  leadsTo: { whenever: (w) => w.the(ScriptRuntime).state.phase === "retiring", then: (w) => w.the(ScriptRuntime).state.phase === "idle" },
});
const judgeIsIndependent = defineProperty("judgeIsIndependent", {
  description: "Script loads, errors, deadlines and retirement never reconfigure or unload the safety judge.",
  always: (w) => w.the(Judge).state.model === "clef" && w.the(Judge).state.independentlyOwned,
});
const deadlineThenRetry = defineScenario("Deadline, reap, then retry", {
  run(s) {
    s.act(s.the(ScriptRuntime), "start");
    s.settle({ until: (w) => w.the(ScriptRuntime).state.phase === "running" });
    s.act(s.the(ScriptRuntime), "deadline");
    s.settle({ until: (w) => w.the(ScriptRuntime).state.phase === "idle" });
    s.act(s.the(ScriptRuntime), "start");
    s.settle({ until: (w) => w.the(ScriptRuntime).state.phase === "running" });
    s.act(s.the(ScriptRuntime), "complete");
    s.act(s.the(ScriptRuntime), "unload");
    s.settle({ until: (w) => w.the(ScriptRuntime).state.phase === "idle" });
  },
});

export default defineSpec({
  name: "Native script runtime ownership",
  description: "Bounded native ownership, resident reuse, deadlines and retirement; native computation outlives a cancelled wait until the process exits.",
  actors: [ScriptRuntime, Judge],
  properties: [ownershipUntilQuiescence, failuresRecover, judgeIsIndependent],
  scenarios: [deadlineThenRetry],
  finalState: { description: "Both bounded operations finished and the owned worker retired.", when: (w) => w.the(ScriptRuntime).state.operations === 2 && w.the(ScriptRuntime).state.phase === "idle" },
});
