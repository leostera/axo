// Everything a person can do in the playground, as data. A run of the simulator is fully
// determined by a starting preset plus the list of `Input`s (a command and the simulated time it
// happened at), which is what the shareable URL stores.

import { z } from "zod";

const id = z.string().min(1).max(64);
const text = z.string().max(200);

export const commandSchema = z.discriminatedUnion("t", [
  z.object({ t: z.literal("addPerson"), name: text }),
  z.object({ t: z.literal("addClient"), kind: z.enum(["phone", "browser"]), owner: z.string().max(64), label: text }),
  z.object({ t: z.literal("addMac"), name: text }),
  z.object({ t: z.literal("setFlag"), flag: z.enum(["unlink", "codeCap"]), value: z.boolean() }),
  z.object({ t: z.literal("signIn"), client: id, person: id }),
  z.object({ t: z.literal("signOut"), client: id }),
  z.object({ t: z.literal("createCode"), client: id }),
  z.object({ t: z.literal("listHosts"), client: id }),
  z.object({ t: z.literal("open"), client: id, hostId: id }),
  z.object({ t: z.literal("leave"), client: id }),
  z.object({ t: z.literal("revoke"), client: id, hostId: id }),
  z.object({ t: z.literal("clientType"), client: id, text }),
  z.object({ t: z.literal("link"), mac: id, code: id }),
  z.object({ t: z.literal("setNetwork"), mac: id, online: z.boolean() }),
  z.object({ t: z.literal("restart"), mac: id }),
  z.object({ t: z.literal("retry"), mac: id }),
  z.object({ t: z.literal("unlink"), mac: id }),
  z.object({ t: z.literal("macType"), mac: id, text }),
  z.object({ t: z.literal("skip"), by: z.number().positive().max(24 * 3600 * 1000) }),
]);
export type Command = z.infer<typeof commandSchema>;

export const inputSchema = z.object({ at: z.number().nonnegative(), command: commandSchema });
export type Input = z.infer<typeof inputSchema>;

/** What the URL carries: the inputs so far and where in simulated time the viewer was. */
export const sharedRunSchema = z.object({
  inputs: z.array(inputSchema).max(2000),
  now: z.number().nonnegative(),
});
export type SharedRun = z.infer<typeof sharedRunSchema>;
