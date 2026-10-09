import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { registerSessionTitles } from "../../bridge/session-title";

/** Title-only real-loader fixture: no relay connection or paid provider. */
export default function sessionTitles(pi: ExtensionAPI) {
  pi.registerProvider("axo-title-parent", {
    baseUrl: process.env.AXO_TEST_MODEL_URL!, apiKey: "local-test-only", api: "openai-completions",
    models: ["fixture", "fixture-mini"].map(id => ({ id, name: id, reasoning: false, input: ["text" as const],
      contextWindow: 32_000, maxTokens: 1000, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } })),
  });
  registerSessionTitles(pi);
}
