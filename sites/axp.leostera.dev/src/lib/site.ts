import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

// Astro runs from the site directory; bundling makes import.meta.url unreliable for this.
export const AXP_ROOT = `${resolve(process.cwd(), "../../axp")}/`;
export const SITE_URL = "https://axp.leostera.dev";
export const SCHEMA_PATH = "/schema/v0.1/axp.schema.json";
export const REPO_URL = "https://github.com/leostera/axo";
export const SOURCE_URL = `${REPO_URL}/blob/main/axp/`;
export const TREE_URL = `${REPO_URL}/tree/main/axp/`;
export const VERSION = "0.1";

const read = (path: string) => readFileSync(AXP_ROOT + path, "utf8");

/** Date of the last commit that touched `path` (relative to axp/), or today when outside git. */
export function lastUpdated(path: string): string {
  try {
    const date = execFileSync("git", ["log", "-1", "--format=%cs", "--", path], { cwd: AXP_ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    if (date) return date;
  } catch {
    // Not a git checkout (a Bazel sandbox, a tarball); fall through.
  }
  return new Date().toISOString().slice(0, 10);
}

// ─── Extensions ─────────────────────────────────────────────────────────────

export interface Extension {
  id: string;
  version: string;
  status: string;
  requires: string;
  roles: string;
  /** The first paragraph after the front matter. */
  summary: string;
  schemaPath: string;
}

function frontMatter(text: string, field: string): string {
  const match = text.match(new RegExp(`^${field}:\\s+(.+)$`, "m"));
  if (!match) throw new Error(`missing ${field}`);
  return match[1].trim();
}

/** Every extension in the registry, in registry order. */
export function extensions(): Extension[] {
  const registry = read("extensions/README.md");
  const ids = [...registry.matchAll(/^\| `([a-z][a-z0-9-]*)` \|/gm)].map((match) => match[1]);
  return ids.map((id) => {
    const text = read(`extensions/${id}.md`);
    const afterFence = text.split("```").slice(2).join("```");
    const summary = afterFence
      .trim()
      .split(/\n\s*\n/)[0]
      .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
      .replace(/`([^`]+)`/g, "$1")
      .replace(/\s+/g, " ");
    const version = frontMatter(text, "Version");
    return {
      id,
      version,
      status: frontMatter(text, "Status"),
      requires: frontMatter(text, "Requires"),
      roles: frontMatter(text, "Roles"),
      summary,
      schemaPath: `/schema/v0.1/ext/${id}/${version}/${id}.schema.json`,
    };
  });
}

// ─── Schemas ────────────────────────────────────────────────────────────────

export interface SchemaFile {
  /** Path on the site, which is also the end of its `$id`. */
  path: string;
  text: string;
}

export function schemas(): SchemaFile[] {
  const files: SchemaFile[] = [{ path: SCHEMA_PATH, text: read("schema/v0.1/axp.schema.json") }];
  for (const id of readdirSync(`${AXP_ROOT}schema/v0.1/ext`)) {
    for (const version of readdirSync(`${AXP_ROOT}schema/v0.1/ext/${id}`)) {
      files.push({ path: `/schema/v0.1/ext/${id}/${version}/${id}.schema.json`, text: read(`schema/v0.1/ext/${id}/${version}/${id}.schema.json`) });
    }
  }
  return files;
}

// ─── Examples ───────────────────────────────────────────────────────────────

export interface ExchangeLine {
  from: string;
  to: string;
  note?: string;
  message: Record<string, unknown>;
}
export interface Example {
  slug: string;
  file: string;
  text: string;
  lines: ExchangeLine[];
}

// From the first connection to the corner cases.
const EXAMPLE_ORDER = ["pairing", "replication", "reading", "command", "attachments", "terminal", "divergence", "fragments", "session"];
const slugOf = (file: string) => file.replace(/\.(axp|atxf)\.jsonl$/, "");
const order = (file: string) => {
  const index = EXAMPLE_ORDER.indexOf(slugOf(file));
  return index === -1 ? EXAMPLE_ORDER.length : index;
};

export function examples(): Example[] {
  return readdirSync(`${AXP_ROOT}examples/`)
    .filter((file) => file.endsWith(".jsonl"))
    .sort((a, b) => order(a) - order(b) || a.localeCompare(b))
    .map((file) => {
      const text = read(`examples/${file}`);
      const lines = file.endsWith(".axp.jsonl")
        ? text.split("\n").filter((line) => line.trim() !== "").map((line) => JSON.parse(line) as ExchangeLine)
        : [];
      return { slug: slugOf(file), file, text, lines };
    });
}
