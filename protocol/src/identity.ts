import { z } from "zod";

// UUID case cannot create two routing keys for the same identity.
export const uuid = z.string().uuid().transform(value => value.toLowerCase());
export const destinationSchema = z.object({ machineId: uuid, hostGeneration: uuid }).strict();
