import { z } from "zod";
import { tool, type AppDefinition, type AppTool, type ProviderApi } from "./app";

/**
 * Google Drive as an app: `codemode.apps.drive.<tool>({ account, ... })` over the Drive API, with
 * full access (`drive`): search, read, upload, organize, share and delete files, in My Drive and
 * shared drives. Google Docs, Sheets and Slides read as text; other files download as base64.
 */

export const DRIVE_SCOPE = "https://www.googleapis.com/auth/drive";
const BASE = "/drive/v3";
const UPLOAD = "https://www.googleapis.com/upload/drive/v3/files";
const FIELDS = "id,name,mimeType,modifiedTime,size,parents,webViewLink,trashed,owners(emailAddress)";
const DEFAULT_CHARS = 100_000;
/** A download is returned as base64 inside a script result of at most 1 MiB. */
const MAX_DOWNLOAD_BYTES = 700_000;

const id = z.string().regex(/^[A-Za-z0-9_-]{1,256}$/, "expected a Drive file ID");
const EXPORTS: Record<string, string> = {
  "application/vnd.google-apps.document": "text/plain",
  "application/vnd.google-apps.spreadsheet": "text/csv",
  "application/vnd.google-apps.presentation": "text/plain",
  "application/vnd.google-apps.drawing": "image/svg+xml",
};
const CONVERT: Record<string, string> = {
  document: "application/vnd.google-apps.document",
  spreadsheet: "application/vnd.google-apps.spreadsheet",
  presentation: "application/vnd.google-apps.presentation",
};

type File = {
  id: string;
  name?: string;
  mimeType?: string;
  modifiedTime?: string;
  size?: string;
  parents?: string[];
  webViewLink?: string;
  trashed?: boolean;
  owners?: Array<{ emailAddress?: string }>;
};

const tools: AppTool[] = [
  tool({
    name: "search_files",
    description:
      "Finds files: { files: [{ id, name, mimeType, modifiedTime, size, parents, webViewLink, owners }], nextPageToken }, newest first. " +
      "`text` matches names and contents; `query` takes Drive's search syntax (e.g. \"name contains 'plan' and mimeType = 'application/pdf'\") for anything else.",
    input: z.object({
      text: z.string().max(1024).optional(),
      query: z.string().max(2048).optional(),
      folderId: id.optional().describe("Only files directly in this folder."),
      mimeType: z.string().max(256).optional(),
      includeTrashed: z.boolean().optional(),
      maxResults: z.number().int().min(1).max(100).optional().describe("Default 25."),
      pageToken: z.string().max(1024).optional(),
    }).strict(),
    idempotent: true,
    async run(api, input) {
      const terms = [
        input.text ? `fullText contains ${quote(input.text)}` : null,
        input.folderId ? `${quote(input.folderId)} in parents` : null,
        input.mimeType ? `mimeType = ${quote(input.mimeType)}` : null,
        input.includeTrashed ? null : "trashed = false",
        input.query ? `(${input.query})` : null,
      ].filter(Boolean);
      const answer = (await api.request("GET", `${BASE}/files`, {
        query: {
          q: terms.join(" and ") || undefined,
          // Drive cannot order a fullText search.
          orderBy: input.text ? undefined : "modifiedTime desc",
          pageSize: String(input.maxResults ?? 25),
          pageToken: input.pageToken,
          fields: `nextPageToken,files(${FIELDS})`,
          supportsAllDrives: "true",
          includeItemsFromAllDrives: "true",
        },
      })) as { files?: File[]; nextPageToken?: string };
      return { files: (answer.files ?? []).map(file), nextPageToken: answer.nextPageToken ?? null };
    },
  }),
  tool({
    name: "get_file",
    description: "Reads a file's metadata: { id, name, mimeType, modifiedTime, size, parents, webViewLink, owners, trashed }.",
    input: z.object({ id }).strict(),
    idempotent: true,
    run: async (api, input) => file(await metadata(api, input.id)),
  }),
  tool({
    name: "read_file",
    description:
      "Reads a file as text: { id, name, mimeType, text, truncated }. Google Docs and Slides read as plain text and Sheets as CSV (the first sheet); " +
      "text files as they are. For other files use download_file.",
    input: z.object({ id, maxChars: z.number().int().min(1).max(500_000).optional().describe(`Default ${DEFAULT_CHARS}.`) }).strict(),
    idempotent: true,
    async run(api, input) {
      const meta = await metadata(api, input.id);
      const exportAs = EXPORTS[meta.mimeType ?? ""];
      if (!exportAs && !isText(meta.mimeType ?? "")) throw new Error(`${meta.name} is ${meta.mimeType}, not text; use download_file`);
      const bytes = exportAs
        ? await api.requestBytes("GET", `${BASE}/files/${input.id}/export`, { query: { mimeType: exportAs }, accept: "*/*" })
        : await api.requestBytes("GET", `${BASE}/files/${input.id}`, { query: { alt: "media", supportsAllDrives: "true" }, accept: "*/*" });
      const text = new TextDecoder().decode(bytes);
      const max = input.maxChars ?? DEFAULT_CHARS;
      return { id: meta.id, name: meta.name ?? null, mimeType: meta.mimeType ?? null, text: text.slice(0, max), truncated: text.length > max };
    },
  }),
  tool({
    name: "download_file",
    description: `Downloads a file's bytes: { id, name, mimeType, size, dataBase64 }, for files up to ${MAX_DOWNLOAD_BYTES} bytes. Google Docs export as PDF.`,
    input: z.object({ id }).strict(),
    idempotent: true,
    async run(api, input) {
      const meta = await metadata(api, input.id);
      const native = meta.mimeType?.startsWith("application/vnd.google-apps.");
      if (!native && Number(meta.size ?? 0) > MAX_DOWNLOAD_BYTES) throw new Error(`${meta.name} is ${meta.size} bytes; download_file takes at most ${MAX_DOWNLOAD_BYTES}`);
      const bytes = native
        ? await api.requestBytes("GET", `${BASE}/files/${input.id}/export`, { query: { mimeType: "application/pdf" }, accept: "*/*" })
        : await api.requestBytes("GET", `${BASE}/files/${input.id}`, { query: { alt: "media", supportsAllDrives: "true" }, accept: "*/*" });
      if (bytes.byteLength > MAX_DOWNLOAD_BYTES) throw new Error(`${meta.name} is ${bytes.byteLength} bytes; download_file takes at most ${MAX_DOWNLOAD_BYTES}`);
      return { id: meta.id, name: meta.name ?? null, mimeType: native ? "application/pdf" : meta.mimeType ?? null, size: bytes.byteLength, dataBase64: base64(new Uint8Array(bytes)) };
    },
  }),
  tool({
    name: "upload_file",
    description:
      "Creates a file from `text` or `dataBase64` and returns it. Give convertTo (\"document\", \"spreadsheet\" or \"presentation\") to make it a Google Doc, Sheet or Slides, e.g. CSV text to a Sheet.",
    input: z.object({
      name: z.string().min(1).max(1024),
      text: z.string().max(5_000_000).optional(),
      dataBase64: z.string().max(7_000_000).optional(),
      mimeType: z.string().max(256).optional().describe("Of the content; default text/plain for text, application/octet-stream otherwise."),
      folderId: id.optional(),
      convertTo: z.enum(["document", "spreadsheet", "presentation"]).optional(),
    }).strict(),
    idempotent: false,
    async run(api, input) {
      if ((input.text === undefined) === (input.dataBase64 === undefined)) throw new Error("give exactly one of text and dataBase64");
      const content = input.text !== undefined ? new TextEncoder().encode(input.text) : fromBase64(input.dataBase64!);
      const contentType = input.mimeType ?? (input.text !== undefined ? "text/plain" : "application/octet-stream");
      const meta = { name: input.name, ...(input.folderId ? { parents: [input.folderId] } : {}), ...(input.convertTo ? { mimeType: CONVERT[input.convertTo] } : {}) };
      const boundary = `axo-${crypto.randomUUID()}`;
      const head = new TextEncoder().encode(`--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${JSON.stringify(meta)}\r\n--${boundary}\r\nContent-Type: ${contentType}\r\n\r\n`);
      const tail = new TextEncoder().encode(`\r\n--${boundary}--`);
      const body = new Uint8Array(head.length + content.length + tail.length);
      body.set(head, 0);
      body.set(content, head.length);
      body.set(tail, head.length + content.length);
      return file((await api.request("POST", UPLOAD, {
        query: { uploadType: "multipart", fields: FIELDS, supportsAllDrives: "true" },
        raw: { contentType: `multipart/related; boundary=${boundary}`, data: body },
      })) as File);
    },
  }),
  tool({
    name: "create_folder",
    description: "Creates a folder and returns it.",
    input: z.object({ name: z.string().min(1).max(1024), parentId: id.optional() }).strict(),
    idempotent: false,
    async run(api, input) {
      return file((await api.request("POST", `${BASE}/files`, {
        query: { fields: FIELDS, supportsAllDrives: "true" },
        body: { name: input.name, mimeType: "application/vnd.google-apps.folder", ...(input.parentId ? { parents: [input.parentId] } : {}) },
      })) as File);
    },
  }),
  tool({
    name: "update_file",
    description: "Renames a file and/or moves it to another folder, and returns it.",
    input: z.object({ id, name: z.string().min(1).max(1024).optional(), folderId: id.optional().describe("Moves the file here, out of its current folders.") }).strict(),
    idempotent: true,
    async run(api, input) {
      const previous = input.folderId ? (await metadata(api, input.id)).parents ?? [] : [];
      return file((await api.request("PATCH", `${BASE}/files/${input.id}`, {
        query: {
          fields: FIELDS,
          supportsAllDrives: "true",
          addParents: input.folderId,
          removeParents: input.folderId ? previous.filter((p) => p !== input.folderId).join(",") || undefined : undefined,
        },
        body: input.name ? { name: input.name } : {},
      })) as File);
    },
  }),
  tool({
    name: "share_file",
    description: "Shares a file with a person and returns { permissionId, role }. They are emailed unless notify is false.",
    input: z.object({
      id,
      email: z.string().email(),
      role: z.enum(["reader", "commenter", "writer"]),
      notify: z.boolean().optional(),
      message: z.string().max(4096).optional(),
    }).strict(),
    idempotent: false,
    async run(api, input) {
      const answer = (await api.request("POST", `${BASE}/files/${input.id}/permissions`, {
        query: { sendNotificationEmail: String(input.notify ?? true), emailMessage: input.message, supportsAllDrives: "true" },
        body: { type: "user", role: input.role, emailAddress: input.email },
      })) as { id: string; role: string };
      return { permissionId: answer.id, role: answer.role };
    },
  }),
  tool({
    name: "trash_file",
    description: "Moves a file to the trash (it can be restored for 30 days) and returns it.",
    input: z.object({ id }).strict(),
    idempotent: true,
    async run(api, input) {
      return file((await api.request("PATCH", `${BASE}/files/${input.id}`, { query: { fields: FIELDS, supportsAllDrives: "true" }, body: { trashed: true } })) as File);
    },
  }),
  tool({
    name: "delete_file",
    description: "Deletes a file for good, skipping the trash. Prefer trash_file unless asked to delete permanently. Returns { deleted: true }.",
    input: z.object({ id }).strict(),
    idempotent: true,
    async run(api, input) {
      await api.request("DELETE", `${BASE}/files/${input.id}`, { query: { supportsAllDrives: "true" } });
      return { deleted: true };
    },
  }),
];

export const drive: AppDefinition = {
  name: "drive",
  title: "Google Drive",
  description: "Find, read, upload, organize and share your files.",
  permissions: [
    "See and download every file in My Drive and shared drives",
    "Upload, create, rename and move files and folders",
    "Share files and change who can see them",
    "Trash and permanently delete files",
    "Read and write comments and versions",
  ],
  provider: "google",
  scopes: ["openid", "email", DRIVE_SCOPE],
  requiredScopes: [DRIVE_SCOPE],
  apiOrigin: "https://www.googleapis.com",
  hosts: ["www.googleapis.com"],
  reference: "https://developers.google.com/workspace/drive/api/reference/rest/v3",
  tools,
};

async function metadata(api: ProviderApi, fileId: string): Promise<File> {
  return (await api.request("GET", `${BASE}/files/${fileId}`, { query: { fields: FIELDS, supportsAllDrives: "true" } })) as File;
}

function file(f: File) {
  return {
    id: f.id,
    name: f.name ?? null,
    mimeType: f.mimeType ?? null,
    modifiedTime: f.modifiedTime ?? null,
    size: f.size === undefined ? null : Number(f.size),
    parents: f.parents ?? [],
    webViewLink: f.webViewLink ?? null,
    owners: (f.owners ?? []).map((o) => o.emailAddress).filter(Boolean),
    trashed: f.trashed ?? false,
  };
}

/** A value in Drive's query syntax: single-quoted, with \ and ' escaped. */
function quote(value: string): string {
  return `'${value.replace(/\\/g, "\\\\").replace(/'/g, "\\'")}'`;
}

function isText(mimeType: string): boolean {
  return mimeType.startsWith("text/") || /^application\/(json|xml|javascript|x-yaml|yaml|csv|x-sh|toml)/.test(mimeType) || mimeType.endsWith("+json") || mimeType.endsWith("+xml");
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

function fromBase64(data: string): Uint8Array<ArrayBuffer> {
  const binary = atob(data.replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}
