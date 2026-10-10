import type { SessionEntry } from "@earendil-works/pi-coding-agent";

export type RemoteError = "notReady" | "notInteractive" | "rejected" | "stale" | "recovery" | "invalid" | "busy" | "staleInteraction" | "blocked" | "unknown";
export type History = { leafId: string | null; entries: readonly SessionEntry[]; branch: readonly SessionEntry[] };
export type Response<Snapshot> = { snapshot: Snapshot } | { history: History } | "dispatched" | { rejected: RemoteError };
export type Record<Snapshot> = { ready: Snapshot } | { status: Snapshot } | { reply: { id: string | null; response: Response<Snapshot> } };

export class ControlFailure extends Error {
  constructor(readonly code: RemoteError) { super("Managed control rejected"); }
}
