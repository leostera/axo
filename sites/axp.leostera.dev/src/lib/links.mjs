// The documents in axp/ link to each other as files (`SPEC.md#9-logs`, `pi.md`, `../examples/`) so
// they read well on GitHub. On the site each document is a page; this remark plugin rewrites those
// links to the pages, and any other relative link to the file on GitHub.

const REPO = "https://github.com/leostera/axo/blob/main/axp/";
const EXTENSION = /^([a-z][a-z0-9-]*)\.md$/;

/** The site path for a link written in the document at `docPath` (relative to axp/). */
export function sitePath(href, docPath) {
  if (/^[a-z]+:/i.test(href) || href.startsWith("#") || href.startsWith("/")) return href;
  const [path, hash] = href.split("#");
  const base = docPath.includes("/") ? docPath.slice(0, docPath.lastIndexOf("/") + 1) : "";
  const resolved = new URL(path, `https://x/${base}`).pathname.slice(1);
  const anchor = hash ? `#${hash}` : "";
  if (resolved === "SPEC.md" || resolved === "") return `/${anchor}`;
  if (resolved === "extensions/" || resolved === "extensions/README.md") return `/extensions/${anchor}`;
  const extension = resolved.startsWith("extensions/") && resolved.slice("extensions/".length).match(EXTENSION);
  if (extension) return `/extensions/${extension[1]}/${anchor}`;
  if (resolved === "examples/" || resolved.startsWith("examples/")) return `/${resolved}${anchor}`;
  if (resolved.startsWith("schema/")) return `/${resolved}`;
  return `${REPO}${resolved}${anchor}`;
}

export function rewriteLinks() {
  return (tree, file) => {
    const docPath = String(file.path ?? "").replace(/\\/g, "/").split("/axp/").pop() ?? "";
    const visit = (node) => {
      if (node.type === "link" && typeof node.url === "string") node.url = sitePath(node.url, docPath);
      for (const child of node.children ?? []) visit(child);
    };
    visit(tree);
  };
}
