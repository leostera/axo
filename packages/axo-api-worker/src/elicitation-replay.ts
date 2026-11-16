import type { Elicitation } from "@axo/protocol";
type Asked = { hostId: string; elicitation: Elicitation };

/** One subscription snapshot owns its catch-up. Terminal notices win over a delayed snapshot. */
export class ElicitationReplay {
  private active?: { asked: Asked[]; resolved: Set<string>; ready: boolean };
  begin(): { add(hostId: string, elicitation: Elicitation): void; finish(): void } {
    const owner = { asked: [] as Asked[], resolved: new Set<string>(), ready: false };
    this.active = owner;
    return {
      add: (hostId, elicitation) => {
        if (this.active === owner && !owner.resolved.has(elicitation.id))
          owner.asked.push({ hostId, elicitation });
      },
      finish: () => { if (this.active === owner) owner.ready = true; },
    };
  }
  resolve(id: string): void { this.active?.resolved.add(id); }
  clear(): void { this.active = undefined; }
  take(): Asked[] {
    const owner = this.active;
    if (!owner?.ready) return [];
    this.clear();
    return owner.asked.filter(asked => !owner.resolved.has(asked.elicitation.id));
  }
}
