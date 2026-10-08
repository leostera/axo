import { readFileSync, statSync } from "node:fs";
import { z } from "zod";

const configSchema = z.object({
  relayURL: z.url().refine(value => new URL(value).protocol === "https:", "Relay must use HTTPS"),
  accessClientId: z.string().min(1),
  accessClientSecret: z.string().min(1),
});
export type BridgeConfig = z.infer<typeof configSchema>;

export function loadConfig(path: string): BridgeConfig {
  if ((statSync(path).mode & 0o077) !== 0) throw new Error("Axo credentials must have mode 0600");
  return configSchema.parse(JSON.parse(readFileSync(path, "utf8")));
}
