import { z } from "zod";
import { Octokit as Core } from "@octokit/core";
import { paginateRest } from "@octokit/plugin-paginate-rest";
import { restEndpointMethods, type RestEndpointMethodTypes } from "@octokit/plugin-rest-endpoint-methods";
import { tool, type AppDefinition, type AppTool, type ProviderApi } from "../app";

/**
 * GitHub as an app: `codemode.apps.github.<tool>({ account, ... })`, signed in with an OAuth app
 * of the person's (oauth/github.ts) and named by the user's login.
 */

const owner = z.string().regex(/^[A-Za-z0-9-]{1,39}$/).describe("A user or organisation, such as \"leostera\".");
const repo = z.string().regex(/^[A-Za-z0-9._-]{1,100}$/).describe("A repository's name, without its owner.");
const number = z.number().int().positive();
const perPage = z.number().int().min(1).max(100).optional().describe("Default 30.");
const page = z.number().int().min(1).optional();

/**
 * Octokit, GitHub's own SDK, with its REST methods and pagination, sending through the gateway's
 * fetch: the grant goes on there, never in Octokit. GitHub refuses requests without a User-Agent.
 */
const Octokit = Core.plugin(restEndpointMethods, paginateRest);
const octokit = (api: ProviderApi) => new Octokit({ baseUrl: "https://api.github.com", userAgent: "Axo", request: { fetch: api.fetch } }).rest;

type Issue = RestEndpointMethodTypes["issues"]["get"]["response"]["data"];
const issue = (i: Issue) => ({
  number: i.number, title: i.title, state: i.state, author: i.user?.login ?? null, pullRequest: Boolean(i.pull_request),
  labels: i.labels.map((l) => (typeof l === "string" ? l : l.name)).filter(Boolean), comments: i.comments,
  created: i.created_at, updated: i.updated_at, url: i.html_url,
});

const tools: AppTool[] = [
  tool({
    name: "get_me",
    description: "The signed-in user: { login, name, email, ... }.",
    input: z.object({}).strict(),
    idempotent: true,
    run: async (api) => (await octokit(api).users.getAuthenticated()).data,
  }),
  tool({
    name: "list_repos",
    description: "Repositories the user can reach, most recently pushed first: { repos: [{ fullName, private, description, defaultBranch, pushed, url }] }.",
    input: z.object({ owner: owner.optional().describe("Only this user's or organisation's; all the user's when left out."), perPage, page }).strict(),
    idempotent: true,
    async run(api, input) {
      const paging = { per_page: input.perPage, page: input.page };
      const repos = input.owner
        ? (await octokit(api).repos.listForUser({ username: input.owner, sort: "pushed", ...paging })).data
        : (await octokit(api).repos.listForAuthenticatedUser({ sort: "pushed", ...paging })).data;
      return { repos: repos.map((r) => ({ fullName: r.full_name, private: r.private, description: r.description, defaultBranch: r.default_branch ?? null, pushed: r.pushed_at, url: r.html_url })) };
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
      const query = { q: input.query, per_page: input.perPage, page: input.page };
      const search = octokit(api).search;
      if (input.kind === "issues") {
        const answer = (await search.issuesAndPullRequests({ ...query, advanced_search: "true" })).data;
        return { total: answer.total_count, items: answer.items.map((i) => issue(i as Issue)) };
      }
      const answer = (await (input.kind === "repositories" ? search.repos(query) : input.kind === "code" ? search.code(query) : search.commits(query))).data;
      return { total: answer.total_count, items: answer.items };
    },
  }),
  tool({
    name: "list_issues",
    description: "A repository's issues and pull requests, newest first: { issues: [{ number, title, state, author, pullRequest, labels, comments, created, updated, url }] }.",
    input: z.object({ owner, repo, state: z.enum(["open", "closed", "all"]).optional(), labels: z.string().max(256).optional().describe("Comma-separated."), perPage, page }).strict(),
    idempotent: true,
    async run(api, input) {
      const issues = (await octokit(api).issues.listForRepo({ owner: input.owner, repo: input.repo, state: input.state, labels: input.labels, per_page: input.perPage, page: input.page })).data;
      return { issues: issues.map((i) => issue(i as Issue)) };
    },
  }),
  tool({
    name: "get_issue",
    description: "An issue or pull request with its body and comments: { ...issue, body, comments: [{ author, body, created }] }.",
    input: z.object({ owner, repo, number }).strict(),
    idempotent: true,
    async run(api, input) {
      const target = { owner: input.owner, repo: input.repo, issue_number: input.number };
      const [found, comments] = await Promise.all([octokit(api).issues.get(target), octokit(api).issues.listComments({ ...target, per_page: 100 })]);
      return { ...issue(found.data), body: found.data.body ?? "", comments: comments.data.map((c) => ({ author: c.user?.login ?? null, body: c.body ?? "", created: c.created_at })) };
    },
  }),
  tool({
    name: "create_issue",
    description: "Opens an issue. Returns { number, url }.",
    input: z.object({ owner, repo, title: z.string().min(1).max(256), body: z.string().max(65536).optional(), labels: z.array(z.string().max(50)).max(20).optional() }).strict(),
    idempotent: false,
    async run(api, input) {
      const created = (await octokit(api).issues.create({ owner: input.owner, repo: input.repo, title: input.title, body: input.body, labels: input.labels })).data;
      return { number: created.number, url: created.html_url };
    },
  }),
  tool({
    name: "comment",
    description: "Comments on an issue or pull request. Returns { id, url }.",
    input: z.object({ owner, repo, number, body: z.string().min(1).max(65536) }).strict(),
    idempotent: false,
    async run(api, input) {
      const created = (await octokit(api).issues.createComment({ owner: input.owner, repo: input.repo, issue_number: input.number, body: input.body })).data;
      return { id: created.id, url: created.html_url };
    },
  }),
  tool({
    name: "get_pull",
    description: "A pull request: { number, title, state, draft, merged, author, head, base, mergeable, additions, deletions, changedFiles, url, body } and its files' names.",
    input: z.object({ owner, repo, number }).strict(),
    idempotent: true,
    async run(api, input) {
      const target = { owner: input.owner, repo: input.repo, pull_number: input.number };
      const [{ data: p }, { data: files }] = await Promise.all([octokit(api).pulls.get(target), octokit(api).pulls.listFiles({ ...target, per_page: 100 })]);
      return {
        number: p.number, title: p.title, state: p.state, draft: p.draft ?? false, merged: p.merged, author: p.user?.login ?? null,
        head: p.head.ref, base: p.base.ref, mergeable: p.mergeable, additions: p.additions, deletions: p.deletions,
        changedFiles: p.changed_files, url: p.html_url, body: p.body ?? "", files: files.map((f) => ({ name: f.filename, status: f.status, additions: f.additions, deletions: f.deletions })),
      };
    },
  }),
  tool({
    name: "get_file",
    description: "A file's text at a branch, tag or commit (the default branch when left out): { path, sha, size, text }. Files over 1 MB are refused.",
    input: z.object({ owner, repo, path: z.string().min(1).max(1024), ref: z.string().max(255).optional() }).strict(),
    idempotent: true,
    async run(api, input) {
      const { data } = await octokit(api).repos.getContent({ owner: input.owner, repo: input.repo, path: input.path, ref: input.ref });
      if (Array.isArray(data) || data.type !== "file" || !("content" in data)) {
        const entry = Array.isArray(data) ? null : data;
        return { path: entry?.path ?? input.path, sha: entry?.sha ?? null, size: entry?.size ?? 0, text: null };
      }
      if (data.encoding !== "base64" || !data.content) return { path: data.path, sha: data.sha, size: data.size, text: null };
      const bytes = Uint8Array.from(atob(data.content.replace(/\n/g, "")), (c) => c.charCodeAt(0));
      return { path: data.path, sha: data.sha, size: data.size, text: new TextDecoder().decode(bytes) };
    },
  }),
  tool({
    name: "list_notifications",
    description: "The user's unread notifications, newest first: { notifications: [{ id, reason, repo, type, title, updated }] }.",
    input: z.object({ all: z.boolean().optional().describe("Read ones too."), perPage }).strict(),
    idempotent: true,
    async run(api, input) {
      const items = (await octokit(api).activity.listNotificationsForAuthenticatedUser({ all: input.all, per_page: input.perPage })).data;
      return { notifications: items.map((x) => ({ id: x.id, reason: x.reason, repo: x.repository.full_name, type: x.subject.type, title: x.subject.title, updated: x.updated_at })) };
    },
  }),
];

export const github: AppDefinition = {
  name: "github",
  title: "GitHub",
  description: "Your GitHub: repositories, issues, pull requests, code search and notifications.",
  permissions: [
    "See and change every repository you can reach, public and private: code, issues, pull requests and settings",
    "Open, edit and comment on issues and pull requests",
    "See the organisations and teams you belong to",
    "See your notifications and mark them read",
  ],
  signIn: "oauth",
  provider: "github",
  providerTitle: "GitHub",
  category: "developer",
  apiOrigin: "https://api.github.com",
  hosts: ["api.github.com"],
  reference: "https://docs.github.com/rest",
  // `repo` reaches private repositories (GitHub has no read-only scope for them), `read:org` the
  // person's organisations, `notifications` their inbox. GitHub's scopes cannot be unticked.
  scopes: ["repo", "read:org", "notifications"],
  requiredScopes: ["repo"],
  tools,
};
