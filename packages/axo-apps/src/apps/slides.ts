import { z } from "zod";
import { tool, type AppDefinition, type AppTool } from "../app";

/**
 * Google Slides as an app: `codemode.apps.slides.<tool>({ account, ... })` over the Slides API,
 * with full access (`presentations`): read presentations as text, create them, add slides and
 * change them. Finding a presentation is Drive's search (apps.drive.search_files).
 */

export const SLIDES_SCOPE = "https://www.googleapis.com/auth/presentations";
const BASE = "/v1/presentations";

const presentationId = z.string().regex(/^[A-Za-z0-9_-]{1,256}$/, "expected a presentation ID");
const objectId = z.string().regex(/^[A-Za-z0-9_:-]{1,256}$/, "expected a slide or element ID");

type TextElement = { textRun?: { content?: string } };
type PageElement = {
  objectId: string;
  shape?: { placeholder?: { type?: string }; text?: { textElements?: TextElement[] } };
  table?: { tableRows?: Array<{ tableCells?: Array<{ text?: { textElements?: TextElement[] } }> }> };
  elementGroup?: { children?: PageElement[] };
};
type Page = { objectId: string; pageElements?: PageElement[]; slideProperties?: { notesPage?: Page } };
type Presentation = { presentationId: string; title?: string; slides?: Page[]; revisionId?: string };

const LAYOUTS = ["BLANK", "TITLE", "TITLE_AND_BODY", "TITLE_AND_TWO_COLUMNS", "TITLE_ONLY", "SECTION_HEADER", "ONE_COLUMN_TEXT", "MAIN_POINT", "BIG_NUMBER", "CAPTION_ONLY"] as const;

const tools: AppTool[] = [
  tool({
    name: "get_presentation",
    description: "Reads a presentation as text: { id, title, url, slides: [{ id, index, text, notes }] }.",
    input: z.object({ id: presentationId }).strict(),
    idempotent: true,
    async run(api, input) {
      const p = (await api.request("GET", `${BASE}/${input.id}`)) as Presentation;
      return {
        id: p.presentationId,
        title: p.title ?? null,
        url: url(p.presentationId),
        slides: (p.slides ?? []).map((slide, index) => ({
          id: slide.objectId,
          index,
          text: textOf(slide.pageElements ?? []).trim(),
          notes: textOf(slide.slideProperties?.notesPage?.pageElements ?? [], "BODY").trim(),
        })),
      };
    },
  }),
  tool({
    name: "create_presentation",
    description: "Creates a presentation and returns { id, title, url }. It starts with one title slide.",
    input: z.object({ title: z.string().min(1).max(1024) }).strict(),
    idempotent: false,
    async run(api, input) {
      const p = (await api.request("POST", BASE, { body: { title: input.title } })) as Presentation;
      return { id: p.presentationId, title: p.title ?? input.title, url: url(p.presentationId) };
    },
  }),
  tool({
    name: "add_slide",
    description:
      `Adds a slide with a layout (${LAYOUTS.join(", ")}; default TITLE_AND_BODY), filling its title and body if given, at \`index\` or the end. Returns { id, url }.`,
    input: z.object({
      id: presentationId,
      layout: z.enum(LAYOUTS).optional(),
      title: z.string().max(10_000).optional(),
      body: z.string().max(100_000).optional(),
      index: z.number().int().min(0).optional(),
    }).strict(),
    idempotent: false,
    async run(api, input) {
      const slideId = `axo_${crypto.randomUUID().replace(/-/g, "")}`;
      const titleId = `${slideId}_t`;
      const bodyId = `${slideId}_b`;
      const layout = input.layout ?? "TITLE_AND_BODY";
      const mappings = [
        ...(input.title !== undefined ? [{ layoutPlaceholder: { type: layout === "CAPTION_ONLY" ? "BODY" : "TITLE" }, objectId: titleId }] : []),
        ...(input.body !== undefined ? [{ layoutPlaceholder: { type: "BODY" }, objectId: bodyId }] : []),
      ];
      await api.request("POST", `${BASE}/${input.id}:batchUpdate`, {
        body: {
          requests: [
            { createSlide: { objectId: slideId, insertionIndex: input.index, slideLayoutReference: { predefinedLayout: layout }, placeholderIdMappings: mappings } },
            ...(input.title ? [{ insertText: { objectId: titleId, text: input.title } }] : []),
            ...(input.body ? [{ insertText: { objectId: bodyId, text: input.body } }] : []),
          ],
        },
      });
      return { id: slideId, url: `${url(input.id)}#slide=id.${slideId}` };
    },
  }),
  tool({
    name: "replace_text",
    description: "Replaces every occurrence of `find` with `replace` across the presentation (or only `slideIds`), and returns { replaced } with how many were.",
    input: z.object({
      id: presentationId,
      find: z.string().min(1).max(10_000),
      replace: z.string().max(100_000),
      matchCase: z.boolean().optional(),
      slideIds: z.array(objectId).max(500).optional(),
    }).strict(),
    idempotent: false,
    async run(api, input) {
      const answer = (await api.request("POST", `${BASE}/${input.id}:batchUpdate`, {
        body: { requests: [{ replaceAllText: { containsText: { text: input.find, matchCase: input.matchCase ?? true }, replaceText: input.replace, pageObjectIds: input.slideIds } }] },
      })) as { replies?: Array<{ replaceAllText?: { occurrencesChanged?: number } }> };
      return { replaced: answer.replies?.[0]?.replaceAllText?.occurrencesChanged ?? 0 };
    },
  }),
  tool({
    name: "delete_slide",
    description: "Deletes a slide by its id. Returns { deleted: true }.",
    input: z.object({ id: presentationId, slideId: objectId }).strict(),
    idempotent: false,
    async run(api, input) {
      await api.request("POST", `${BASE}/${input.id}:batchUpdate`, { body: { requests: [{ deleteObject: { objectId: input.slideId } }] } });
      return { deleted: true };
    },
  }),
  tool({
    name: "batch_update",
    description:
      "Sends Slides batchUpdate requests as they are (https://developers.google.com/workspace/slides/api/reference/rest/v1/presentations/request), " +
      "for anything the other tools do not do: images, shapes, tables, formatting, moving slides. Returns { replies }.",
    input: z.object({ id: presentationId, requests: z.array(z.record(z.string(), z.unknown())).min(1).max(500) }).strict(),
    idempotent: false,
    async run(api, input) {
      const answer = (await api.request("POST", `${BASE}/${input.id}:batchUpdate`, { body: { requests: input.requests } })) as { replies?: unknown[] };
      return { replies: answer.replies ?? [] };
    },
  }),
  tool({
    name: "get_thumbnail",
    description: "A slide's picture: { url, width, height }, a PNG link that works for 30 minutes.",
    input: z.object({ id: presentationId, slideId: objectId, size: z.enum(["SMALL", "MEDIUM", "LARGE"]).optional().describe("Default MEDIUM.") }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("GET", `${BASE}/${input.id}/pages/${input.slideId}/thumbnail`, {
        query: { "thumbnailProperties.thumbnailSize": input.size ?? "MEDIUM" },
      })) as { contentUrl?: string; width?: number; height?: number };
      return { url: answer.contentUrl ?? null, width: answer.width ?? null, height: answer.height ?? null };
    },
  }),
];

export const slides: AppDefinition = {
  name: "slides",
  title: "Google Slides",
  description: "Read, build and edit your presentations.",
  permissions: [
    "Read every presentation you can open, with speaker notes",
    "Create presentations and add, change and delete slides",
    "Insert text, images, shapes and tables",
  ],
  signIn: "oauth",
  provider: "google",
  providerTitle: "Google",
  category: "files",
  scopes: ["openid", "email", SLIDES_SCOPE],
  requiredScopes: [SLIDES_SCOPE],
  apiOrigin: "https://slides.googleapis.com",
  hosts: ["slides.googleapis.com"],
  reference: "https://developers.google.com/workspace/slides/api/reference/rest",
  tools,
};

function url(id: string): string {
  return `https://docs.google.com/presentation/d/${id}/edit`;
}

/** The text on a page, element by element; `only` keeps one placeholder type, such as the notes' BODY. */
export function textOf(elements: PageElement[], only?: string): string {
  let text = "";
  for (const element of elements) {
    if (element.shape?.text && (!only || element.shape.placeholder?.type === only))
      text += `${(element.shape.text.textElements ?? []).map((t) => t.textRun?.content ?? "").join("")}\n`;
    if (element.table && !only)
      for (const row of element.table.tableRows ?? [])
        text += `${(row.tableCells ?? []).map((cell) => (cell.text?.textElements ?? []).map((t) => t.textRun?.content ?? "").join("").trim()).join("\t")}\n`;
    if (element.elementGroup) text += textOf(element.elementGroup.children ?? [], only);
  }
  return text;
}
