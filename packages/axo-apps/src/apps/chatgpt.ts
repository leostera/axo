import { z } from "zod";
import { ProviderError, tool, type AppDefinition, type AppTool } from "../app";

/**
 * ChatGPT as an app: `codemode.apps.chatgpt.<tool>({ account, ... })`, signed in the way the
 * Codex CLI is (see openai.ts), so calls use the person's ChatGPT plan rather than an API key.
 * `respond` is one turn of the Responses API at chatgpt.com/backend-api/codex, as Codex sends it:
 * streamed, not stored, read to its end here and returned whole.
 */

const CODEX = "https://chatgpt.com/backend-api/codex";
/** A turn can think for a while; a script has five minutes in all. */
const RESPOND_TIMEOUT_MS = 240_000;
const MAX_TEXT_CHARS = 400_000;

const message = z.object({
  role: z.enum(["user", "assistant", "developer"]),
  content: z.string().min(1).max(200_000),
}).strict();

type ResponseItem = { type?: string; role?: string; content?: Array<{ type?: string; text?: string }>; summary?: Array<{ text?: string }> };
type CompletedResponse = { id?: string; model?: string; status?: string; output?: ResponseItem[]; usage?: unknown; error?: { message?: string } | null };

/** Reads a Responses stream to its end: the completed response, or the failure it reported. */
export function completedResponse(stream: string): CompletedResponse {
  let completed: CompletedResponse | null = null;
  for (const event of stream.split(/\r?\n\r?\n/)) {
    const data = event.split(/\r?\n/).filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trimStart()).join("\n");
    if (!data || data === "[DONE]") continue;
    let parsed: { type?: string; response?: CompletedResponse; error?: { message?: string }; message?: string };
    try {
      parsed = JSON.parse(data);
    } catch {
      continue;
    }
    if (parsed.type === "response.completed" || parsed.type === "response.incomplete") completed = parsed.response ?? null;
    if (parsed.type === "response.failed") throw new ProviderError(502, `ChatGPT: ${parsed.response?.error?.message ?? "the response failed"}`.slice(0, 300));
    if (parsed.type === "error") throw new ProviderError(502, `ChatGPT: ${parsed.error?.message ?? parsed.message ?? "error"}`.slice(0, 300));
  }
  if (!completed) throw new ProviderError(502, "ChatGPT: the response ended before it completed");
  return completed;
}

const tools: AppTool[] = [
  tool({
    name: "respond",
    description:
      "Asks ChatGPT one turn, as the account's ChatGPT plan: { id, model, status, text, reasoning, usage }. " +
      "`input` is a prompt, or the conversation so far as [{ role, content }]. Pick `model` from list_models. " +
      "`webSearch` lets the model search the web. Nothing is stored at OpenAI beyond what ChatGPT keeps for any Codex turn.",
    input: z.object({
      model: z.string().min(1).max(128).describe("A model slug from list_models, such as \"gpt-5.5\"."),
      input: z.union([z.string().min(1).max(200_000), z.array(message).min(1).max(200)]),
      instructions: z.string().max(100_000).optional().describe("The system prompt; a plain helpful-assistant one when left out."),
      reasoningEffort: z.enum(["none", "minimal", "low", "medium", "high", "xhigh"]).optional(),
      webSearch: z.boolean().optional(),
    }).strict(),
    idempotent: true,
    async run(api, input) {
      const turns = typeof input.input === "string" ? [{ role: "user" as const, content: input.input }] : input.input;
      const body = {
        model: input.model,
        instructions: input.instructions ?? "You are a helpful assistant.",
        input: turns.map((turn) => ({
          type: "message",
          role: turn.role,
          content: [{ type: turn.role === "assistant" ? "output_text" : "input_text", text: turn.content }],
        })),
        store: false,
        stream: true,
        ...(input.reasoningEffort ? { reasoning: { effort: input.reasoningEffort, summary: "auto" } } : {}),
        ...(input.webSearch ? { tools: [{ type: "web_search" }] } : {}),
      };
      const answer = await api.requestRaw("POST", `${CODEX}/responses`, {
        body,
        accept: "text/event-stream",
        headers: { "OpenAI-Beta": "responses=experimental" },
        timeoutMs: RESPOND_TIMEOUT_MS,
      });
      const response = completedResponse(new TextDecoder().decode(answer.body));
      const output = response.output ?? [];
      const text = output.filter((item) => item.type === "message")
        .flatMap((item) => item.content ?? []).filter((part) => part.type === "output_text").map((part) => part.text ?? "").join("");
      const reasoning = output.filter((item) => item.type === "reasoning").flatMap((item) => item.summary ?? []).map((s) => s.text ?? "").join("\n");
      return {
        id: response.id ?? null,
        model: response.model ?? input.model,
        status: response.status ?? null,
        text: text.slice(0, MAX_TEXT_CHARS),
        reasoning: reasoning ? reasoning.slice(0, 20_000) : null,
        usage: response.usage ?? null,
        truncated: text.length > MAX_TEXT_CHARS,
      };
    },
  }),
  tool({
    name: "list_models",
    description: "Lists the models the account's ChatGPT plan can use through Codex: { models: [{ slug, name, description, reasoningEfforts }] }.",
    input: z.object({}).strict(),
    idempotent: true,
    async run(api) {
      const answer = (await api.request("GET", `${CODEX}/models`, { query: { client_version: "1.0.0" } })) as {
        models?: Array<{ slug?: string; display_name?: string; description?: string; supported_reasoning_levels?: Array<{ effort?: string }> }>;
      };
      return {
        models: (answer.models ?? []).map((m) => ({
          slug: m.slug ?? null,
          name: m.display_name ?? null,
          description: m.description ?? null,
          reasoningEfforts: (m.supported_reasoning_levels ?? []).map((l) => l.effort).filter(Boolean),
        })),
      };
    },
  }),
  tool({
    name: "usage",
    description: "How much of the account's ChatGPT plan limits Codex has used, and when they reset, as ChatGPT reports it.",
    input: z.object({}).strict(),
    idempotent: true,
    async run(api) {
      return api.request("GET", "https://chatgpt.com/backend-api/wham/usage");
    },
  }),
];

export const chatgpt: AppDefinition = {
  name: "chatgpt",
  title: "ChatGPT",
  description: "Ask ChatGPT's models with your ChatGPT plan, signed in the way Codex is.",
  permissions: [
    "Ask ChatGPT's models, using your plan's limits",
    "See which models your plan offers, and how much of its limits you have used",
  ],
  signIn: "device",
  provider: "openai",
  providerTitle: "OpenAI",
  category: "productivity",
  apiOrigin: "https://chatgpt.com",
  hosts: ["chatgpt.com"],
  reference: "https://github.com/openai/codex (the Responses API at https://chatgpt.com/backend-api/codex/responses, streamed with store: false)",
  tools,
};
