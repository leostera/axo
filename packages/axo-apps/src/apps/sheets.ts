import { z } from "zod";
import { tool, type AppDefinition, type AppTool } from "../app";

/**
 * Google Sheets as an app: `codemode.apps.sheets.<tool>({ account, ... })` over the Sheets API,
 * with full access (`spreadsheets`): read and write cells, append rows, create spreadsheets.
 * Finding a spreadsheet is Drive's search (apps.drive.search_files).
 */

export const SHEETS_SCOPE = "https://www.googleapis.com/auth/spreadsheets";
const BASE = "/v4/spreadsheets";

const spreadsheetId = z.string().regex(/^[A-Za-z0-9_-]{1,256}$/, "expected a spreadsheet ID");
const range = z.string().min(1).max(512).describe("A range in A1 notation, such as \"Sheet1!A1:C10\" or \"Sheet1\" for a whole sheet.");
const cell = z.union([z.string(), z.number(), z.boolean(), z.null()]);
const values = z.array(z.array(cell).max(1000)).max(10_000).describe("Rows of cells.");
const raw = z.boolean().optional().describe("Store values exactly as given; by default they are parsed as if typed, so \"=SUM(A1:A3)\" is a formula and \"3\" a number.");

const tools: AppTool[] = [
  tool({
    name: "get_spreadsheet",
    description: "Reads a spreadsheet's title and sheets: { id, title, url, sheets: [{ sheetId, title, rows, columns }] }.",
    input: z.object({ id: spreadsheetId }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("GET", `${BASE}/${input.id}`, { query: { fields: "spreadsheetId,properties.title,spreadsheetUrl,sheets.properties" } })) as {
        spreadsheetId: string;
        spreadsheetUrl?: string;
        properties?: { title?: string };
        sheets?: Array<{ properties?: { sheetId?: number; title?: string; gridProperties?: { rowCount?: number; columnCount?: number } } }>;
      };
      return {
        id: answer.spreadsheetId,
        title: answer.properties?.title ?? null,
        url: answer.spreadsheetUrl ?? null,
        sheets: (answer.sheets ?? []).map(({ properties: p }) => ({ sheetId: p?.sheetId ?? null, title: p?.title ?? null, rows: p?.gridProperties?.rowCount ?? null, columns: p?.gridProperties?.columnCount ?? null })),
      };
    },
  }),
  tool({
    name: "read_range",
    description: "Reads cells: { range, values: [[...], ...] }, as they are shown (formatted), rows first.",
    input: z.object({ id: spreadsheetId, range, formulas: z.boolean().optional().describe("Return formulas instead of their values.") }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("GET", `${BASE}/${input.id}/values/${encodeURIComponent(input.range)}`, {
        query: { valueRenderOption: input.formulas ? "FORMULA" : "FORMATTED_VALUE" },
      })) as { range?: string; values?: unknown[][] };
      return { range: answer.range ?? input.range, values: answer.values ?? [] };
    },
  }),
  tool({
    name: "write_range",
    description: "Writes cells starting at the range's top-left cell and returns { updatedRange, updatedCells }.",
    input: z.object({ id: spreadsheetId, range, values, raw }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("PUT", `${BASE}/${input.id}/values/${encodeURIComponent(input.range)}`, {
        query: { valueInputOption: input.raw ? "RAW" : "USER_ENTERED" },
        body: { range: input.range, majorDimension: "ROWS", values: input.values },
      })) as { updatedRange?: string; updatedCells?: number };
      return { updatedRange: answer.updatedRange ?? null, updatedCells: answer.updatedCells ?? 0 };
    },
  }),
  tool({
    name: "append_rows",
    description: "Adds rows after the last row of the table in the range and returns { updatedRange, updatedRows }.",
    input: z.object({ id: spreadsheetId, range, values, raw }).strict(),
    idempotent: false,
    async run(api, input) {
      const answer = (await api.request("POST", `${BASE}/${input.id}/values/${encodeURIComponent(input.range)}:append`, {
        query: { valueInputOption: input.raw ? "RAW" : "USER_ENTERED", insertDataOption: "INSERT_ROWS" },
        body: { range: input.range, majorDimension: "ROWS", values: input.values },
      })) as { updates?: { updatedRange?: string; updatedRows?: number } };
      return { updatedRange: answer.updates?.updatedRange ?? null, updatedRows: answer.updates?.updatedRows ?? 0 };
    },
  }),
  tool({
    name: "clear_range",
    description: "Empties cells (keeping their formatting) and returns { clearedRange }.",
    input: z.object({ id: spreadsheetId, range }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("POST", `${BASE}/${input.id}/values/${encodeURIComponent(input.range)}:clear`, { body: {} })) as { clearedRange?: string };
      return { clearedRange: answer.clearedRange ?? input.range };
    },
  }),
  tool({
    name: "create_spreadsheet",
    description: "Creates a spreadsheet and returns { id, title, url, sheets }. `sheets` names its sheets; default one named Sheet1.",
    input: z.object({ title: z.string().min(1).max(1024), sheets: z.array(z.string().min(1).max(100)).min(1).max(50).optional() }).strict(),
    idempotent: false,
    async run(api, input) {
      const answer = (await api.request("POST", BASE, {
        body: { properties: { title: input.title }, ...(input.sheets ? { sheets: input.sheets.map((title) => ({ properties: { title } })) } : {}) },
      })) as { spreadsheetId: string; spreadsheetUrl?: string; properties?: { title?: string }; sheets?: Array<{ properties?: { title?: string } }> };
      return {
        id: answer.spreadsheetId,
        title: answer.properties?.title ?? input.title,
        url: answer.spreadsheetUrl ?? null,
        sheets: (answer.sheets ?? []).map((s) => s.properties?.title ?? null),
      };
    },
  }),
];

export const sheets: AppDefinition = {
  name: "sheets",
  title: "Google Sheets",
  description: "Read and edit your spreadsheets.",
  permissions: [
    "Read every spreadsheet you can open",
    "Write cells, add rows and clear ranges",
    "Create spreadsheets, add sheets, format and chart them",
  ],
  signIn: "oauth",
  provider: "google",
  providerTitle: "Google",
  category: "files",
  scopes: ["openid", "email", SHEETS_SCOPE],
  requiredScopes: [SHEETS_SCOPE],
  apiOrigin: "https://sheets.googleapis.com",
  hosts: ["sheets.googleapis.com"],
  reference: "https://developers.google.com/workspace/sheets/api/reference/rest",
  tools,
};
