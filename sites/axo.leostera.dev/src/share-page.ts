/**
 * A shared conversation's page and its download, served by the Worker from the snapshot in R2.
 *
 * `/s/<shareId>/<slug>` is the web app's page with the snapshot inlined, so it draws in one
 * request with nothing to wait for, and with a title and description for link previews.
 * `/s/<shareId>/<slug>.jsonl` is the same conversation as an ATXF transcript.
 */
import { ATXF_EXTENSION, ATXF_MEDIA_TYPE, shareSlug, shareToAtxf, sharedSnapshotSchema, type SharedSnapshot } from "@axo/protocol";

export type ShareRoute =
  | { kind: "page"; shareId: string }
  | { kind: "transcript"; shareId: string };

/** `/s/<id>`, `/s/<id>/<slug>`, and either with `.jsonl` for the transcript. */
export function shareRoute(pathname: string): ShareRoute | null {
  const match = /^\/s\/([A-Za-z0-9_-]{22})(?:\.jsonl|\/([^/]*))?\/?$/.exec(pathname);
  if (!match) return null;
  const shareId = match[1]!;
  return pathname.endsWith(".jsonl") ? { kind: "transcript", shareId } : { kind: "page", shareId };
}

/** Reads a stored snapshot; a share the current schema can't read is treated as missing. */
export function readSnapshot(text: string): SharedSnapshot | null {
  try {
    const parsed = sharedSnapshotSchema.safeParse(JSON.parse(text));
    return parsed.success ? parsed.data : null;
  } catch {
    return null;
  }
}

const REDACTED = /\[redacted:[^\]]*\]/g;
/** The title tool's calls are bookkeeping: the page draws them as its header, not as steps. */
const TITLE_TOOL = "axo_set_title";

/**
 * The Session's emoji. Shares from before it was published still have it, in what the title tool
 * said ("Session named 🐫 riot: …"); the page reads it the same way (shared-session.tsx).
 */
export function shareEmoji(snapshot: SharedSnapshot): string | null {
  if (snapshot.emoji) return snapshot.emoji;
  for (const message of [...snapshot.messages].reverse()) {
    if (message.tool?.name !== TITLE_TOOL) continue;
    const emoji = /^Session (?:named|renamed to) (\S+) /u.exec(message.tool.output)?.[1];
    if (emoji && /\p{Extended_Pictographic}/u.test(emoji)) return emoji;
  }
  return null;
}
const DESCRIPTION_CHARS = 200;

/** What a link preview says: the request that started the conversation, and what it took. */
export function shareDescription(snapshot: SharedSnapshot): string {
  const prompt = snapshot.messages.find(message => message.role === "user")?.text ?? "";
  const clean = prompt.replace(REDACTED, "…").replace(/\s+/g, " ").trim();
  const cut = clean.length > DESCRIPTION_CHARS ? `${clean.slice(0, DESCRIPTION_CHARS - 1).trimEnd()}…` : clean;
  const tools = snapshot.messages.filter(message => message.tool && message.tool.name !== TITLE_TOOL).length;
  const facts = [
    snapshot.model?.name,
    tools ? `${tools} tool ${tools === 1 ? "call" : "calls"}` : null,
    "shared from Axo",
  ].filter(Boolean).join(" · ");
  return cut ? `${cut} — ${facts}` : facts;
}

export function shareTitle(snapshot: SharedSnapshot): string {
  const emoji = shareEmoji(snapshot);
  return emoji ? `${emoji} ${snapshot.title}` : snapshot.title;
}

const escapeHtml = (text: string) =>
  text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

/** JSON that can sit inside a `<script>`: nothing in it can close the element or start a comment. */
export const scriptJson = (value: unknown) =>
  JSON.stringify(value).replace(/</g, "\\u003c").replace(/>/g, "\\u003e").replace(/&/g, "\\u0026")
    .replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029");

/** The element the page reads the snapshot from (packages/axo-web-app/src/chat/shared-session.tsx). */
export const SNAPSHOT_ELEMENT_ID = "axo-share-snapshot";

/**
 * The app's `index.html` made into this share's page: its own title, description and preview
 * tags, a link to the transcript, and the snapshot itself.
 */
export function sharePageHtml(indexHtml: string, origin: string, shareId: string, snapshot: SharedSnapshot): string {
  const title = `${shareTitle(snapshot)} · Axo`;
  const description = shareDescription(snapshot);
  const slug = shareSlug(snapshot.title);
  const url = `${origin}/s/${shareId}/${slug}`;
  const head = [
    `<link rel="canonical" href="${escapeHtml(url)}" />`,
    `<link rel="alternate" type="application/jsonl" title="ATXF transcript" href="${escapeHtml(`${url}.jsonl`)}" />`,
    // Shares are unlisted: anyone with the link can read one, but search engines shouldn't list it.
    `<meta name="robots" content="noindex" />`,
    `<meta property="og:type" content="article" />`,
    `<meta property="og:site_name" content="Axo" />`,
    `<meta property="og:title" content="${escapeHtml(shareTitle(snapshot))}" />`,
    `<meta property="og:description" content="${escapeHtml(description)}" />`,
    `<meta property="og:url" content="${escapeHtml(url)}" />`,
    `<meta property="og:image" content="${escapeHtml(`${origin}/favicon-192.png`)}" />`,
    `<meta property="article:published_time" content="${escapeHtml(snapshot.publishedAt)}" />`,
    `<meta name="twitter:card" content="summary" />`,
    `<script id="${SNAPSHOT_ELEMENT_ID}" type="application/json">${scriptJson({ shareId, snapshot })}</script>`,
  ].join("\n    ");
  return indexHtml
    .replace(/<title>[^<]*<\/title>/, `<title>${escapeHtml(title)}</title>`)
    .replace(/<meta name="description" content="[^"]*"\s*\/?>/, `<meta name="description" content="${escapeHtml(description)}" />`)
    .replace("</head>", `  ${head}\n  </head>`);
}

/** The download's headers: an ATXF file named after the share. */
export function transcriptResponse(shareId: string, snapshot: SharedSnapshot, method: string): Response {
  const body = shareToAtxf(shareId, snapshot);
  return new Response(method === "HEAD" ? null : body, {
    headers: {
      "Content-Type": ATXF_MEDIA_TYPE,
      "Content-Disposition": `attachment; filename="${shareSlug(snapshot.title)}${ATXF_EXTENSION}"`,
      "Cache-Control": "public, max-age=60, s-maxage=300",
      "X-Content-Type-Options": "nosniff",
      "Access-Control-Allow-Origin": "*",
    },
  });
}
