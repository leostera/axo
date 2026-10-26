// The shareable URL: #play/<preset>/r=<lz-compressed JSON of a SharedRun>.

import LZString from "lz-string";
import { sharedRunSchema } from "./commands";
import { replay, type Replayed } from "./replay";
import { presets, type Sim } from "./sim";

export function encodeRun(sim: Sim): string {
  return LZString.compressToEncodedURIComponent(JSON.stringify({ inputs: sim.inputs, now: sim.now }));
}

export type Loaded = { presetId: string; shared: Replayed | null };

/** Reads a location hash. Anything that doesn't parse or replay is treated as "no shared run". */
export function loadHash(hash: string): Loaded {
  const [, presetId = "", params = ""] = hash.split("/");
  const encoded = /^r=(.+)$/.exec(params)?.[1];
  const preset = presets.find((p) => p.id === presetId);
  if (!encoded || !preset) return { presetId, shared: null };
  try {
    const json = LZString.decompressFromEncodedURIComponent(encoded);
    const run = sharedRunSchema.parse(JSON.parse(json ?? ""));
    return { presetId, shared: replay(preset.build(), run.inputs, run.now) };
  } catch {
    return { presetId, shared: null };
  }
}
