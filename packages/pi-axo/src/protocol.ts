import { isAbsolute } from "node:path";
import { parseAttachments, type PromptAttachment } from "./attachments.js";
import { isThinkingLevel, type ThinkingLevel } from "./pi-state.js";

export const AXO_PI_PROTOCOL_VERSION = 1;
export const MAX_BRIDGE_RECORD_BYTES = 8 * 1024 * 1024;
const MAX_TEXT_BYTES = 64 * 1024;
const ID_PATTERN = /^[a-zA-Z0-9._:-]{1,128}$/u;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
/** A client's commandId: any hyphenated hexadecimal UUID, as axod checks it. */
const COMMAND_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;

export interface PiSessionIdentity {
  axoSessionId: string;
  axoPaneId: string;
  piSessionId: string;
  sessionFile: string | null;
  cwd: string;
  processId: number;
}

export type PiControlAction =
  /**
   * A prompt. With a `commandId` (a client's, RFD0024) it is taken at most once, recorded in the
   * log with a receipt, and queued in the log while Pi works: `delivery` says whether it waits
   * for the turn to end (`followUp`, the default) or joins it (`steer`, RFD0033).
   */
  | { kind: "send"; text: string; delivery?: "steer" | "followUp"; commandId?: string; attachments?: PromptAttachment[] }
  | { kind: "cancel" }
  /** Stops the running turn if `turnId`, the id of one of its user records, belongs to it. */
  | { kind: "stop"; turnId: string }
  | { kind: "shutdown" }
  | { kind: "shutdownIfIdle" }
  /** Switches this Session's model, thinking level, or both (RFD0033). */
  | { kind: "setModel"; model?: { provider: string; id: string }; thinkingLevel?: ThinkingLevel };

export interface PiControlCommand {
  requestId: string;
  axoSessionId: string;
  action: PiControlAction;
}

export type PiCommandResult =
  | { accepted: true }
  | { accepted: false; reason: "invalid" | "busy" | "idle" | "stale" | "unavailable" };

export interface PiBridgeAuthenticate {
  type: "authenticate";
  protocolVersion: typeof AXO_PI_PROTOCOL_VERSION;
  token: string;
}

export interface PiBridgeAuthenticated {
  type: "authenticated";
  protocolVersion: typeof AXO_PI_PROTOCOL_VERSION;
}

export interface PiBridgeHello {
  type: "hello";
  protocolVersion: typeof AXO_PI_PROTOCOL_VERSION;
  identity: PiSessionIdentity;
}

export interface PiBridgeEvent {
  type: "event";
  streamId: string;
  sequence: number;
  name: string;
  data: unknown;
}

export interface PiBridgeCommandResult {
  type: "commandResult";
  requestId: string;
  result: PiCommandResult;
}

export interface PiBridgeProtocolError {
  type: "protocolError";
  message: string;
}

export type PiBridgeRecord = PiBridgeAuthenticated | PiBridgeHello | PiBridgeEvent | PiBridgeCommandResult | PiBridgeProtocolError;

export type ParseCommandResult =
  | { ok: true; command: PiControlCommand }
  | { ok: false; reason: "invalid" | "stale" };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasOnlyKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  return Object.keys(value).every(key => keys.includes(key));
}

function isRequestId(value: unknown): value is string {
  return typeof value === "string" && ID_PATTERN.test(value);
}

function parseAction(value: unknown): PiControlAction | null {
  if (!isRecord(value) || typeof value.kind !== "string") return null;

  if (value.kind === "send") {
    if (!hasOnlyKeys(value, ["kind", "text", "delivery", "commandId", "attachments"]) || typeof value.text !== "string") return null;
    // Files axod fetched and checked (RFD0030); with any, the text may be empty.
    const attachments = value.attachments === undefined ? [] : parseAttachments(value.attachments);
    if (attachments === null) return null;
    if (new TextEncoder().encode(value.text).byteLength > MAX_TEXT_BYTES || (value.text.length === 0 && attachments.length === 0)) return null;
    if (value.delivery !== undefined && value.delivery !== "steer" && value.delivery !== "followUp") return null;
    if (value.commandId !== undefined && (typeof value.commandId !== "string" || !COMMAND_ID_PATTERN.test(value.commandId))) return null;
    return {
      kind: "send",
      text: value.text,
      ...(value.delivery === undefined ? {} : { delivery: value.delivery }),
      ...(value.commandId === undefined ? {} : { commandId: value.commandId.toLowerCase() }),
      ...(attachments.length === 0 ? {} : { attachments }),
    };
  }

  if (value.kind === "stop") {
    if (!hasOnlyKeys(value, ["kind", "turnId"]) || !isRequestId(value.turnId)) return null;
    return { kind: "stop", turnId: value.turnId };
  }

  if (value.kind === "setModel") {
    if (!hasOnlyKeys(value, ["kind", "model", "thinkingLevel"])) return null;
    if (value.model === undefined && value.thinkingLevel === undefined) return null;
    if (value.thinkingLevel !== undefined && !isThinkingLevel(value.thinkingLevel)) return null;
    let model: { provider: string; id: string } | undefined;
    if (value.model !== undefined) {
      if (!isRecord(value.model) || !hasOnlyKeys(value.model, ["provider", "id"])) return null;
      const { provider, id } = value.model;
      if (typeof provider !== "string" || typeof id !== "string" || provider.length === 0 || id.length === 0 || provider.length > 128 || id.length > 128) return null;
      model = { provider, id };
    }
    return {
      kind: "setModel",
      ...(model === undefined ? {} : { model }),
      ...(value.thinkingLevel === undefined ? {} : { thinkingLevel: value.thinkingLevel }),
    };
  }

  if (value.kind === "cancel" && hasOnlyKeys(value, ["kind"])) {
    return { kind: "cancel" };
  }
  if (value.kind === "shutdown" && hasOnlyKeys(value, ["kind"])) {
    return { kind: "shutdown" };
  }
  if (value.kind === "shutdownIfIdle" && hasOnlyKeys(value, ["kind"])) {
    return { kind: "shutdownIfIdle" };
  }
  return null;
}

export function parsePiControlCommand(value: unknown, expectedSessionId: string): ParseCommandResult {
  if (!isRecord(value) || !hasOnlyKeys(value, ["type", "requestId", "axoSessionId", "action"])) {
    return { ok: false, reason: "invalid" };
  }
  if (value.type !== "command" || !isRequestId(value.requestId) || typeof value.axoSessionId !== "string") {
    return { ok: false, reason: "invalid" };
  }
  if (!UUID_PATTERN.test(value.axoSessionId) || value.axoSessionId !== expectedSessionId) {
    return { ok: false, reason: "stale" };
  }

  const action = parseAction(value.action);
  if (action === null) return { ok: false, reason: "invalid" };
  return {
    ok: true,
    command: {
      requestId: value.requestId,
      axoSessionId: value.axoSessionId,
      action,
    },
  };
}

export function parsePiSessionIdentity(value: {
  axoSessionId: unknown;
  axoPaneId: unknown;
  piSessionId: unknown;
  sessionFile: unknown;
  cwd: unknown;
  processId: unknown;
}): PiSessionIdentity | null {
  if (typeof value.axoSessionId !== "string" || !UUID_PATTERN.test(value.axoSessionId)) return null;
  if (typeof value.axoPaneId !== "string" || !UUID_PATTERN.test(value.axoPaneId)) return null;
  if (typeof value.piSessionId !== "string" || !ID_PATTERN.test(value.piSessionId)) return null;
  if (value.sessionFile !== null && (
    typeof value.sessionFile !== "string" ||
    !isAbsolute(value.sessionFile) ||
    value.sessionFile.length > 4096 ||
    value.sessionFile.includes("\0")
  )) return null;
  if (typeof value.cwd !== "string" || !isAbsolute(value.cwd) || value.cwd.length > 4096 || value.cwd.includes("\0")) return null;
  if (!Number.isSafeInteger(value.processId) || (value.processId as number) < 1) return null;
  return {
    axoSessionId: value.axoSessionId,
    axoPaneId: value.axoPaneId,
    piSessionId: value.piSessionId,
    sessionFile: value.sessionFile as string | null,
    cwd: value.cwd,
    processId: value.processId as number,
  };
}
