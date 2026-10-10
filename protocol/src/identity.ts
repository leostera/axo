import { z } from "zod";

// UUID case cannot create two routing keys for the same identity.
export const uuid = z.string().toLowerCase().uuid();
export const destinationSchema = z.object({ machineId: uuid, hostGeneration: uuid }).strict();
