import { z } from "zod";
import { hostIdSchema, hostRefSchema, sessionIdSchema } from "./v1.ts";

/**
 * Elicitations (RFD0029): an agent asks the person, and only the person answers. axod owns each
 * one; HostDO keeps the pending ones in memory and shows them to the account's people; an answer
 * comes from a signed-in web or iOS client, never from a Mac.
 */
export const ELICITATION_METHODS = {
  /** `axod mcp` → axod, on `axod.sock`: asks, and waits for the outcome. */
  request: "axo.elicitation.request",
  /** A person's answer: client → ClientDO → HostDO → axod. */
  resolve: "axo.elicitation.resolve",
  /** axod → HostDO → clients: a card is needed. */
  requested: "axo.elicitation.requested",
  /** axod → HostDO → clients: it is settled; dismiss the card. */
  resolved: "axo.elicitation.resolved",
} as const;

export const ELICITATION_LIMITS = {
  messageChars: 1_000,
  /** Pending at once on one Mac; more are refused until one settles. */
  pendingPerHost: 32,
  /** How long one waits for an answer before it is cancelled. */
  timeoutMs: 5 * 60_000,
} as const;

export const ELICITATION_ERRORS = {
  /** Answered already, expired, or never asked. */
  notPending: -32011,
  /** Only a person answers: a Mac's own credential, or anything else, cannot. */
  notAPerson: -32012,
} as const;

/** What the person is asked. Only `confirm` (yes or no) exists yet. */
export const elicitationSchema = z.object({
  id: z.uuid(),
  sessionId: sessionIdSchema,
  kind: z.literal("confirm"),
  /** The agent's words, shown as the agent's. */
  message: z.string().min(1).max(ELICITATION_LIMITS.messageChars),
  /** Unix milliseconds. */
  createdAt: z.number().int().nonnegative(),
  expiresAt: z.number().int().nonnegative(),
}).strict();
export type Elicitation = z.infer<typeof elicitationSchema>;

/** What a person may answer. */
export const elicitationAnswerSchema = z.enum(["accept", "decline"]);
export type ElicitationAnswer = z.infer<typeof elicitationAnswerSchema>;
/** How one ends: the person's answer, or `cancel` when nobody answered in time or the asker left. */
export const elicitationOutcomeSchema = z.enum(["accept", "decline", "cancel"]);
export type ElicitationOutcome = z.infer<typeof elicitationOutcomeSchema>;

export const elicitationResolvedSchema = z.object({
  id: z.uuid(),
  sessionId: sessionIdSchema,
  action: elicitationOutcomeSchema,
}).strict();
export type ElicitationResolved = z.infer<typeof elicitationResolvedSchema>;

/** A client's answer, to its ClientDO. */
export const clientElicitationResolveParamsSchema = z.object({
  hostId: hostIdSchema,
  elicitationId: z.uuid(),
  action: elicitationAnswerSchema,
}).strict();
/** The answer as HostDO hands it to the Mac. */
export const hostElicitationResolveParamsSchema = z.object({
  target: hostRefSchema,
  elicitationId: z.uuid(),
  action: elicitationAnswerSchema,
}).strict();
export const elicitationResolveResultSchema = z.object({ resolved: z.literal(true) }).strict();

/** What ClientDO sends its client: the Mac a card belongs to, and the card or its end. */
export const clientElicitationRequestedParamsSchema = z.object({ hostId: hostIdSchema, elicitation: elicitationSchema }).strict();
export const clientElicitationResolvedParamsSchema = elicitationResolvedSchema.extend({ hostId: hostIdSchema }).strict();
