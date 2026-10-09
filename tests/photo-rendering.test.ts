import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { getCapabilities, setCapabilities } from "@earendil-works/pi-tui";
import { renderPhoto } from "../bridge/photo-rendering";

test("a synthetic JPEG renders through Pi's PNG conversion and Kitty image component", async () => {
  const original = getCapabilities();
  try {
    setCapabilities({ ...original, images: "kitty" });
    const data = (await readFile(new URL("./fixtures/synthetic-photo.jpg", import.meta.url))).toString("base64");
    let ready!: () => void;
    const completed = new Promise<void>(resolve => { ready = resolve; });
    const component = renderPhoto({ type: "image", mimeType: "image/jpeg", data }, { fallbackColor: text => text }, ready);
    assert.ok(component.render(80).join("\n").includes("Preparing photo preview"));
    await completed;
    const output = component.render(80).join("\n");
    assert.ok(output.includes("\u001b_G"), "Must emit a Kitty image, not only a JPEG fallback label");
    assert.ok(!output.includes("preview unavailable"));
  } finally { setCapabilities(original); }
});
