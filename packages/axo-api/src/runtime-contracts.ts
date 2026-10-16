import { z } from "zod";
import { uuid } from "./identity.js";

export const processSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("starting") }).strict(),
  z.object({ kind: z.literal("running"), pid: z.number().int().positive() }).strict(),
  z.object({ kind: z.literal("stopping"), pid: z.number().int().positive() }).strict(),
  z.object({ kind: z.literal("exited"), wait_status: z.number().int() }).strict(),
  z.object({ kind: z.literal("failed") }).strict(),
  z.object({ kind: z.literal("recovery_required") }).strict(),
]);
export const runtimeRefSchema = z.object({
  host_generation: uuid,
  target: z.object({ session_id: uuid, pane_id: uuid }).strict(),
  runtime_generation: uuid,
}).strict();
export const terminalSchema = z.object({
  runtime: runtimeRefSchema,
  process: processSchema,
  attached: z.boolean(),
  backlog_bytes: z.number().int().min(0).max(8192),
}).strict();
