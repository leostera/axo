import { z } from "zod";
import { tool, type AppDefinition, type AppTool } from "../app";

/**
 * Google Tasks as an app: `codemode.apps.tasks.<tool>({ account, ... })` over the Tasks API, with
 * full access (`tasks`): task lists and their tasks.
 */

export const TASKS_SCOPE = "https://www.googleapis.com/auth/tasks";
const BASE = "/tasks/v1";

const listId = z.string().regex(/^[A-Za-z0-9_@.-]{1,256}$/, "expected a task list ID").describe("A task list's id; \"@default\" is the account's default list.");
const taskId = z.string().regex(/^[A-Za-z0-9_-]{1,256}$/, "expected a task ID");
const due = z.string().regex(/^\d{4}-\d{2}-\d{2}/, "expected a date, YYYY-MM-DD").describe("The due date, YYYY-MM-DD; Google keeps only the date.");

type Task = { id: string; title?: string; notes?: string; status?: string; due?: string; completed?: string; parent?: string; webViewLink?: string; updated?: string };

const tools: AppTool[] = [
  tool({
    name: "list_tasklists",
    description: "Lists the account's task lists: { tasklists: [{ id, title, updated }] }.",
    input: z.object({}).strict(),
    idempotent: true,
    async run(api) {
      const answer = (await api.request("GET", `${BASE}/users/@me/lists`, { query: { maxResults: "100" } })) as { items?: Array<{ id: string; title?: string; updated?: string }> };
      return { tasklists: (answer.items ?? []).map((l) => ({ id: l.id, title: l.title ?? null, updated: l.updated ?? null })) };
    },
  }),
  tool({
    name: "create_tasklist",
    description: "Creates a task list and returns { id, title }.",
    input: z.object({ title: z.string().min(1).max(1024) }).strict(),
    idempotent: false,
    async run(api, input) {
      const list = (await api.request("POST", `${BASE}/users/@me/lists`, { body: { title: input.title } })) as { id: string; title?: string };
      return { id: list.id, title: list.title ?? input.title };
    },
  }),
  tool({
    name: "list_tasks",
    description: "Lists a task list's tasks: { tasks: [{ id, title, notes, status, due, completed, parent }], nextPageToken }. Completed tasks are left out unless showCompleted.",
    input: z.object({
      list: listId.optional(),
      showCompleted: z.boolean().optional(),
      dueMin: z.iso.datetime({ offset: true }).optional(),
      dueMax: z.iso.datetime({ offset: true }).optional(),
      maxResults: z.number().int().min(1).max(100).optional().describe("Default 100."),
      pageToken: z.string().max(1024).optional(),
    }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("GET", `${BASE}/lists/${input.list ?? "@default"}/tasks`, {
        query: {
          showCompleted: String(input.showCompleted ?? false),
          showHidden: String(input.showCompleted ?? false),
          dueMin: input.dueMin,
          dueMax: input.dueMax,
          maxResults: String(input.maxResults ?? 100),
          pageToken: input.pageToken,
        },
      })) as { items?: Task[]; nextPageToken?: string };
      return { tasks: (answer.items ?? []).map(task), nextPageToken: answer.nextPageToken ?? null };
    },
  }),
  tool({
    name: "create_task",
    description: "Adds a task, under `parent` if given, and returns it.",
    input: z.object({ list: listId.optional(), title: z.string().min(1).max(1024), notes: z.string().max(8192).optional(), due: due.optional(), parent: taskId.optional() }).strict(),
    idempotent: false,
    async run(api, input) {
      const created = (await api.request("POST", `${BASE}/lists/${input.list ?? "@default"}/tasks`, {
        query: { parent: input.parent },
        body: { title: input.title, notes: input.notes, due: dueOf(input.due) },
      })) as Task;
      return task(created);
    },
  }),
  tool({
    name: "update_task",
    description: "Changes a task's title, notes, due date, or marks it done (`done: true`) or not, and returns it. A field left out is not touched.",
    input: z.object({
      list: listId.optional(),
      id: taskId,
      title: z.string().min(1).max(1024).optional(),
      notes: z.string().max(8192).optional(),
      due: due.nullable().optional().describe("YYYY-MM-DD, or null to clear it."),
      done: z.boolean().optional(),
    }).strict(),
    idempotent: true,
    async run(api, input) {
      const body: Record<string, unknown> = {};
      if (input.title !== undefined) body.title = input.title;
      if (input.notes !== undefined) body.notes = input.notes;
      if (input.due !== undefined) body.due = input.due === null ? null : dueOf(input.due);
      if (input.done !== undefined) Object.assign(body, input.done ? { status: "completed" } : { status: "needsAction", completed: null });
      const updated = (await api.request("PATCH", `${BASE}/lists/${input.list ?? "@default"}/tasks/${input.id}`, { body })) as Task;
      return task(updated);
    },
  }),
  tool({
    name: "delete_task",
    description: "Deletes a task. Returns { deleted: true }.",
    input: z.object({ list: listId.optional(), id: taskId }).strict(),
    idempotent: true,
    async run(api, input) {
      await api.request("DELETE", `${BASE}/lists/${input.list ?? "@default"}/tasks/${input.id}`);
      return { deleted: true };
    },
  }),
  tool({
    name: "clear_completed",
    description: "Hides every completed task of a list. Returns { cleared: true }.",
    input: z.object({ list: listId.optional() }).strict(),
    idempotent: true,
    async run(api, input) {
      await api.request("POST", `${BASE}/lists/${input.list ?? "@default"}/clear`);
      return { cleared: true };
    },
  }),
];

export const tasks: AppDefinition = {
  name: "tasks",
  title: "Google Tasks",
  description: "See and manage your to-do lists.",
  permissions: [
    "See every task list and task",
    "Add, change, complete and delete tasks and lists",
  ],
  signIn: "oauth",
  provider: "google",
  providerTitle: "Google",
  category: "productivity",
  scopes: ["openid", "email", TASKS_SCOPE],
  requiredScopes: [TASKS_SCOPE],
  apiOrigin: "https://tasks.googleapis.com",
  hosts: ["tasks.googleapis.com"],
  reference: "https://developers.google.com/workspace/tasks/reference/rest",
  tools,
};

/** Google takes a due date as an RFC 3339 time at midnight UTC. */
function dueOf(date: string | undefined): string | undefined {
  return date ? `${date.slice(0, 10)}T00:00:00.000Z` : undefined;
}

function task(t: Task) {
  return {
    id: t.id,
    title: t.title ?? null,
    notes: t.notes ?? null,
    status: t.status ?? null,
    due: t.due?.slice(0, 10) ?? null,
    completed: t.completed ?? null,
    parent: t.parent ?? null,
    url: t.webViewLink ?? null,
  };
}
