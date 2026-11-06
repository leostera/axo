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
  /** An input answer that is missing, did not open, or does not fit its fields; it still waits. */
  badInput: -32014,
  /** Not signed by its device for this answer; it still waits. */
  badSignature: -32015,
  /** Answered already, expired, or never asked. */
  notPending: -32011,
  /** Only a person answers: a Mac's own credential, or anything else, cannot. */
  notAPerson: -32012,
  /** On `axod.sock`, only axod's own tools ask as a tool. */
  notATool: -32013,
} as const;

/**
 * Values sealed to a Mac's input key (RFD0029, the side channel for input): HPKE base mode with
 * DHKEM(P-256, HKDF-SHA256), HKDF-SHA256 and AES-256-GCM. The plaintext is
 * `{ "values": { "<field id>": "<value>" } }`, bound by `aad` to the request and the address shown.
 */
export const INPUT_SEAL = {
  info: "axo-ask-input/v1",
  aad: (requestId: string, origin: string | undefined) => `${requestId}\n${origin ?? ""}`,
  /** Fields one request asks for at most, and characters in one value. */
  maxFields: 8,
  maxChars: 1_000,
} as const;

/** What a field is for: the form gives it the matching autofill hint and entry. */
export const inputFieldKindSchema = z.enum(["username", "email", "password", "code", "text"]);
export type InputFieldKind = z.infer<typeof inputFieldKindSchema>;

/** Where an input request's values go, all of it the Mac's own reading of the window. */
export const inputRequestSchema = z.object({
  app: z.string().min(1).max(200),
  window: z.string().max(500),
  /** The page's origin, from the browser itself; absent outside a browser. */
  origin: z.string().min(1).max(500).optional(),
  fields: z.array(z.object({ id: z.string().regex(/^f[0-9]$/), label: z.string().max(200), kind: inputFieldKindSchema }).strict()).min(1).max(INPUT_SEAL.maxFields),
  submit: z.string().min(1).max(200).optional(),
  /** The Mac's input key: base64 of an uncompressed P-256 point. Pinned per Mac. */
  key: z.base64().length(88),
}).strict();
export type InputRequest = z.infer<typeof inputRequestSchema>;

export const sealedSchema = z.object({
  enc: z.base64().length(88),
  ciphertext: z.base64().min(4).max(16_384),
}).strict();
export type Sealed = z.infer<typeof sealedSchema>;

/**
 * What a phone or a browser sends with every answer (RFD0029): its key, its name and its ECDSA
 * P-256 signature over that answer alone.
 */
export const deviceProofSchema = z.object({
  key: z.base64().length(88),
  name: z.string().min(1).max(80),
  signature: z.base64().length(88),
}).strict();
export type DeviceProof = z.infer<typeof deviceProofSchema>;

/** What the person is asked: yes or no, or values for a form's fields. */
export const elicitationSchema = z.object({
  id: z.uuid(),
  sessionId: sessionIdSchema,
  kind: z.enum(["confirm", "input"]),
  /**
   * Who asks: the agent, in its own words, or Axo's computer-use gate, describing what it is
   * about to do. axod lets only its own `axod mcp` ask as a tool. Absent from an older axod.
   */
  askedBy: z.enum(["agent", "computerUse"]).default("agent"),
  /** The asker's words, shown as theirs. */
  message: z.string().min(1).max(ELICITATION_LIMITS.messageChars),
  /** For `input`: the fields, where they go, and the key to seal them to. */
  input: inputRequestSchema.optional(),
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
  /** An accepted input request's values, sealed to the Mac: the cloud never reads them. */
  sealed: sealedSchema.optional(),
  device: deviceProofSchema.optional(),
}).strict();
/** The answer as HostDO hands it to the Mac. */
export const hostElicitationResolveParamsSchema = z.object({
  target: hostRefSchema,
  elicitationId: z.uuid(),
  action: elicitationAnswerSchema,
  sealed: sealedSchema.optional(),
  device: deviceProofSchema.optional(),
}).strict();
export const elicitationResolveResultSchema = z.object({ resolved: z.literal(true) }).strict();

/** What ClientDO sends its client: the Mac a card belongs to, and the card or its end. */
export const clientElicitationRequestedParamsSchema = z.object({ hostId: hostIdSchema, elicitation: elicitationSchema }).strict();
export const clientElicitationResolvedParamsSchema = elicitationResolvedSchema.extend({ hostId: hostIdSchema }).strict();
