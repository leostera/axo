/**
 * The Worker as it is, with a SessionDO whose R2 can fail the way R2 and networks do, when a test
 * asks (RFD0044): every call failing (offline), a PUT that stores but whose answer is lost, a GET
 * that fails, and a bug that stores other bytes than those sent.
 */
import { AxoSessionDO as ReleaseSessionDO } from "../../src/session-store";

export * from "../../src/index";
export { default } from "../../src/index";

export type SegmentFaults = {
  /** Every R2 call throws. */
  offline: boolean;
  /** The next this many PUTs store the object, then throw as if the answer was lost. */
  loseAnswer: number;
  /** The next this many GETs of a segment throw. */
  failGet: number;
  /** The next this many PUTs of a segment store other bytes than those sent. */
  corruptPut: number;
  /** The most cut records the object keeps, in place of its real limit. */
  cutLimit: number | null;
};

export class AxoSessionDO extends ReleaseSessionDO {
  private readonly faults: SegmentFaults = { offline: false, loseAnswer: 0, failGet: 0, corruptPut: 0, cutLimit: null };

  async injectFaults(faults: Partial<SegmentFaults>): Promise<void> {
    Object.assign(this.faults, faults);
  }

  protected override cutKeepLimit(): number {
    return this.faults.cutLimit ?? super.cutKeepLimit();
  }

  protected override segments(): R2Bucket | undefined {
    const bucket = super.segments();
    if (!bucket) return undefined;
    const faults = this.faults;
    const offline = () => {
      if (faults.offline) throw new Error("network connection lost");
    };
    return {
      async put(key: string, value: Uint8Array, options?: R2PutOptions) {
        offline();
        if (faults.corruptPut > 0 && key.endsWith(".atxf.jsonl")) {
          faults.corruptPut -= 1;
          const other = value.slice();
          // A record's text changes, so its line no longer reads the same.
          const at = new TextDecoder().decode(other).indexOf("question");
          if (at >= 0) other[at] = "Q".charCodeAt(0);
          else other[0] = " ".charCodeAt(0);
          const { sha256: _, ...rest } = options ?? {};
          return bucket.put(key, other, rest);
        }
        const stored = await bucket.put(key, value, options);
        if (faults.loseAnswer > 0) {
          faults.loseAnswer -= 1;
          throw new Error("the answer to the PUT was lost");
        }
        return stored;
      },
      async get(key: string, options?: R2GetOptions) {
        offline();
        if (faults.failGet > 0 && key.endsWith(".atxf.jsonl")) {
          faults.failGet -= 1;
          throw new Error("GET failed");
        }
        return bucket.get(key, options);
      },
      async head(key: string) {
        offline();
        return bucket.head(key);
      },
      async list(options?: R2ListOptions) {
        offline();
        return bucket.list(options);
      },
    } as unknown as R2Bucket;
  }
}
