import { z } from "zod";
import { tool, type AppTool, type HttpApp } from "./app";

/**
 * Every app's `request` tool: any endpoint of the app's API, as the account, so a script can do
 * everything the app's permissions allow, not only what its named tools do. The grant only ever
 * goes to the app's own hosts (AppDefinition.hosts), over https.
 */

const MAX_TEXT_CHARS = 500_000;
/** Base64 grows a third; a script result is at most 1 MiB. */
const MAX_BINARY_BYTES = 600_000;
const FORBIDDEN_HEADERS = new Set(["authorization", "cookie", "host", "content-length", "proxy-authorization"]);

const headerValue = z.string().max(1024).regex(/^[^\r\n]*$/, "may not contain line breaks");

export function requestTool(definition: Pick<HttpApp, "title" | "apiOrigin" | "hosts" | "reference">): AppTool {
  const hosts = definition.hosts.join(", ");
  return tool({
    name: "request",
    description:
      `Calls any endpoint of the ${definition.title} API (${definition.reference}) as the account, for anything the other tools do not do. ` +
      `\`path\` is relative to ${definition.apiOrigin} (e.g. "/v1/..."), or a full https URL on ${hosts}. ` +
      "Returns { status, contentType, json } for JSON, { text } for other text, { base64 } for binary, with truncated when cut. " +
      "A 4xx or 5xx answer is an error with the API's message.",
    input: z.object({
      method: z.enum(["GET", "POST", "PUT", "PATCH", "DELETE"]),
      path: z.string().min(1).max(4096),
      query: z.record(z.string().max(128), z.union([z.string().max(8192), z.array(z.string().max(8192)).max(100)])).optional()
        .describe("Query parameters; an array repeats the parameter."),
      body: z.unknown().optional().describe("Sent as JSON."),
      text: z.object({ contentType: z.string().max(256).regex(/^[^\r\n]*$/), data: z.string().max(5_000_000) }).strict().optional()
        .describe("A non-JSON body, sent as is instead of `body`."),
      headers: z.record(z.string(), headerValue).superRefine((headers, ctx) => {
        for (const name of Object.keys(headers)) {
          if (!/^[A-Za-z0-9-]{1,64}$/.test(name)) ctx.addIssue({ code: "custom", message: `${name.slice(0, 64)} is not a header name`, path: [name] });
          else if (FORBIDDEN_HEADERS.has(name.toLowerCase())) ctx.addIssue({ code: "custom", message: `${name} is set by Axo`, path: [name] });
        }
      }).optional(),
    }).strict(),
    idempotent: false,
    async run(api, input) {
      if (input.body !== undefined && input.text) throw new Error("pass `body` or `text`, not both");
      const answer = await api.requestRaw(input.method, input.path, {
        query: input.query,
        body: input.body,
        raw: input.text,
        headers: input.headers,
        accept: "*/*",
      });
      const contentType = answer.contentType;
      const bytes = new Uint8Array(answer.body);
      const base = { status: answer.status, contentType };
      if (!bytes.length) return { ...base, json: null, truncated: false };
      if (/[/+]json\b/i.test(contentType)) {
        const text = new TextDecoder().decode(bytes);
        if (text.length <= MAX_TEXT_CHARS) {
          try {
            return { ...base, json: JSON.parse(text) as unknown, truncated: false };
          } catch {
            // Not JSON after all: returned as text.
          }
        }
        return { ...base, text: text.slice(0, MAX_TEXT_CHARS), truncated: text.length > MAX_TEXT_CHARS };
      }
      if (/^text\/|xml|javascript|csv|x-www-form-urlencoded/i.test(contentType)) {
        const text = new TextDecoder().decode(bytes);
        return { ...base, text: text.slice(0, MAX_TEXT_CHARS), truncated: text.length > MAX_TEXT_CHARS };
      }
      return { ...base, base64: base64(bytes.subarray(0, MAX_BINARY_BYTES)), bytes: bytes.length, truncated: bytes.length > MAX_BINARY_BYTES };
    },
  });
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}
