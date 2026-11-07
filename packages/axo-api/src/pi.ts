import { z } from "zod";

/** What a Session's Pi runs and can switch to, as clients see it (RFD0033). */

/** Pi's thinking levels, lowest first. */
export const thinkingLevelSchema = z.enum(["off", "minimal", "low", "medium", "high", "xhigh", "max"]);
export type ThinkingLevel = z.infer<typeof thinkingLevelSchema>;
const modelNameSchema = z.string().min(1).max(128);
export const piModelRefSchema = z.object({ provider: modelNameSchema, id: modelNameSchema, name: modelNameSchema }).strict();
/** What a Session's Pi runs, once it has said (RFD0033). */
export const piRuntimeSchema = z.object({ model: piModelRefSchema.nullable(), thinkingLevel: thinkingLevelSchema }).strict();
export type PiRuntime = z.infer<typeof piRuntimeSchema>;
export const piCommandSchema = z.object({
  name: z.string().min(1).max(128),
  description: z.string().max(200),
  source: z.enum(["extension", "prompt", "skill"]),
}).strict();
export type PiCommand = z.infer<typeof piCommandSchema>;
export const piModelSchema = piModelRefSchema.extend({ thinkingLevels: z.array(thinkingLevelSchema).max(7) }).strict();
export type PiModel = z.infer<typeof piModelSchema>;

