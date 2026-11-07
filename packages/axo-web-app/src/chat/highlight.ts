/**
 * Syntax colours for code in replies. Not a parser: one pass of a few patterns per family of
 * languages (comments, strings, numbers, keywords, types, calls), which is what makes code
 * readable at a glance. It only colours, so it never moves anything on the page, and it runs
 * as the code is drawn, with no download and no waiting.
 */
export type TokenKind = "plain" | "comment" | "string" | "number" | "keyword" | "type" | "call" | "property" | "added" | "removed" | "meta";
export interface Token { readonly kind: TokenKind; readonly text: string }

interface Grammar {
  readonly comments: readonly string[];
  readonly strings: readonly string[];
  readonly keywords: ReadonlySet<string>;
}

const words = (text: string) => new Set(text.split(/\s+/).filter(Boolean));

const LINE_COMMENT: Record<string, string> = {
  slash: String.raw`\/\/[^\n]*`,
  hash: String.raw`(?<![^\s])#[^\n]*`,
  dash: String.raw`--[^\n]*`,
  block: String.raw`\/\*[\s\S]*?(?:\*\/|$)`,
  ocaml: String.raw`\(\*[\s\S]*?(?:\*\)|$)`,
  html: String.raw`<!--[\s\S]*?(?:-->|$)`,
};
const STRING: Record<string, string> = {
  double: String.raw`"(?:[^"\\\n]|\\.)*"?`,
  single: String.raw`'(?:[^'\\\n]|\\.)*'?`,
  backtick: String.raw`\x60(?:[^\x60\\]|\\.)*\x60?`,
  triple: String.raw`"""[\s\S]*?(?:"""|$)`,
};

const C_LIKE = "if else for while do return break continue switch case default new delete try catch finally throw class struct enum interface extends implements import export from as const let var function static public private protected void null true false this self super in of typeof instanceof async await yield";
const grammars: Record<string, Grammar> = {
  ts: {
    comments: ["block", "slash"], strings: ["double", "single", "backtick"],
    keywords: words(`${C_LIKE} type readonly keyof satisfies declare namespace undefined any unknown never string number boolean`),
  },
  rust: {
    comments: ["block", "slash"], strings: ["double"],
    keywords: words("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while Some None Ok Err"),
  },
  swift: {
    comments: ["block", "slash"], strings: ["triple", "double"],
    keywords: words("actor as async await break case catch class continue default defer do else enum extension false fileprivate final for func guard if import in init inout internal let nil nonisolated private protocol public return self Self some any static struct super switch throw throws true try var where while @MainActor @Observable @State"),
  },
  go: {
    comments: ["block", "slash"], strings: ["double", "backtick"],
    keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var nil true false"),
  },
  zig: {
    comments: ["slash"], strings: ["double"],
    keywords: words("const var fn pub return if else while for switch break continue struct enum union error try catch defer errdefer comptime inline export extern test null undefined true false and or orelse"),
  },
  c: {
    comments: ["block", "slash"], strings: ["double", "single"],
    keywords: words("auto break case char const continue default do double else enum extern float for goto if int long register return short signed sizeof static struct switch typedef union unsigned void volatile while include define NULL true false"),
  },
  ocaml: {
    comments: ["ocaml"], strings: ["double"],
    keywords: words("and as assert begin class constraint do done downto else end exception external false for fun function functor if in include inherit let match method module mutable new object of open or private rec sig struct then to true try type val virtual when while with"),
  },
  python: {
    comments: ["hash"], strings: ["triple", "double", "single"],
    keywords: words("and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield self"),
  },
  shell: {
    comments: ["hash"], strings: ["double", "single"],
    keywords: words("if then else elif fi for while until do done case esac in function return export local set unset source cd echo exit"),
  },
  sql: {
    comments: ["dash", "block"], strings: ["single", "double"],
    keywords: words("select from where insert into values update set delete create table index view drop alter add primary key foreign references not null and or join left right inner outer on group by order having limit offset as distinct returning begin commit rollback SELECT FROM WHERE INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE INDEX DROP ALTER PRIMARY KEY NOT NULL AND OR JOIN ON GROUP BY ORDER LIMIT AS"),
  },
  data: { comments: ["hash"], strings: ["double", "single"], keywords: words("true false null") },
  json: { comments: [], strings: ["double"], keywords: words("true false null") },
  css: { comments: ["block"], strings: ["double", "single"], keywords: words("important") },
  html: { comments: ["html"], strings: ["double", "single"], keywords: new Set() },
};

const aliases: Record<string, string> = {
  ts: "ts", typescript: "ts", tsx: "ts", js: "ts", javascript: "ts", jsx: "ts", mjs: "ts", cjs: "ts",
  rs: "rust", rust: "rust", swift: "swift", go: "go", zig: "zig", c: "c", h: "c", cpp: "c", "c++": "c", java: "c", kotlin: "c",
  ml: "ocaml", mli: "ocaml", ocaml: "ocaml", reason: "ocaml", py: "python", python: "python",
  sh: "shell", bash: "shell", zsh: "shell", shell: "shell", console: "shell", fish: "shell",
  sql: "sql", sqlite: "sql", toml: "data", yaml: "data", yml: "data", ini: "data", dockerfile: "shell",
  json: "json", jsonc: "json", jsonl: "json", css: "css", scss: "css", html: "html", xml: "html", svg: "html",
};

const compiled = new Map<string, RegExp>();

function pattern(grammar: Grammar): RegExp {
  const parts = [
    ...grammar.comments.map(name => `(?<comment>${LINE_COMMENT[name]})`),
    ...grammar.strings.map(name => `(?<string>${STRING[name]})`),
    String.raw`(?<number>\b(?:0x[0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b)`,
    String.raw`(?<word>@?[A-Za-z_][A-Za-z0-9_]*)`,
  ];
  // Duplicate group names are allowed in alternatives (ES2025); join them by renaming.
  let n = 0;
  return new RegExp(parts.join("|").replace(/\?<(comment|string)>/g, (_, name) => `?<${name}${n++}>`), "g");
}

/** Colours `text` as `language`; unknown languages come back as one plain token. */
export function highlight(text: string, language: string | null): Token[] {
  const name = language ? aliases[language.toLowerCase()] : undefined;
  if (language && /^(diff|patch)$/i.test(language)) return diffTokens(text);
  const grammar = name ? grammars[name] : undefined;
  if (!name || !grammar) return [{ kind: "plain", text }];
  let regex = compiled.get(name);
  if (!regex) compiled.set(name, regex = pattern(grammar));
  regex.lastIndex = 0;

  const tokens: Token[] = [];
  const push = (kind: TokenKind, value: string) => {
    const last = tokens[tokens.length - 1];
    if (last && last.kind === kind) tokens[tokens.length - 1] = { kind, text: last.text + value };
    else if (value) tokens.push({ kind, text: value });
  };
  let at = 0;
  for (const match of text.matchAll(regex)) {
    const index = match.index;
    push("plain", text.slice(at, index));
    const value = match[0];
    const groups = match.groups ?? {};
    const after = text.slice(index + value.length);
    const kind: TokenKind = Object.entries(groups).find(([, v]) => v !== undefined)?.[0].replace(/\d+$/, "") as TokenKind;
    if (kind === ("word" as TokenKind)) {
      if (grammar.keywords.has(value)) push("keyword", value);
      else if (/^\s*\(/.test(after)) push("call", value);
      else if (/^[A-Z][a-z0-9]/.test(value) && name !== "sql") push("type", value);
      else push("plain", value);
    } else if (kind === "string" && name === "json" && /^\s*:/.test(after)) push("property", value);
    else push(kind, value);
    at = index + value.length;
  }
  push("plain", text.slice(at));
  return tokens;
}

function diffTokens(text: string): Token[] {
  return text.split(/(?<=\n)/).map(line => ({
    kind: line.startsWith("+") ? "added" : line.startsWith("-") ? "removed" : line.startsWith("@@") ? "meta" : "plain",
    text: line,
  }));
}
