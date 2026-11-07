/**
 * Where an MCP server's icon is, for its tile in Settings › Apps: the icon the server names in
 * its `initialize` answer, or else the one its site's home page declares (an Apple touch icon,
 * which is large, before a plain icon), or else the site's `/favicon.ico` if it is an image.
 * The site is the server's host without an `mcp.` or `api.` in front. Only https URLs are kept;
 * the browser loads the icon itself, and shows a plug when there is none.
 */

const TIMEOUT_MS = 5_000;
const MAX_PAGE_BYTES = 512 * 1024;
const MAX_URL = 2048;

export async function findSiteIcon(serverUrl: string, named: readonly string[], fetcher: typeof fetch): Promise<string | null> {
  for (const src of named) {
    const url = httpsUrl(src, serverUrl);
    if (url) return url;
  }
  let site: URL;
  try {
    site = new URL(serverUrl);
  } catch {
    return null;
  }
  if (site.protocol !== "https:") return null;
  const home = `https://${site.hostname.replace(/^(mcp|api)\./, "")}/`;
  const page = await text(home, fetcher);
  if (page) {
    const declared = iconsIn(page.body, page.url);
    if (declared) return declared;
  }
  const favicon = new URL("/favicon.ico", page?.url ?? home).toString();
  return (await isImage(favicon, fetcher)) ? favicon : null;
}

/** The best icon a page declares: an Apple touch icon, then an SVG or PNG icon, then any icon. */
export function iconsIn(html: string, base: string): string | null {
  const links = [...html.matchAll(/<link\b[^>]*>/gi)].map((m) => m[0]);
  const attr = (tag: string, name: string) => new RegExp(`\\b${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, "i").exec(tag)?.slice(1).find((v) => v !== undefined) ?? null;
  const icons = links.flatMap((tag) => {
    const rel = (attr(tag, "rel") ?? "").toLowerCase().split(/\s+/);
    const href = attr(tag, "href");
    if (!href) return [];
    const url = httpsUrl(decodeEntities(href), base);
    if (!url) return [];
    const type = (attr(tag, "type") ?? "").toLowerCase();
    const rank = rel.includes("apple-touch-icon") || rel.includes("apple-touch-icon-precomposed") ? 0
      : rel.includes("icon") && (type.includes("svg") || /\.svg(\?|$)/i.test(url)) ? 1
      : rel.includes("icon") && (type.includes("png") || /\.png(\?|$)/i.test(url)) ? 2
      : rel.includes("icon") ? 3
      : -1;
    return rank < 0 ? [] : [{ url, rank }];
  });
  icons.sort((a, b) => a.rank - b.rank);
  return icons[0]?.url ?? null;
}

function httpsUrl(src: string, base: string): string | null {
  try {
    const url = new URL(src, base);
    return url.protocol === "https:" && url.toString().length <= MAX_URL ? url.toString() : null;
  } catch {
    return null;
  }
}

function decodeEntities(value: string): string {
  return value.replace(/&amp;/g, "&").replace(/&#x2F;/gi, "/").replace(/&#47;/g, "/");
}

async function text(url: string, fetcher: typeof fetch): Promise<{ body: string; url: string } | null> {
  try {
    const response = await fetcher(url, { headers: { Accept: "text/html" }, redirect: "follow", signal: AbortSignal.timeout(TIMEOUT_MS) });
    if (!response.ok || !(response.headers.get("Content-Type") ?? "").includes("html") || !response.body) {
      await response.body?.cancel();
      return null;
    }
    // Icons are declared in the head: the first half megabyte is plenty.
    const reader = response.body.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    while (size < MAX_PAGE_BYTES) {
      const { value, done } = await reader.read();
      if (done) break;
      chunks.push(value);
      size += value.byteLength;
    }
    await reader.cancel().catch(() => undefined);
    const bytes = new Uint8Array(size);
    let at = 0;
    for (const chunk of chunks) {
      bytes.set(chunk.subarray(0, Math.max(0, size - at)), at);
      at += chunk.byteLength;
    }
    return { body: new TextDecoder().decode(bytes), url: response.url || url };
  } catch {
    return null;
  }
}

async function isImage(url: string, fetcher: typeof fetch): Promise<boolean> {
  try {
    const response = await fetcher(url, { redirect: "follow", signal: AbortSignal.timeout(TIMEOUT_MS) });
    await response.body?.cancel();
    return response.ok && (response.headers.get("Content-Type") ?? "").startsWith("image/");
  } catch {
    return false;
  }
}
