import { readFileSync } from "node:fs";
import { isAbsolute } from "node:path";

/**
 * A prompt's attachments as Pi takes them (RFD0030). axod has already fetched each one to the
 * Mac and checked its bytes against its hash; this turns them into what the model reads:
 *
 * - PNG, JPEG, GIF and WebP up to 5 MiB become image blocks the model sees;
 * - anything else, or a larger image, becomes a line naming the file, its type, size and path,
 *   and `axo-asset:sha256:<hex>`, so the agent can open it and clients can link it.
 */

export interface PromptAttachment {
  path: string;
  asset: string;
  name: string;
  mimeType: string;
  size: number;
}

export type TextBlock = { type: "text"; text: string };
export type ImageBlock = { type: "image"; data: string; mimeType: string };
/** What `pi.sendUserMessage` takes. */
export type PromptContent = string | (TextBlock | ImageBlock)[];

export const MAX_ATTACHMENTS = 8;
export const MAX_INLINE_IMAGE_BYTES = 5 * 1024 * 1024;
const MAX_ASSET_BYTES = 100 * 1024 * 1024;
const MODEL_IMAGES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);
const ASSET_PATTERN = /^sha256:[0-9a-f]{64}$/u;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Parses the bridge's `attachments`, or null if any is malformed. */
export function parseAttachments(value: unknown): PromptAttachment[] | null {
  if (!Array.isArray(value) || value.length > MAX_ATTACHMENTS) return null;
  const parsed: PromptAttachment[] = [];
  for (const item of value) {
    if (!isRecord(item) || Object.keys(item).some(key => !["path", "asset", "name", "mimeType", "size"].includes(key))) return null;
    const { path, asset, name, mimeType, size } = item;
    if (typeof path !== "string" || !isAbsolute(path)) return null;
    if (typeof asset !== "string" || !ASSET_PATTERN.test(asset)) return null;
    if (typeof name !== "string" || name.length === 0 || name.length > 255 || /[/\\\p{Cc}]/u.test(name)) return null;
    if (typeof mimeType !== "string" || mimeType.length > 100) return null;
    if (typeof size !== "number" || !Number.isSafeInteger(size) || size < 0 || size > MAX_ASSET_BYTES) return null;
    parsed.push({ path, asset, name, mimeType, size });
  }
  return parsed;
}

/** A size as people read it. */
export function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/** The line a file the model can't see inline becomes. */
export function attachmentLine(attachment: PromptAttachment): string {
  return `[Attached file: ${attachment.name} (${attachment.mimeType}, ${formatSize(attachment.size)}) at ${attachment.path} axo-asset:${attachment.asset}]`;
}

const IMAGE_LINE = /^\[Attached image: (.+) at (.+) axo-asset:sha256:[0-9a-f]{64}\]$/u;
const FILE_LINE = /^\[Attached file: (.+) \(([^,()]+), ([^()]+)\) at (.+) axo-asset:sha256:[0-9a-f]{64}\]$/u;

/**
 * How a person's message shows in Pi's terminal: the lines above, written for the agent, become
 * one short line each. The transcript, and what the model reads, keep them whole.
 */
export function showAttachmentLines(markdown: string): string {
  if (!markdown.includes("axo-asset:sha256:")) return markdown;
  return markdown.split("\n").map(line => {
    const image = IMAGE_LINE.exec(line);
    if (image) return `🖼  ${image[1]}`;
    const file = FILE_LINE.exec(line);
    if (file) return `📎 ${file[1]} · ${file[3]}`;
    return line;
  }).join("\n");
}

/**
 * The prompt as Pi takes it: the text alone when there are no attachments, else blocks. A file
 * that can't be read here fails the whole prompt, as a missing download does in axod.
 */
export function promptContent(
  text: string,
  attachments: readonly PromptAttachment[],
  read: (path: string) => Buffer = path => readFileSync(path),
): PromptContent {
  if (attachments.length === 0) return text;
  const blocks: (TextBlock | ImageBlock)[] = [];
  const lines: string[] = [];
  for (const attachment of attachments) {
    if (MODEL_IMAGES.has(attachment.mimeType) && attachment.size <= MAX_INLINE_IMAGE_BYTES) {
      blocks.push({ type: "image", data: read(attachment.path).toString("base64"), mimeType: attachment.mimeType });
      // The model sees the image; the agent still gets where it is, to use it in tools.
      lines.push(`[Attached image: ${attachment.name} at ${attachment.path} axo-asset:${attachment.asset}]`);
    } else {
      lines.push(attachmentLine(attachment));
    }
  }
  const body = [text, ...lines].filter(part => part.length > 0).join("\n\n");
  return [{ type: "text", text: body }, ...blocks];
}
