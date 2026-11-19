import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { test } from "node:test";
import { chromePath, hostId, listed, sid, startApp, startCloud } from "./fake-cloud.mjs";

test("composer: host, actual agent, model and thinking stay separate on one toolbar without sending", {
  skip: !existsSync(chromePath) && "Set CHROME_PATH", timeout: 90_000,
}, async () => {
  const id = sid(1);
  const session = listed(id, "Composer controls", 1);
  session.metadata.agent = "codex";
  session.metadata.pi = { model: { provider: "openai", id: "test-model", name: "A deliberately long model name" }, thinkingLevel: "medium" };
  const models = [{ ...session.metadata.pi.model, thinkingLevels: ["off", "medium", "high"] }];
  const cloud = await startCloud(new Map([[id, []]]), [session], { models });
  let app;
  try {
    app = await startApp(cloud);
    const page = await app.browser.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`${app.appUrl}/__tests__/chat/${hostId}/${id}`, { waitUntil: "networkidle" });
    const field = page.getByRole("textbox", { name: "Message", exact: true });
    await field.waitFor({ timeout: 10_000 }).catch(async error => { throw new Error(`${error.message}; page errors: ${JSON.stringify(errors)}; body: ${(await page.locator("body").innerText()).slice(0, 1200)}`); });
    await field.fill("Keep this unsent");
    for (const width of [1100, 768, 390, 320]) {
      await page.setViewportSize({ width, height: 844 });
      const controls = [
        page.locator(".composer-toolbar .add-button"),
        page.getByRole("button", { name: "Host: Mac", exact: true }),
        page.getByLabel("Agent: Codex", { exact: true }),
        page.getByRole("button", { name: "Model: A deliberately long model name", exact: true }),
        page.getByRole("button", { name: "Thinking: Medium", exact: true }),
        page.locator(".composer-mic"),
        page.getByRole("button", { name: "Send", exact: true }),
      ];
      const boxes = await Promise.all(controls.map(control => control.boundingBox()));
      for (let i = 0; i < boxes.length; i++) {
        assert.ok(boxes[i] && boxes[i].width > 0);
        assert.ok(boxes[i].x >= 0 && boxes[i].x + boxes[i].width <= width + 1, JSON.stringify({ width, boxes }));
        if (i) {
          assert.ok(boxes[i].x >= boxes[i - 1].x + boxes[i - 1].width - 1, "host → agent → model → thinking");
          assert.ok(Math.abs(boxes[i].y + boxes[i].height / 2 - boxes[0].y - boxes[0].height / 2) < 2, "one line");
        }
      }
      const modelText = await page.locator(".model-picker > button:first-child .model-picker-label").boundingBox();
      assert.ok(modelText.width >= 20, "the model label must remain readable, not a zero-width pill");
      assert.equal(await page.locator(".host-picker.floating").count(), 0);
      await page.screenshot({ path: join(process.env.TEST_UNDECLARED_OUTPUTS_DIR ?? tmpdir(), `composer-pills-${width}.png`) });
    }
    await page.getByRole("button", { name: "Thinking: Medium", exact: true }).click();
    await page.getByRole("radio", { name: "High", exact: true }).check();
    await page.getByRole("button", { name: "Thinking: High", exact: true }).waitFor();
    assert.equal(await field.inputValue(), "Keep this unsent");
    assert.equal(cloud.prompts.length, 0);
    assert.equal(cloud.modelSets[0].thinkingLevel, "high");
    await page.keyboard.press("Escape");
    await page.getByRole("button", { name: "Host: Mac", exact: true }).click();
    await page.getByRole("menuitemradio", { name: /New chat on Mac/ }).click();
    assert.equal(cloud.prompts.length, 0, "changing destination never sends");
    await page.setViewportSize({ width: 1100, height: 844 });
    await page.getByText("Composer controls", { exact: true }).click();
    assert.equal(await field.inputValue(), "Keep this unsent", "the original Session retains its own draft");
    await page.getByLabel("Agent: Codex", { exact: true }).click();
    await page.getByRole("menuitem", { name: "New chat to choose another agent", exact: true }).click();
    assert.equal(cloud.prompts.length, 0);
    await page.getByText("Composer controls", { exact: true }).click();
    assert.equal(await field.inputValue(), "Keep this unsent");
  } finally {
    await app?.close();
  }
});
