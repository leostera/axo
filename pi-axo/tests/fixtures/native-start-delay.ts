// Public vanilla-Pi extension loaded only by the Rust-owned native fixture.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { writeFileSync } from "node:fs";
import { join } from "node:path";

export default function fixture(pi: ExtensionAPI) {
  // No model request is made by this fixture. This metadata keeps startup independent
  // of the operator's real provider credentials in the disposable HOME.
  pi.registerProvider("axo-native-fixture", {
    baseUrl: "http://127.0.0.1:1", apiKey: "unused-owned-fixture", api: "openai-completions",
    models: [{ id: "fixture", name: "Native workbench fixture", reasoning: false,
      input: ["text"], contextWindow: 32000, maxTokens: 1000,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  });
  pi.on("session_start", async (_event, ctx) => {
    writeFileSync(join(ctx.cwd, "native-pi-starting"), "starting", { mode: 0o600 });
    await new Promise(resolve => setTimeout(resolve, 3000));
  });
}
