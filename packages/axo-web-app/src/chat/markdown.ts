/**
 * The parts of a reply drawn differently: prose, headings, lists, quotes, tables, rules and code.
 * A port of the phone's `MarkdownBlocks`. Not a Markdown engine: it splits a reply where the look
 * changes and leaves inline formatting to `inlineSpans`. An unclosed fence runs to the end, so a
 * reply that is still arriving never loses its code.
 */
export type ListMarker = { kind: "bullet" } | { kind: "number"; value: number };

export type MarkdownBlock =
  | { kind: "paragraph"; text: string }
  | { kind: "heading"; level: 1 | 2 | 3; text: string }
  | { kind: "listItem"; marker: ListMarker; depth: number; text: string }
  | { kind: "quote"; text: string }
  | { kind: "table"; header: string[]; rows: string[][] }
  | { kind: "rule" }
  | { kind: "code"; language: string | null; text: string };

export function parseMarkdown(text: string): MarkdownBlock[] {
  const lines = text.split("\n");
  const blocks: MarkdownBlock[] = [];
  let paragraph: string[] = [];
  let quote: string[] = [];

  const flushParagraph = () => {
    const joined = paragraph.join("\n").trim();
    if (joined) blocks.push({ kind: "paragraph", text: joined });
    paragraph = [];
  };
  const flushQuote = () => {
    const joined = quote.join("\n").trim();
    if (joined) blocks.push({ kind: "quote", text: joined });
    quote = [];
  };
  const flush = () => {
    flushParagraph();
    flushQuote();
  };

  let index = 0;
  while (index < lines.length) {
    const line = lines[index]!;
    const trimmed = line.trim();
    index += 1;

    if (trimmed.startsWith("```")) {
      flush();
      const language = trimmed.slice(3).trim();
      const code: string[] = [];
      while (index < lines.length && !lines[index]!.trim().startsWith("```")) {
        code.push(lines[index]!);
        index += 1;
      }
      index += 1; // the closing fence, if there is one
      blocks.push({ kind: "code", language: language || null, text: code.join("\n") });
    } else if (trimmed.startsWith(">")) {
      flushParagraph();
      const rest = trimmed.slice(1);
      quote.push(rest.startsWith(" ") ? rest.slice(1) : rest);
    } else if (!trimmed) {
      flush();
    } else if (isRule(trimmed)) {
      flush();
      blocks.push({ kind: "rule" });
    } else if (heading(trimmed)) {
      flush();
      blocks.push(heading(trimmed)!);
    } else if (listItem(line)) {
      flush();
      blocks.push(listItem(line)!);
    } else if (cells(trimmed) && index < lines.length && isTableSeparator(lines[index]!.trim(), cells(trimmed)!.length)) {
      flush();
      const header = cells(trimmed)!;
      index += 1;
      const rows: string[][] = [];
      while (index < lines.length) {
        const row = cells(lines[index]!.trim(), 1);
        if (!row) break;
        rows.push(fit(row, header.length));
        index += 1;
      }
      blocks.push({ kind: "table", header, rows });
    } else {
      flushQuote();
      paragraph.push(line);
    }
  }
  flush();
  return blocks;
}

function heading(line: string): MarkdownBlock | null {
  const hashes = /^#*/.exec(line)![0].length;
  if (hashes < 1 || hashes > 3 || line[hashes] !== " ") return null;
  const text = line.slice(hashes).trim();
  return text ? { kind: "heading", level: hashes as 1 | 2 | 3, text } : null;
}

/** A list item, its depth from the indentation: two spaces (or a tab) a level. */
function listItem(line: string): MarkdownBlock | null {
  const indent = /^[ \t]*/.exec(line)![0];
  const width = [...indent].reduce((sum, character) => sum + (character === "\t" ? 4 : 1), 0);
  const depth = Math.min(Math.floor(width / 2), 6);
  const rest = line.slice(indent.length);
  for (const marker of ["- ", "* ", "+ ", "• "]) {
    if (rest.startsWith(marker)) {
      const text = rest.slice(marker.length).trim();
      return text ? { kind: "listItem", marker: { kind: "bullet" }, depth, text } : null;
    }
  }
  const numbered = /^(\d{1,9})[.)] (.*)$/.exec(rest);
  if (numbered) {
    const text = numbered[2]!.trim();
    return text ? { kind: "listItem", marker: { kind: "number", value: Number(numbered[1]) }, depth, text } : null;
  }
  return null;
}

/** `---`, `***` or `___`, three or more, spaces allowed between. */
function isRule(line: string): boolean {
  const marks = line.replaceAll(" ", "");
  return marks.length >= 3 && "-*_".includes(marks[0]!) && [...marks].every(mark => mark === marks[0]);
}

/** A table row's cells: the line has a pipe; the outer pipes are optional. */
function cells(line: string, minimum = 2): string[] | null {
  if (!line.includes("|")) return null;
  let body = line;
  if (body.startsWith("|")) body = body.slice(1);
  if (body.endsWith("|")) body = body.slice(0, -1);
  const found = body.split("|").map(cell => cell.trim());
  return found.length >= minimum ? found : null;
}

function isTableSeparator(line: string, columns: number): boolean {
  const found = cells(line);
  return found !== null && found.length === columns && found.every(cell => /^:?-+:?$/.test(cell));
}

function fit(row: string[], columns: number): string[] {
  return row.length >= columns ? row.slice(0, columns) : [...row, ...Array<string>(columns - row.length).fill("")];
}

/** A run of a line with one look: plain, bold, italic, `code`, or a link (http and https only). */
export type InlineSpan =
  | { kind: "text"; text: string }
  | { kind: "strong"; text: string }
  | { kind: "emphasis"; text: string }
  | { kind: "code"; text: string }
  | { kind: "link"; text: string; href: string };

const inlinePattern = /`([^`]+)`|\*\*([^*]+)\*\*|__([^_]+)__|\*([^*\s][^*]*)\*|_([^_\s][^_]*)_|\[([^\]]+)\]\(([^)\s]+)\)/g;

export function inlineSpans(text: string): InlineSpan[] {
  const spans: InlineSpan[] = [];
  let last = 0;
  for (const match of text.matchAll(inlinePattern)) {
    if (match.index > last) spans.push({ kind: "text", text: text.slice(last, match.index) });
    const [whole, code, strong, strongAlt, emphasis, emphasisAlt, label, href] = match;
    if (code !== undefined) spans.push({ kind: "code", text: code });
    else if (strong !== undefined || strongAlt !== undefined) spans.push({ kind: "strong", text: (strong ?? strongAlt)! });
    else if (emphasis !== undefined || emphasisAlt !== undefined) spans.push({ kind: "emphasis", text: (emphasis ?? emphasisAlt)! });
    else if (label !== undefined && href !== undefined && /^https?:\/\//i.test(href)) spans.push({ kind: "link", text: label, href });
    else spans.push({ kind: "text", text: whole });
    last = match.index + whole.length;
  }
  if (last < text.length) spans.push({ kind: "text", text: text.slice(last) });
  return spans;
}
