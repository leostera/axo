/**
 * Builds the public snapshot of a conversation and redacts it before it leaves the Mac.
 *
 * Nothing here uploads; the command in share-command.ts decides that. The rules:
 * - Only what was said and which tools ran is kept: no reasoning, no images, tool output is cut.
 * - Known secret shapes are scrubbed by pattern first, so no model ever sees them.
 * - A cheap classifier (Clef) flags fields that may still hold sensitive details; a cheap chat
 *   model (Haiku) names the exact substrings to remove from the flagged ones. Without a classifier,
 *   every field goes to the chat model. The model only names text to remove; it never rewrites.
 * - Any model failure fails the whole redaction. A snapshot is never published half-checked.
 */

export const SNAPSHOT_VERSION = 1;
export const MAX_TOOL_OUTPUT_CHARS = 4_000;
export const MAX_TEXT_CHARS = 20_000;
/** What the cloud accepts (`@axo/protocol`'s shared snapshot schema), with room for placeholders. */
export const MAX_TITLE_CHARS = 120;
export const MAX_SUBTITLE_CHARS = 1_000;
export const MAX_COMMAND_CHARS = 8_000;
/** Classifier probability from which a field is sent to the redacting model. Kept low on purpose. */
export const TRIAGE_THRESHOLD = 0.15;

export type SharedToolKind = "shell" | "edit" | "file" | "search" | "generic";

export interface SharedTool {
  callId: string | null;
  name: string;
  kind: SharedToolKind;
  subtitle: string | null;
  command: string | null;
  status: "completed" | "failed" | "running";
  output: string;
  outputTruncated: boolean;
}

export interface SharedMessage {
  id: string;
  role: "user" | "assistant" | "tool";
  text: string;
  timestamp: number | null;
  tool: SharedTool | null;
  images: [];
}

export interface SharedSnapshot {
  version: typeof SNAPSHOT_VERSION;
  title: string;
  publishedAt: string;
  messages: SharedMessage[];
}

export interface RedactionFinding {
  text: string;
  category: string;
}

/** The models redaction uses, so the logic can be tested without Pi. */
export interface RedactionModels {
  /** Probability that `text` holds sensitive information, or null when no classifier is available. */
  triage(text: string): Promise<number | null>;
  /** Exact substrings of `text` to remove. Throws when the model fails or answers badly. */
  findSensitive(text: string): Promise<RedactionFinding[]>;
}

export interface RedactionReport {
  /** Placeholders inserted, by category. */
  categories: Record<string, number>;
  fieldsChecked: number;
  fieldsSentToRedactor: number;
  classifierUsed: boolean;
}

// ---- building the snapshot from Pi's session ----

interface BranchEntry {
  type: string;
  id?: string;
  message?: unknown;
}

function asObject(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function cut(text: string, limit: number): { text: string; truncated: boolean } {
  return text.length <= limit ? { text, truncated: false } : { text: `${text.slice(0, limit)}\n…`, truncated: true };
}

function visibleText(content: unknown): string {
  if (typeof content === "string") return content.trim();
  return (Array.isArray(content) ? content : []).flatMap(raw => {
    const block = asObject(raw);
    if (block?.type === "text" && typeof block.text === "string") return [block.text];
    if (block?.type === "image") return ["[Image omitted]"];
    return [];
  }).join("\n").trim();
}

export function toolKind(name: string): SharedToolKind {
  switch (name) {
    case "bash": return "shell";
    case "edit": case "write": return "edit";
    case "read": return "file";
    case "grep": case "find": case "ls": case "search": return "search";
    default: return "generic";
  }
}

function toolFromCall(block: Record<string, unknown>): SharedTool | null {
  if (typeof block.name !== "string") return null;
  const args = asObject(block.arguments);
  const kind = toolKind(block.name);
  const subtitle = ["path", "file_path", "pattern", "query"]
    .map(key => args?.[key]).find((value): value is string => typeof value === "string") ?? null;
  const command = typeof args?.command === "string" ? args.command : null;
  return {
    callId: typeof block.id === "string" ? block.id : null,
    name: block.name,
    kind,
    subtitle: kind === "shell" || subtitle === null ? null : cut(subtitle, MAX_SUBTITLE_CHARS).text,
    command: kind === "shell" && command !== null ? cut(command, MAX_COMMAND_CHARS).text : null,
    status: "running",
    output: "",
    outputTruncated: false,
  };
}

/** What was said on the current branch, oldest first: words and tools, nothing else. */
export function buildSharedMessages(branch: readonly BranchEntry[]): SharedMessage[] {
  const messages: SharedMessage[] = [];
  const toolsByCall = new Map<string, number>();
  for (const [entryIndex, entry] of branch.entries()) {
    if (entry.type !== "message") continue;
    const message = asObject(entry.message);
    if (!message) continue;
    const baseId = entry.id ?? `entry-${entryIndex}`;
    const timestamp = typeof message.timestamp === "number" ? message.timestamp : null;

    if (message.role === "user") {
      const text = cut(visibleText(message.content), MAX_TEXT_CHARS).text;
      if (text) messages.push({ id: baseId, role: "user", text, timestamp, tool: null, images: [] });
      continue;
    }

    if (message.role === "assistant") {
      let words: string[] = [];
      let piece = 0;
      const flush = () => {
        const text = cut(words.join("\n").trim(), MAX_TEXT_CHARS).text;
        if (text) messages.push({ id: `${baseId}#${piece++}`, role: "assistant", text, timestamp, tool: null, images: [] });
        words = [];
      };
      const content = message.content;
      if (typeof content === "string") words.push(content);
      for (const raw of Array.isArray(content) ? content : []) {
        const block = asObject(raw);
        if (block?.type === "text" && typeof block.text === "string") words.push(block.text);
        else if (block?.type === "image") words.push("[Image omitted]");
        else if (block?.type === "toolCall") {
          flush();
          const tool = toolFromCall(block);
          if (!tool) continue;
          if (tool.callId) toolsByCall.set(tool.callId, messages.length);
          messages.push({ id: `${baseId}#${piece++}`, role: "tool", text: "", timestamp, tool, images: [] });
        }
        // Reasoning ("thinking") is deliberately never published.
      }
      flush();
      continue;
    }

    if (message.role === "toolResult" && typeof message.toolCallId === "string") {
      const index = toolsByCall.get(message.toolCallId);
      const owner = index === undefined ? undefined : messages[index];
      if (!owner?.tool) continue;
      const output = cut(visibleText(message.content), MAX_TOOL_OUTPUT_CHARS);
      owner.tool = {
        ...owner.tool,
        status: message.isError === true ? "failed" : "completed",
        output: output.text,
        outputTruncated: output.truncated || message.truncated === true,
      };
    }
  }
  return messages;
}

// ---- deterministic scrubbing ----

type Scrubber = { pattern: RegExp; category: string; keep?: (match: RegExpExecArray) => string };

/** Shapes that are secret wherever they appear. Order matters: the widest shapes go first. */
const SCRUBBERS: Scrubber[] = [
  { pattern: /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, category: "private-key" },
  { pattern: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/g, category: "aws-key" },
  { pattern: /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b/g, category: "github-token" },
  { pattern: /\bgithub_pat_[A-Za-z0-9_]{40,}\b/g, category: "github-token" },
  { pattern: /\bglpat-[A-Za-z0-9_-]{20,}\b/g, category: "gitlab-token" },
  { pattern: /\bxox[abposr]-[A-Za-z0-9-]{10,}\b/g, category: "slack-token" },
  { pattern: /\bsk-(?:ant-|proj-|or-)?[A-Za-z0-9_-]{20,}\b/g, category: "api-key" },
  { pattern: /\bAIza[0-9A-Za-z_-]{35}\b/g, category: "api-key" },
  { pattern: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g, category: "jwt" },
  { pattern: /\baxo1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{20,}\b/g, category: "session-token" },
  {
    pattern: /\b(Bearer|Basic|Token)\s+[A-Za-z0-9._~+/=-]{16,}/gi,
    category: "authorization",
    keep: match => `${match[1]} `,
  },
  {
    pattern: /\b([a-z][a-z0-9+.-]*:\/\/)[^\s/:@]+:[^\s/@]+@/gi,
    category: "url-credentials",
    keep: match => match[1]!,
  },
  {
    // A value, not code: no spaces or punctuation like `env.X`, `undefined;` or `secret()`, and a digit.
    pattern: /\b([A-Za-z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|PRIVATE_?KEY|ACCESS_?KEY|CREDENTIALS?)[A-Za-z0-9_]*)(\s*[=:]\s*)(["']?)(?=[A-Za-z0-9_+/=-]*\d)([A-Za-z0-9_+/=-]{8,})\3(?![A-Za-z0-9_.(])/gi,
    category: "secret",
    keep: match => `${match[1]}${match[2]}${match[3]}`,
  },
  { pattern: /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g, category: "email" },
];

export function placeholder(category: string): string {
  return `[redacted:${category}]`;
}

function count(report: RedactionReport, category: string, times = 1): void {
  report.categories[category] = (report.categories[category] ?? 0) + times;
}

/** Replaces known secret shapes and home-directory names, before any model sees the text. */
export function scrubText(text: string, report: RedactionReport): string {
  let result = text.replace(/(\/(?:Users|home)\/)[^/\s"'`]+/g, () => "~");
  for (const { pattern, category, keep } of SCRUBBERS) {
    result = result.replace(pattern, (...args) => {
      const match = args.slice(0, -2) as unknown as RegExpExecArray;
      count(report, category);
      return `${keep ? keep(match) : ""}${placeholder(category)}`;
    });
  }
  return result;
}

// ---- model redaction ----

interface FieldRef {
  get(): string;
  set(value: string): void;
}

function fieldsOf(snapshot: SharedSnapshot): FieldRef[] {
  const fields: FieldRef[] = [{ get: () => snapshot.title, set: value => { snapshot.title = value; } }];
  for (const message of snapshot.messages) {
    fields.push({ get: () => message.text, set: value => { message.text = value; } });
    const tool = message.tool;
    if (!tool) continue;
    fields.push({ get: () => tool.output, set: value => { tool.output = value; } });
    fields.push({ get: () => tool.command ?? "", set: value => { tool.command = tool.command === null ? null : value; } });
    fields.push({ get: () => tool.subtitle ?? "", set: value => { tool.subtitle = tool.subtitle === null ? null : value; } });
  }
  return fields;
}

const CATEGORY = /^[a-z][a-z0-9-]{0,31}$/;

/** Parses the redacting model's answer; throws on anything but the expected JSON. */
export function parseFindings(answer: string): RedactionFinding[] {
  const start = answer.indexOf("{");
  const end = answer.lastIndexOf("}");
  if (start < 0 || end < start) throw new Error("The redaction model did not answer with JSON");
  const parsed = asObject(JSON.parse(answer.slice(start, end + 1)));
  if (!parsed || !Array.isArray(parsed.redactions)) throw new Error("The redaction model's answer has no redactions list");
  return parsed.redactions.map(raw => {
    const finding = asObject(raw);
    if (typeof finding?.text !== "string") throw new Error("The redaction model named a redaction without text");
    const category = typeof finding.category === "string" && CATEGORY.test(finding.category) ? finding.category : "sensitive";
    return { text: finding.text, category };
  });
}

async function eachLimited<T>(items: readonly T[], limit: number, work: (item: T) => Promise<void>): Promise<void> {
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) await work(items[next++]!);
  });
  await Promise.all(workers);
}

function replaceAll(text: string, findings: readonly RedactionFinding[]): { text: string; replaced: Map<string, number> } {
  const replaced = new Map<string, number>();
  let result = text;
  for (const finding of findings) {
    const parts = result.split(finding.text);
    if (parts.length < 2) continue;
    replaced.set(finding.category, (replaced.get(finding.category) ?? 0) + parts.length - 1);
    result = parts.join(placeholder(finding.category));
  }
  return { text: result, replaced };
}

/**
 * Redacts a snapshot in place: scrub every field, triage with the classifier, ask the chat model
 * about flagged fields, then remove every named substring from every field (a secret seen once is
 * removed wherever it appears).
 */
export async function redactSnapshot(snapshot: SharedSnapshot, models: RedactionModels, concurrency = 4): Promise<RedactionReport> {
  const report: RedactionReport = { categories: {}, fieldsChecked: 0, fieldsSentToRedactor: 0, classifierUsed: false };
  const fields = fieldsOf(snapshot);
  for (const field of fields) field.set(scrubText(field.get(), report));

  const candidates = fields.filter(field => field.get().trim().length > 0);
  report.fieldsChecked = candidates.length;
  const findings: RedactionFinding[] = [];
  await eachLimited(candidates, concurrency, async field => {
    const text = field.get();
    const probability = await models.triage(text);
    if (probability !== null) report.classifierUsed = true;
    if (probability !== null && probability < TRIAGE_THRESHOLD) return;
    report.fieldsSentToRedactor += 1;
    for (const finding of await models.findSensitive(text)) {
      // Too-short names would shred ordinary words; placeholders are already safe.
      if (finding.text.trim().length >= 3 && !finding.text.includes("[redacted:")) findings.push(finding);
    }
  });

  findings.sort((a, b) => b.text.length - a.text.length);
  for (const field of fields) {
    const { text, replaced } = replaceAll(field.get(), findings);
    field.set(text);
    for (const [category, times] of replaced) count(report, category, times);
  }
  snapshot.title = snapshot.title.trim().slice(0, MAX_TITLE_CHARS).trim() || "Shared Axo session";
  keepWithinLimits(snapshot);
  return report;
}

/** Placeholders are longer than what they replace; cut fields back to what the cloud accepts. */
function keepWithinLimits(snapshot: SharedSnapshot): void {
  for (const message of snapshot.messages) {
    message.text = cut(message.text, MAX_TEXT_CHARS).text;
    const tool = message.tool;
    if (!tool) continue;
    const output = cut(tool.output, MAX_TOOL_OUTPUT_CHARS);
    tool.output = output.text;
    tool.outputTruncated ||= output.truncated;
    if (tool.command !== null) tool.command = cut(tool.command, MAX_COMMAND_CHARS).text;
    if (tool.subtitle !== null) tool.subtitle = cut(tool.subtitle, MAX_SUBTITLE_CHARS).text;
  }
}

// ---- prompts ----

export const TRIAGE_INSTRUCTIONS = [
  "Would publishing this text on the public internet expose sensitive information?",
  "Sensitive: credentials, API keys, tokens, passwords, private keys, connection strings, session cookies;",
  "personal data about real people (contact details, addresses, phone numbers, account handles tied to private data);",
  "customer or user data; internal hostnames, private IP addresses, internal URLs; account, zone or resource IDs;",
  "private business information such as unreleased plans, revenue, or confidential incidents.",
  "Not sensitive: ordinary source code, public libraries and tools, generic shell commands, public documentation,",
  "and placeholders that look like [redacted:...].",
].join(" ");

export const REDACTOR_SYSTEM_PROMPT = `You review text from a coding-agent conversation before it is published on the public internet.
Find every piece of sensitive information and return it so it can be removed.

Sensitive information includes: credentials, API keys, tokens, passwords, private keys, connection strings, cookies; personal data about real people (names together with contact details, email addresses, phone numbers, street addresses); customer or user data; internal hostnames, private IP addresses and internal URLs; account, zone, database or other resource identifiers; confidential business information.

Do not flag ordinary source code, public package names, public URLs, generic commands, file names, or text already replaced with [redacted:...].

Answer with JSON only, in exactly this shape:
{"redactions":[{"text":"<exact substring copied verbatim from the input>","category":"<short-kebab-case-category>"}]}
Copy each substring exactly, character for character, so it can be found and replaced. Return {"redactions":[]} when there is nothing to remove.`;

/** A readable file name for the redacted snapshot kept on this Mac. */
export function slugify(title: string): string {
  const slug = title.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase()
    .replace(/\[redacted:[^\]]*\]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60).replace(/-+$/, "");
  return slug || "session";
}
