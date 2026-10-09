import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** Local deterministic test server only; never contacts a paid provider. */
export default function testProvider(pi: ExtensionAPI) {
  pi.registerProvider("axo-test", {
    baseUrl: process.env.AXO_TEST_MODEL_URL!, apiKey: "local-test-only", api: "openai-completions",
    models: [{ id: "fixture", name: "Axo fixture", reasoning: false, input: ["text", "image"],
      contextWindow: 32_000, maxTokens: 1000, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  });
}
