import { z } from "zod";
import { uuid } from "./identity.js";
import { runtimeRefSchema, terminalSchema } from "./runtime-contracts.js";

// Retained presentation metadata, not a pane mutation or launch authority.
export const shellPaneSchema = z.object({
  paneId: uuid,
  kind: z.literal("shell"),
  profileId: z.string().regex(/^[a-zA-Z0-9_-]{1,64}$/).nullable(),
  state: z.enum(["adding", "open", "failed", "closing", "removed"]),
  runtime: runtimeRefSchema.nullable(),
  terminal: terminalSchema.nullable(),
}).strict();
