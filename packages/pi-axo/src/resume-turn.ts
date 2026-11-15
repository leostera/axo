import type { PiCommandResult } from "./protocol.js";

export interface ResumeTurnHost {
  isIdle(): boolean;
  hasQueuedPrompts(): boolean;
  resume?: () => void;
  unsupported(): void;
}

/** One automatic recovery per Pi runtime, independent of bridge reconnects/receipt loss. */
export class ResumeTurnControl {
  private claimed = false;
  private readonly host: ResumeTurnHost;

  constructor(host: ResumeTurnHost) {
    this.host = host;
  }

  take(): PiCommandResult {
    if (this.claimed) return { accepted: true };
    if (!this.host.isIdle() || this.host.hasQueuedPrompts()) return { accepted: false, reason: "busy" };
    if (this.host.resume === undefined) {
      this.host.unsupported();
      return { accepted: false, reason: "unavailable" };
    }
    // Claim before calling the host, even if its receipt/error later becomes uncertain.
    this.claimed = true;
    this.host.resume();
    return { accepted: true };
  }
}
