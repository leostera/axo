// A controlled local model and actual tools inside ambient Pi's real TUI/agent.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { readFileSync } from "node:fs";
export default function provider(pi: ExtensionAPI) {
  pi.on("input", event => { if (event.text === "FIXTURE_HANDLED_INPUT") return { action: "handled" }; });
  const config = JSON.parse(readFileSync(process.env.AXO_INTERACTIVE_FIXTURE_CONFIG!, "utf8"));
  const url = new URL(config.baseUrl);
  if (url.protocol !== "http:" || url.hostname !== "127.0.0.1") throw new Error("Fixture provider must be loopback");
  pi.registerProvider("axo-interactive-fixture", { baseUrl: url.toString(), apiKey: "local-fixture-only", api: "openai-completions",
    models: [{ id: "fixture", name: "Interactive fixture", reasoning: false, input: ["text"], contextWindow: 32000, maxTokens: 1000, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }] });
  pi.registerTool({ name: "fixture_ask", label: "Choice", description: "Show an actual interactive choice", parameters: Type.Object({}),
    async execute(_id, _params, signal, _update, ctx) {
      const choice = await ctx.ui.select("Controlled real TUI choice", ["Alpha", "Beta"], { signal });
      return { content: [{ type: "text", text: choice === undefined ? "cancelled" : `selected:${choice}` }], details: { choice: choice ?? null } };
    } });
}
