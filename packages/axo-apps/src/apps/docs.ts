import { z } from "zod";
import { tool, type AppDefinition, type AppTool } from "../app";

/**
 * Google Docs as an app: `codemode.apps.docs.<tool>({ account, ... })` over the Docs API, with
 * full access (`documents`): read documents as text, create them, and change their text. Finding
 * a document is Drive's search (apps.drive.search_files).
 */

export const DOCS_SCOPE = "https://www.googleapis.com/auth/documents";
const BASE = "/v1/documents";
const DEFAULT_CHARS = 100_000;

const documentId = z.string().regex(/^[A-Za-z0-9_-]{1,256}$/, "expected a document ID");

type Element = {
  paragraph?: { elements?: Array<{ textRun?: { content?: string } }> };
  table?: { tableRows?: Array<{ tableCells?: Array<{ content?: Element[] }> }> };
  tableOfContents?: { content?: Element[] };
};
type Document = { documentId: string; title?: string; revisionId?: string; body?: { content?: Element[] } };

const tools: AppTool[] = [
  tool({
    name: "get_document",
    description: "Reads a document as plain text: { id, title, text, truncated, url }. Tables read as tab-separated rows.",
    input: z.object({ id: documentId, maxChars: z.number().int().min(1).max(500_000).optional().describe(`Default ${DEFAULT_CHARS}.`) }).strict(),
    idempotent: true,
    async run(api, input) {
      const doc = (await api.request("GET", `${BASE}/${input.id}`)) as Document;
      const text = textOf(doc.body?.content ?? []);
      const max = input.maxChars ?? DEFAULT_CHARS;
      return { id: doc.documentId, title: doc.title ?? null, text: text.slice(0, max), truncated: text.length > max, url: url(doc.documentId) };
    },
  }),
  tool({
    name: "create_document",
    description: "Creates a document, with `text` as its body if given, and returns { id, title, url }.",
    input: z.object({ title: z.string().min(1).max(1024), text: z.string().max(1_000_000).optional() }).strict(),
    idempotent: false,
    async run(api, input) {
      const doc = (await api.request("POST", BASE, { body: { title: input.title } })) as Document;
      if (input.text) await api.request("POST", `${BASE}/${doc.documentId}:batchUpdate`, { body: { requests: [{ insertText: { location: { index: 1 }, text: input.text } }] } });
      return { id: doc.documentId, title: doc.title ?? input.title, url: url(doc.documentId) };
    },
  }),
  tool({
    name: "append_text",
    description: "Adds text at the end of a document and returns { id, url }. Start it with \"\\n\" for a new paragraph.",
    input: z.object({ id: documentId, text: z.string().min(1).max(1_000_000) }).strict(),
    idempotent: false,
    async run(api, input) {
      await api.request("POST", `${BASE}/${input.id}:batchUpdate`, { body: { requests: [{ insertText: { endOfSegmentLocation: {}, text: input.text } }] } });
      return { id: input.id, url: url(input.id) };
    },
  }),
  tool({
    name: "replace_text",
    description: "Replaces every occurrence of `find` with `replace` and returns { id, replaced } with how many were.",
    input: z.object({ id: documentId, find: z.string().min(1).max(10_000), replace: z.string().max(100_000), matchCase: z.boolean().optional() }).strict(),
    idempotent: false,
    async run(api, input) {
      const answer = (await api.request("POST", `${BASE}/${input.id}:batchUpdate`, {
        body: { requests: [{ replaceAllText: { containsText: { text: input.find, matchCase: input.matchCase ?? true }, replaceText: input.replace } }] },
      })) as { replies?: Array<{ replaceAllText?: { occurrencesChanged?: number } }> };
      return { id: input.id, replaced: answer.replies?.[0]?.replaceAllText?.occurrencesChanged ?? 0 };
    },
  }),
];

export const docs: AppDefinition = {
  name: "docs",
  title: "Google Docs",
  description: "Read and write your documents.",
  permissions: [
    "Read every document you can open",
    "Create documents and change their text and formatting",
  ],
  signIn: "oauth",
  provider: "google",
  providerTitle: "Google",
  category: "files",
  scopes: ["openid", "email", DOCS_SCOPE],
  requiredScopes: [DOCS_SCOPE],
  apiOrigin: "https://docs.googleapis.com",
  hosts: ["docs.googleapis.com"],
  reference: "https://developers.google.com/workspace/docs/api/reference/rest",
  tools,
};

function url(id: string): string {
  return `https://docs.google.com/document/d/${id}/edit`;
}

/** A document's body as text: paragraphs as they are, a table's cells tab-separated. */
export function textOf(content: Element[]): string {
  let text = "";
  for (const element of content) {
    if (element.paragraph) for (const run of element.paragraph.elements ?? []) text += run.textRun?.content ?? "";
    if (element.table)
      for (const row of element.table.tableRows ?? [])
        text += `${(row.tableCells ?? []).map((cell) => textOf(cell.content ?? []).trim()).join("\t")}\n`;
    if (element.tableOfContents) text += textOf(element.tableOfContents.content ?? []);
  }
  return text;
}
