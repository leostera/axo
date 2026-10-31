import { z } from "zod";
import { tool, type AppDefinition, type AppTool, type ProviderApi } from "./app";

/**
 * Gmail as an app: `codemode.apps.gmail.<tool>({ account, ... })` over the Gmail REST API, as
 * one of the Google accounts the person signed in with. The grant is full access
 * (`https://mail.google.com/`): it reads, sends, drafts, labels, trashes and deletes mail; and
 * Gmail's settings (`gmail.settings.basic`, `gmail.settings.sharing`): filters, vacation
 * replies, send-as addresses and forwarding.
 */

export const GMAIL_SCOPE = "https://mail.google.com/";
/** Full mail access, and the settings it does not cover: filters, forwarding, send-as and delegates. */
export const GMAIL_SCOPES = [GMAIL_SCOPE, "https://www.googleapis.com/auth/gmail.settings.basic", "https://www.googleapis.com/auth/gmail.settings.sharing"];
const BASE = "/gmail/v1/users/me";
const DEFAULT_BODY_CHARS = 20_000;
const MAX_BODY_CHARS = 200_000;

const id = z.string().regex(/^[A-Za-z0-9_-]{1,256}$/, "expected a Gmail ID");
const labelIds = z.array(z.string().min(1).max(256)).max(100);
/** One header value: no line breaks, so no header can be smuggled in. */
const line = (max: number) => z.string().max(max).regex(/^[^\r\n]*$/, "may not contain line breaks");
const addresses = z.union([line(2048), z.array(line(512)).max(100)]);
const maxBodyChars = z.number().int().min(0).max(MAX_BODY_CHARS).optional()
  .describe(`How much of each body to return, in characters; default ${DEFAULT_BODY_CHARS}.`);

const composeSchema = z.object({
  to: addresses.optional().describe("Recipients, as \"a@example.com\" or \"Ada <a@example.com>\"; a string may list several, separated by commas."),
  cc: addresses.optional(),
  bcc: addresses.optional(),
  subject: line(998).optional().describe("Required unless replying; a reply defaults to \"Re: \" and the original subject."),
  text: z.string().max(1_000_000).describe("The plain-text body."),
  html: z.string().max(1_000_000).optional().describe("An HTML body, sent alongside the text."),
  replyToMessageId: id.optional().describe("The Gmail ID of a message to reply to: threads the reply and sets In-Reply-To and References."),
}).strict();
type Compose = z.infer<typeof composeSchema>;

type Header = { name: string; value: string };
type Part = {
  partId?: string;
  mimeType?: string;
  filename?: string;
  headers?: Header[];
  body?: { size?: number; data?: string; attachmentId?: string };
  parts?: Part[];
};
type Message = { id: string; threadId: string; labelIds?: string[]; snippet?: string; internalDate?: string; sizeEstimate?: number; payload?: Part };

const tools: AppTool[] = [
  tool({
    name: "get_profile",
    description: "Returns the signed-in Gmail account: { emailAddress, messagesTotal, threadsTotal, historyId }.",
    input: z.object({}).strict(),
    idempotent: true,
    run: (api) => api.request("GET", `${BASE}/profile`),
  }),
  tool({
    name: "search_messages",
    description:
      "Searches messages with Gmail's search syntax (e.g. \"from:ada is:unread newer_than:7d\") and returns " +
      "{ messages: [{ id, threadId, from, to, subject, date, snippet, labelIds }], nextPageToken, resultSizeEstimate }. " +
      "Pass nextPageToken back as pageToken for more. Read a message's body with get_message.",
    input: z.object({
      query: z.string().max(2048).optional(),
      labelIds: labelIds.optional().describe("Only messages with all of these labels, e.g. [\"INBOX\", \"UNREAD\"]."),
      maxResults: z.number().int().min(1).max(50).optional().describe("Default 10."),
      pageToken: z.string().max(512).optional(),
      includeSpamTrash: z.boolean().optional(),
    }).strict(),
    idempotent: true,
    async run(api, input) {
      const list = (await api.request("GET", `${BASE}/messages`, {
        query: {
          q: input.query,
          labelIds: input.labelIds,
          maxResults: String(input.maxResults ?? 10),
          pageToken: input.pageToken,
          includeSpamTrash: input.includeSpamTrash ? "true" : undefined,
        },
      })) as { messages?: Array<{ id: string }>; nextPageToken?: string; resultSizeEstimate?: number };
      const messages = await Promise.all((list.messages ?? []).map(async ({ id }) => summary((await api.request("GET", `${BASE}/messages/${id}`, {
        query: { format: "metadata", metadataHeaders: ["From", "To", "Cc", "Subject", "Date"] },
      })) as Message)));
      return { messages, nextPageToken: list.nextPageToken ?? null, resultSizeEstimate: list.resultSizeEstimate ?? messages.length };
    },
  }),
  tool({
    name: "get_message",
    description:
      "Reads one message: { id, threadId, labelIds, from, to, cc, subject, date, messageId, snippet, text, html?, textTruncated, attachments: [{ filename, mimeType, size }] }. " +
      "`text` is the plain-text body, or the HTML body as text when there is none.",
    input: z.object({ id, maxBodyChars, includeHtml: z.boolean().optional().describe("Also return the HTML body, if any.") }).strict(),
    idempotent: true,
    async run(api, input) {
      return full((await api.request("GET", `${BASE}/messages/${input.id}`, { query: { format: "full" } })) as Message, input.maxBodyChars, input.includeHtml);
    },
  }),
  tool({
    name: "get_thread",
    description: "Reads a whole thread: { id, messages: [...] }, each message as get_message returns it, oldest first.",
    input: z.object({ id, maxBodyChars }).strict(),
    idempotent: true,
    async run(api, input) {
      const thread = (await api.request("GET", `${BASE}/threads/${input.id}`, { query: { format: "full" } })) as { id: string; messages?: Message[] };
      return { id: thread.id, messages: (thread.messages ?? []).map((message) => full(message, input.maxBodyChars ?? 10_000, false)) };
    },
  }),
  tool({
    name: "list_labels",
    description: "Lists labels: { labels: [{ id, name, type }] }. System labels include INBOX, UNREAD, STARRED, IMPORTANT, SENT, DRAFT, SPAM and TRASH.",
    input: z.object({}).strict(),
    idempotent: true,
    async run(api) {
      const answer = (await api.request("GET", `${BASE}/labels`)) as { labels?: Array<{ id: string; name: string; type?: string }> };
      return { labels: (answer.labels ?? []).map(({ id, name, type }) => ({ id, name, type: type ?? null })) };
    },
  }),
  tool({
    name: "send_message",
    description: "Sends an email from the signed-in account and returns { id, threadId, labelIds }. Give replyToMessageId to reply in a thread. A call that may have run is not safe to repeat: check the Sent label first.",
    input: composeSchema,
    idempotent: false,
    async run(api, input) {
      const { raw, threadId } = await compose(api, input);
      return api.request("POST", `${BASE}/messages/send`, { body: { raw, ...(threadId ? { threadId } : {}) } });
    },
  }),
  tool({
    name: "create_draft",
    description: "Saves a draft instead of sending it, and returns { id, message: { id, threadId } }. Takes the same input as send_message.",
    input: composeSchema,
    idempotent: false,
    async run(api, input) {
      const { raw, threadId } = await compose(api, input);
      return api.request("POST", `${BASE}/drafts`, { body: { message: { raw, ...(threadId ? { threadId } : {}) } } });
    },
  }),
  tool({
    name: "modify_message",
    description:
      "Adds and removes labels on a message and returns { id, threadId, labelIds }. Archive: remove INBOX. Mark read: remove UNREAD. Star: add STARRED.",
    input: z.object({ id, addLabelIds: labelIds.optional(), removeLabelIds: labelIds.optional() }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("POST", `${BASE}/messages/${input.id}/modify`, {
        body: { addLabelIds: input.addLabelIds ?? [], removeLabelIds: input.removeLabelIds ?? [] },
      })) as Message;
      return { id: answer.id, threadId: answer.threadId, labelIds: answer.labelIds ?? [] };
    },
  }),
  tool({
    name: "trash_message",
    description: "Moves a message to the trash (Gmail deletes it after 30 days) and returns { id, threadId, labelIds }.",
    input: z.object({ id }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("POST", `${BASE}/messages/${input.id}/trash`)) as Message;
      return { id: answer.id, threadId: answer.threadId, labelIds: answer.labelIds ?? [] };
    },
  }),
  tool({
    name: "delete_message",
    description: "Deletes a message for good, skipping the trash; it cannot be recovered. Prefer trash_message unless asked to delete permanently. Returns { deleted: true }.",
    input: z.object({ id }).strict(),
    idempotent: true,
    async run(api, input) {
      await api.request("DELETE", `${BASE}/messages/${input.id}`);
      return { deleted: true };
    },
  }),
  tool({
    name: "list_filters",
    description: "Lists the account's filters: { filters: [{ id, criteria, action }] }, in Gmail's settings API shape.",
    input: z.object({}).strict(),
    idempotent: true,
    async run(api) {
      const answer = (await api.request("GET", `${BASE}/settings/filters`)) as { filter?: unknown[] } | null;
      return { filters: answer?.filter ?? [] };
    },
  }),
  tool({
    name: "create_filter",
    description:
      "Creates a filter for incoming mail and returns it. criteria: { from, to, subject, query, negatedQuery, hasAttachment, size, sizeComparison }; " +
      "action: { addLabelIds, removeLabelIds, forward } (remove \"INBOX\" to archive, add \"TRASH\" to delete, remove \"UNREAD\" to mark read).",
    input: z.object({ criteria: z.record(z.string(), z.unknown()), action: z.record(z.string(), z.unknown()) }).strict(),
    idempotent: false,
    run: (api, input) => api.request("POST", `${BASE}/settings/filters`, { body: input }),
  }),
  tool({
    name: "delete_filter",
    description: "Deletes a filter by its id. Returns { deleted: true }.",
    input: z.object({ id }).strict(),
    idempotent: true,
    async run(api, input) {
      await api.request("DELETE", `${BASE}/settings/filters/${input.id}`);
      return { deleted: true };
    },
  }),
  tool({
    name: "get_vacation",
    description: "Reads the vacation auto-reply: { enableAutoReply, responseSubject, responseBodyPlainText, startTime, endTime, ... }.",
    input: z.object({}).strict(),
    idempotent: true,
    run: (api) => api.request("GET", `${BASE}/settings/vacation`),
  }),
  tool({
    name: "set_vacation",
    description: "Turns the vacation auto-reply on or off and returns it. Times are milliseconds since the epoch; restrictToContacts and restrictToDomain limit who gets it.",
    input: z.object({
      enableAutoReply: z.boolean(),
      responseSubject: z.string().max(998).optional(),
      responseBodyPlainText: z.string().max(100_000).optional(),
      responseBodyHtml: z.string().max(100_000).optional(),
      startTime: z.number().int().optional(),
      endTime: z.number().int().optional(),
      restrictToContacts: z.boolean().optional(),
      restrictToDomain: z.boolean().optional(),
    }).strict(),
    idempotent: true,
    run: (api, input) => api.request("PUT", `${BASE}/settings/vacation`, { body: { ...input, startTime: input.startTime?.toString(), endTime: input.endTime?.toString() } }),
  }),
  tool({
    name: "list_send_as",
    description: "Lists the addresses the account can send as, with their signatures: { sendAs: [{ sendAsEmail, displayName, signature, isDefault, isPrimary }] }.",
    input: z.object({}).strict(),
    idempotent: true,
    run: (api) => api.request("GET", `${BASE}/settings/sendAs`),
  }),
];

export const gmail: AppDefinition = {
  name: "gmail",
  title: "Gmail",
  description: "Read, search, send and organize your mail, and manage Gmail's settings.",
  permissions: [
    "Read, search and download every message and attachment",
    "Send mail and replies, and write drafts",
    "Label, archive, trash and permanently delete mail",
    "Manage labels, filters, forwarding, aliases, signatures and vacation replies",
  ],
  provider: "google",
  category: "communication",
  scopes: ["openid", "email", ...GMAIL_SCOPES],
  requiredScopes: GMAIL_SCOPES,
  apiOrigin: "https://gmail.googleapis.com",
  hosts: ["gmail.googleapis.com", "www.googleapis.com"],
  reference: "https://developers.google.com/workspace/gmail/api/reference/rest",
  tools,
};

// ─── Reading messages ──────────────────────────────────────────────────────────

function header(part: Part | undefined, name: string): string | null {
  const lower = name.toLowerCase();
  return part?.headers?.find((h) => h.name.toLowerCase() === lower)?.value ?? null;
}

function summary(message: Message) {
  return {
    id: message.id,
    threadId: message.threadId,
    from: header(message.payload, "From"),
    to: header(message.payload, "To"),
    subject: header(message.payload, "Subject"),
    date: header(message.payload, "Date"),
    snippet: message.snippet ?? "",
    labelIds: message.labelIds ?? [],
  };
}

function full(message: Message, maxChars = DEFAULT_BODY_CHARS, includeHtml = false) {
  const parts = flatten(message.payload);
  const textPart = parts.find((p) => p.mimeType === "text/plain" && !p.filename && p.body?.data);
  const htmlPart = parts.find((p) => p.mimeType === "text/html" && !p.filename && p.body?.data);
  const html = htmlPart ? decodeBody(htmlPart) : null;
  const body = textPart ? decodeBody(textPart) : html !== null ? htmlToText(html) : "";
  return {
    ...summary(message),
    cc: header(message.payload, "Cc"),
    messageId: header(message.payload, "Message-ID"),
    text: body.slice(0, maxChars),
    textTruncated: body.length > maxChars,
    ...(includeHtml && html !== null ? { html: html.slice(0, maxChars) } : {}),
    attachments: parts
      .filter((p) => p.filename && p.body?.attachmentId)
      .map((p) => ({ filename: p.filename!, mimeType: p.mimeType ?? "application/octet-stream", size: p.body?.size ?? 0 })),
  };
}

function flatten(part: Part | undefined): Part[] {
  if (!part) return [];
  return [part, ...(part.parts ?? []).flatMap(flatten)];
}

function decodeBody(part: Part): string {
  const bytes = fromBase64Url(part.body?.data ?? "");
  const charset = /charset="?([^";\s]+)"?/i.exec(header(part, "Content-Type") ?? "")?.[1] ?? "utf-8";
  try {
    return new TextDecoder(charset).decode(bytes);
  } catch {
    return new TextDecoder().decode(bytes);
  }
}

/** Enough HTML-to-text for reading mail: drops markup, keeps line structure. */
export function htmlToText(html: string): string {
  return html
    .replace(/<(script|style|head)[^>]*>[\s\S]*?<\/\1>/gi, "")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|li|tr|h[1-6]|blockquote)>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/gi, " ")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, "\"")
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&amp;/gi, "&")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

// ─── Writing messages ──────────────────────────────────────────────────────────

/** Builds the RFC 5322 message Gmail sends, and the thread a reply belongs to. */
async function compose(api: ProviderApi, input: Compose): Promise<{ raw: string; threadId: string | null }> {
  let subject = input.subject ?? null;
  let threadId: string | null = null;
  const headers: Array<[string, string]> = [];
  if (input.replyToMessageId) {
    const original = (await api.request("GET", `${BASE}/messages/${input.replyToMessageId}`, {
      query: { format: "metadata", metadataHeaders: ["Subject", "Message-ID", "References"] },
    })) as Message;
    threadId = original.threadId;
    const messageId = header(original.payload, "Message-ID");
    if (messageId) {
      headers.push(["In-Reply-To", messageId]);
      headers.push(["References", [header(original.payload, "References"), messageId].filter(Boolean).join(" ")]);
    }
    const originalSubject = header(original.payload, "Subject") ?? "";
    subject ??= /^re:/i.test(originalSubject) ? originalSubject : `Re: ${originalSubject}`;
  }
  if (subject === null) throw new Error("subject is required unless replying");
  const to = list(input.to);
  const cc = list(input.cc);
  const bcc = list(input.bcc);
  if (to.length + cc.length + bcc.length === 0) throw new Error("give at least one recipient in to, cc or bcc");
  if (to.length) headers.unshift(["To", to.map(address).join(", ")]);
  if (cc.length) headers.push(["Cc", cc.map(address).join(", ")]);
  if (bcc.length) headers.push(["Bcc", bcc.map(address).join(", ")]);
  headers.push(["Subject", encodeWord(subject)], ["MIME-Version", "1.0"]);
  const text = ["Content-Type: text/plain; charset=\"UTF-8\"", "Content-Transfer-Encoding: base64", "", wrap(toBase64(input.text))].join("\r\n");
  let body: string;
  if (input.html === undefined) body = text;
  else {
    const boundary = `axo-${crypto.randomUUID()}`;
    const html = ["Content-Type: text/html; charset=\"UTF-8\"", "Content-Transfer-Encoding: base64", "", wrap(toBase64(input.html))].join("\r\n");
    body = [`Content-Type: multipart/alternative; boundary="${boundary}"`, "", `--${boundary}`, text, `--${boundary}`, html, `--${boundary}--`].join("\r\n");
  }
  // A single-part body's own headers belong with the message's.
  const message = `${headers.map(([name, value]) => `${name}: ${value}`).join("\r\n")}\r\n${body}`;
  return { raw: toBase64Url(new TextEncoder().encode(message)), threadId };
}

function list(value: string | string[] | undefined): string[] {
  if (value === undefined) return [];
  const entries = Array.isArray(value) ? value : splitAddresses(value);
  return entries.map((entry) => entry.trim()).filter(Boolean);
}

/** Splits "a@x, Ada <b@y>" on commas outside quotes and angle brackets. */
function splitAddresses(value: string): string[] {
  const out: string[] = [];
  let current = "";
  let quoted = false;
  let angle = false;
  for (const char of value) {
    if (char === "\"") quoted = !quoted;
    else if (char === "<" && !quoted) angle = true;
    else if (char === ">" && !quoted) angle = false;
    if (char === "," && !quoted && !angle) {
      out.push(current);
      current = "";
    } else current += char;
  }
  out.push(current);
  return out;
}

const EMAIL = /^[^\s@<>",]+@[^\s@<>",]+$/;

/** One address, with a display name encoded if it is not ASCII. */
export function address(entry: string): string {
  const named = /^(.*)<([^<>]+)>$/.exec(entry.trim());
  const email = (named ? named[2]! : entry).trim();
  if (!EMAIL.test(email)) throw new Error(`not an email address: ${email.slice(0, 100)}`);
  const name = named?.[1]!.trim().replace(/^"(.*)"$/, "$1") ?? "";
  if (!name) return email;
  return `${/^[\x20-\x7e]*$/.test(name) ? `"${name.replace(/["\\]/g, "\\$&")}"` : encodeWord(name)} <${email}>`;
}

/** A header value as an RFC 2047 encoded word when it is not plain ASCII. */
export function encodeWord(value: string): string {
  return /^[\x20-\x7e]*$/.test(value) ? value : `=?UTF-8?B?${toBase64(value)}?=`;
}

function wrap(base64: string): string {
  return base64.replace(/.{1,76}/g, "$&\r\n").trimEnd();
}

function toBase64(text: string): string {
  return bytesToBase64(new TextEncoder().encode(text));
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

function toBase64Url(bytes: Uint8Array): string {
  return bytesToBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64Url(data: string): Uint8Array {
  const base64 = data.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, "="));
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}
