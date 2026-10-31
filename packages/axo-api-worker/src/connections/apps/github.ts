import { z } from "zod";
import { tool, type AppDefinition, type AppTool, type ProviderApi } from "./app";
import { bearer } from "./token";

/**
 * GitHub as an app: `codemode.apps.github.<tool>({ account, ... })`, with a personal access
 * token, named by its login. What it reaches is what the token was given (fine-grained tokens
 * name their repositories). GitHub's own MCP server is the other way in, once Axo has an OAuth
 * app registered with GitHub.
 */

const owner = z.string().regex(/^[A-Za-z0-9-]{1,39}$/).describe("A user or organisation, such as \"leostera\".");
const repo = z.string().regex(/^[A-Za-z0-9._-]{1,100}$/).describe("A repository's name, without its owner.");
const number = z.number().int().positive();
const perPage = z.number().int().min(1).max(100).optional().describe("Default 30.");
const page = z.number().int().min(1).optional();

// GitHub refuses requests without a User-Agent.
const API_HEADERS = { "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "Axo" };
const get = (api: ProviderApi, path: string, query: Record<string, string | undefined> = {}) =>
  api.request("GET", path, { query, headers: API_HEADERS, accept: "application/vnd.github+json" });
const send = (api: ProviderApi, method: "POST" | "PATCH" | "PUT" | "DELETE", path: string, body: unknown) =>
  api.request(method, path, { body, headers: API_HEADERS, accept: "application/vnd.github+json" });
const n = (value: number | undefined) => (value === undefined ? undefined : String(value));

type Issue = { number: number; title: string; state: string; user?: { login?: string }; labels?: Array<{ name?: string } | string>; comments?: number; created_at: string; updated_at: string; html_url: string; pull_request?: unknown; body?: string | null };
const issue = (i: Issue) => ({
  number: i.number, title: i.title, state: i.state, author: i.user?.login ?? null, pullRequest: Boolean(i.pull_request),
  labels: (i.labels ?? []).map((l) => (typeof l === "string" ? l : l.name)).filter(Boolean), comments: i.comments ?? 0,
  created: i.created_at, updated: i.updated_at, url: i.html_url,
});

const tools: AppTool[] = [
  tool({
    name: "get_me",
    description: "The token's user: { login, name, email, ... }.",
    input: z.object({}).strict(),
    idempotent: true,
    run: (api) => get(api, "/user"),
  }),
  tool({
    name: "list_repos",
    description: "Repositories the user can reach, most recently pushed first: { repos: [{ fullName, private, description, defaultBranch, pushed, url }] }.",
    input: z.object({ owner: owner.optional().describe("Only this user's or organisation's; all the user's when left out."), perPage, page }).strict(),
    idempotent: true,
    async run(api, input) {
      const path = input.owner ? `/users/${input.owner}/repos` : "/user/repos";
      const repos = (await get(api, path, { sort: "pushed", per_page: n(input.perPage), page: n(input.page) })) as Array<{ full_name: string; private: boolean; description: string | null; default_branch: string; pushed_at: string; html_url: string }>;
      return { repos: repos.map((r) => ({ fullName: r.full_name, private: r.private, description: r.description, defaultBranch: r.default_branch, pushed: r.pushed_at, url: r.html_url })) };
    },
  }),
  tool({
    name: "search",
    description:
      "GitHub search with its own query syntax. `kind` is issues (issues and pull requests, such as \"repo:o/r is:pr is:open author:@me\"), repositories, code or commits. " +
      "Returns { total, items } with GitHub's items.",
    input: z.object({ kind: z.enum(["issues", "repositories", "code", "commits"]), query: z.string().min(1).max(512), perPage, page }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await get(api, `/search/${input.kind}`, { q: input.query, per_page: n(input.perPage), page: n(input.page) })) as { total_count: number; items: unknown[] };
      return { total: answer.total_count, items: input.kind === "issues" ? (answer.items as Issue[]).map(issue) : answer.items };
    },
  }),
  tool({
    name: "list_issues",
    description: "A repository's issues and pull requests, newest first: { issues: [{ number, title, state, author, pullRequest, labels, comments, created, updated, url }] }.",
    input: z.object({ owner, repo, state: z.enum(["open", "closed", "all"]).optional(), labels: z.string().max(256).optional().describe("Comma-separated."), perPage, page }).strict(),
    idempotent: true,
    async run(api, input) {
      const issues = (await get(api, `/repos/${input.owner}/${input.repo}/issues`, { state: input.state, labels: input.labels, per_page: n(input.perPage), page: n(input.page) })) as Issue[];
      return { issues: issues.map(issue) };
    },
  }),
  tool({
    name: "get_issue",
    description: "An issue or pull request with its body and comments: { ...issue, body, comments: [{ author, body, created }] }.",
    input: z.object({ owner, repo, number }).strict(),
    idempotent: true,
    async run(api, input) {
      const base = `/repos/${input.owner}/${input.repo}/issues/${input.number}`;
      const [found, comments] = await Promise.all([get(api, base) as Promise<Issue>, get(api, `${base}/comments`, { per_page: "100" }) as Promise<Array<{ user?: { login?: string }; body?: string; created_at: string }>>]);
      return { ...issue(found), body: found.body ?? "", comments: comments.map((c) => ({ author: c.user?.login ?? null, body: c.body ?? "", created: c.created_at })) };
    },
  }),
  tool({
    name: "create_issue",
    description: "Opens an issue. Returns { number, url }.",
    input: z.object({ owner, repo, title: z.string().min(1).max(256), body: z.string().max(65536).optional(), labels: z.array(z.string().max(50)).max(20).optional() }).strict(),
    idempotent: false,
    async run(api, input) {
      const created = (await send(api, "POST", `/repos/${input.owner}/${input.repo}/issues`, { title: input.title, body: input.body, labels: input.labels })) as Issue;
      return { number: created.number, url: created.html_url };
    },
  }),
  tool({
    name: "comment",
    description: "Comments on an issue or pull request. Returns { id, url }.",
    input: z.object({ owner, repo, number, body: z.string().min(1).max(65536) }).strict(),
    idempotent: false,
    async run(api, input) {
      const created = (await send(api, "POST", `/repos/${input.owner}/${input.repo}/issues/${input.number}/comments`, { body: input.body })) as { id: number; html_url: string };
      return { id: created.id, url: created.html_url };
    },
  }),
  tool({
    name: "get_pull",
    description: "A pull request: { number, title, state, draft, merged, author, head, base, mergeable, additions, deletions, changedFiles, url, body } and its files' names.",
    input: z.object({ owner, repo, number }).strict(),
    idempotent: true,
    async run(api, input) {
      const base = `/repos/${input.owner}/${input.repo}/pulls/${input.number}`;
      const [p, files] = await Promise.all([
        get(api, base) as Promise<{ number: number; title: string; state: string; draft?: boolean; merged?: boolean; user?: { login?: string }; head: { ref: string }; base: { ref: string }; mergeable?: boolean | null; additions?: number; deletions?: number; changed_files?: number; html_url: string; body?: string | null }>,
        get(api, `${base}/files`, { per_page: "100" }) as Promise<Array<{ filename: string; status: string; additions: number; deletions: number }>>,
      ]);
      return {
        number: p.number, title: p.title, state: p.state, draft: p.draft ?? false, merged: p.merged ?? false, author: p.user?.login ?? null,
        head: p.head.ref, base: p.base.ref, mergeable: p.mergeable ?? null, additions: p.additions ?? 0, deletions: p.deletions ?? 0,
        changedFiles: p.changed_files ?? files.length, url: p.html_url, body: p.body ?? "", files: files.map((f) => ({ name: f.filename, status: f.status, additions: f.additions, deletions: f.deletions })),
      };
    },
  }),
  tool({
    name: "get_file",
    description: "A file's text at a branch, tag or commit (the default branch when left out): { path, sha, size, text }. Files over 1 MB are refused.",
    input: z.object({ owner, repo, path: z.string().min(1).max(1024), ref: z.string().max(255).optional() }).strict(),
    idempotent: true,
    async run(api, input) {
      const file = (await get(api, `/repos/${input.owner}/${input.repo}/contents/${input.path.split("/").map(encodeURIComponent).join("/")}`, { ref: input.ref })) as { path: string; sha: string; size: number; content?: string; encoding?: string; type: string };
      if (file.type !== "file" || file.encoding !== "base64" || !file.content) return { path: file.path, sha: file.sha, size: file.size, text: null };
      const bytes = Uint8Array.from(atob(file.content.replace(/\n/g, "")), (c) => c.charCodeAt(0));
      return { path: file.path, sha: file.sha, size: file.size, text: new TextDecoder().decode(bytes) };
    },
  }),
  tool({
    name: "list_notifications",
    description: "The user's unread notifications, newest first: { notifications: [{ id, reason, repo, type, title, updated }] }.",
    input: z.object({ all: z.boolean().optional().describe("Read ones too."), perPage }).strict(),
    idempotent: true,
    async run(api, input) {
      const items = (await get(api, "/notifications", { all: input.all ? "true" : undefined, per_page: n(input.perPage) })) as Array<{ id: string; reason: string; updated_at: string; repository: { full_name: string }; subject: { type: string; title: string } }>;
      return { notifications: items.map((x) => ({ id: x.id, reason: x.reason, repo: x.repository.full_name, type: x.subject.type, title: x.subject.title, updated: x.updated_at })) };
    },
  }),
];

export const github: AppDefinition = {
  name: "github",
  title: "GitHub",
  description: "Your GitHub: repositories, issues, pull requests, code search and notifications.",
  permissions: [
    "See the repositories, issues and pull requests your token reaches",
    "Open issues and comment on them",
    "Anything else your token allows",
  ],
  signIn: "token",
  provider: "github",
  providerTitle: "GitHub",
  category: "developer",
  apiOrigin: "https://api.github.com",
  hosts: ["api.github.com"],
  reference: "https://docs.github.com/rest",
  token: {
    helpUrl: "https://github.com/settings/personal-access-tokens/new",
    named: false,
    fields: [{ name: "token", label: "Personal access token", help: "In GitHub, open Settings, Developer settings, Personal access tokens, and make one for the repositories Axo may use.", secret: true }],
    authorize: bearer("token"),
    async identify(api) {
      const me = (await get(api, "/user")) as { login?: string };
      return me.login?.toLowerCase() ?? null;
    },
  },
  tools,
};
