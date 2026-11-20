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
    const page = await app.browser.newPage({ reducedMotion: "reduce" });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`${app.appUrl}/__tests__/chat/${hostId}/${id}`, { waitUntil: "networkidle" });
    const field = page.getByRole("textbox", { name: "Message", exact: true });
    await field.waitFor({ timeout: 10_000 }).catch(async error => { throw new Error(`${error.message}; page errors: ${JSON.stringify(errors)}; body: ${(await page.locator("body").innerText()).slice(0, 1200)}`); });
    await field.fill("Keep this unsent");
    const hostBadge = page.getByRole("img", { name: "Host: Mac", exact: true });
    const agentBadge = page.getByRole("img", { name: "Agent: Codex", exact: true });
    assert.equal(await hostBadge.locator("svg[data-icon]").count(), 1, "the host badge keeps its machine icon");
    assert.equal(await page.getByRole("button", { name: /^(Host|Agent):/ }).count(), 0);
    for (const width of [1100, 768, 390, 320]) {
      await page.setViewportSize({ width, height: 844 });
      const controls = [
        page.locator(".composer-toolbar .add-button"),
        hostBadge,
        agentBadge,
        page.getByRole("button", { name: "Model: A deliberately long model name", exact: true }),
        page.getByRole("button", { name: "Thinking: Medium", exact: true }),
        page.locator(".composer-mic"),
        page.getByRole("button", { name: "Send", exact: true }),
      ];
      const elements = await Promise.all(controls.map(control => control.elementHandle()));
      const { boxes, toolbar, pills } = await page.evaluate(elements => {
        const frame = element => element.getBoundingClientRect().toJSON();
        return {
          boxes: elements.map(frame),
          toolbar: frame(document.querySelector(".composer-toolbar")),
          pills: elements.slice(1, 5).map(element => {
            const style = getComputedStyle(element);
            const height = frame(element).height;
            const fillHeight = height - parseFloat(style.borderTopWidth) - parseFloat(style.borderBottomWidth);
            return { height, fillHeight, clip: style.backgroundClip };
          }),
        };
      }, elements);
      await Promise.all(elements.map(element => element.dispose()));
      for (let i = 0; i < boxes.length; i++) {
        assert.ok(boxes[i] && boxes[i].width > 0);
        assert.ok(boxes[i].x >= 0 && boxes[i].x + boxes[i].width <= width + 1, JSON.stringify({ width, boxes }));
        if (i) {
          assert.ok(boxes[i].x >= boxes[i - 1].x + boxes[i - 1].width - 1, "host → agent → model → thinking");
          assert.ok(Math.abs(boxes[i].y + boxes[i].height / 2 - boxes[0].y - boxes[0].height / 2) < 2, "one line");
        }
      }
      for (const pill of pills) assert.deepEqual(pill, { height: 36, fillHeight: 30, clip: "padding-box" });
      assert.ok(Math.abs(boxes[0].x - toolbar.x) <= 1, `Add hugs the left edge at ${width}px: ${boxes[0].x} vs ${toolbar.x}`);
      assert.ok(Math.abs(boxes.at(-1).x + boxes.at(-1).width - toolbar.x - toolbar.width) <= 1, "Send hugs the right edge");
      if (width >= 768) assert.ok(boxes[1].x - (boxes[0].x + boxes[0].width) > 12, "spare space belongs between Add and Host");
      assert.ok(boxes[5].x - (boxes[4].x + boxes[4].width) <= 6, "Thinking stays beside Mic");
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
    await hostBadge.click();
    await agentBadge.click();
    assert.equal(await page.getByRole("menu", { name: /Start on|Session agent|Coding agents/ }).count(), 0);
    await hostBadge.waitFor();
    await agentBadge.waitFor();
    assert.equal(cloud.prompts.length, 0);
    assert.equal(await field.inputValue(), "Keep this unsent", "badges do not move or send the draft");

    await page.setViewportSize({ width: 1100, height: 844 });
    await page.getByRole("button", { name: "New chat", exact: true }).click();
    await page.getByRole("button", { name: "Model: Host default", exact: true }).click();
    const model = page.getByRole("option", { name: /A deliberately long model name/ });
    await model.click({ timeout: 5_000 }).catch(async error => {
      throw new Error(`${error.message}; toolbar: ${await page.locator(".composer-toolbar").innerText()}; page errors: ${JSON.stringify(errors)}`);
    });
    await page.getByRole("button", { name: "Model: A deliberately long model name", exact: true }).waitFor();
    assert.equal(cloud.modelSets.length, 1, "draft choice never changes a running model");
    assert.equal(cloud.prompts.length, 0, "draft catalog does not send");
  } finally {
    await app?.close();
  }
});
