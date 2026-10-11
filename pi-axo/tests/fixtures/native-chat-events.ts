// Rust-owned fixture progress only. This public observer is not shipped by Axo
// and never supplies run/binding authority or writes a canonical transcript.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { writeFileSync } from "node:fs";
import { join } from "node:path";

export default function fixture(pi: ExtensionAPI) {
  pi.on("message_update", (event, ctx) => {
    const update = event.assistantMessageEvent;
    if (update.type !== "text_delta") return;
    const filename = update.delta === "native-stream-started-5" ? "native-provider-stream-5"
      : update.delta === "native-stream-started-6" ? "native-provider-stream-6" : undefined;
    if (filename === undefined) return;
    writeFileSync(join(ctx.cwd, filename), "started", { mode: 0o600 });
  });
}
