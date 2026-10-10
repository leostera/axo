import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

/** Controlled local model/tools only. Pi's actual loop, delivery and persistence are unchanged. */
export default function fixture(pi: ExtensionAPI) {
  pi.on("input", event => event.text === "CONSUME" ? { action: "handled" } : undefined);
  pi.registerProvider("axo-pi-test", {
    baseUrl: process.env.AXO_TEST_MODEL_URL!, apiKey: "local-fixture-only", api: "openai-completions",
    models: [{ id: "fixture", name: "Pi integration fixture", reasoning: false, input: ["text"],
      contextWindow: 32000, maxTokens: 1000, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  });
  pi.registerTool({ name: "fixture_ask", label: "Fixture question", description: "Ask a controlled choice", parameters: Type.Object({}),
    async execute(_id, _params, _signal, _onUpdate, ctx) {
      const choice = await ctx.ui.select("Controlled choice", ["Alpha", "Beta"]);
      return { content: [{ type: "text", text: choice === undefined ? "cancelled" : `selected:${choice}` }], details: { choice: choice ?? null } };
    },
  });
}
