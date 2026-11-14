import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { test } from "node:test";
import { chromePath, hostId, listed, record, sid, startApp, startCloud } from "./fake-cloud.mjs";

const browserOptions = { skip: !existsSync(chromePath) && "Set CHROME_PATH to run this browser test", timeout: 60_000 };
const output = name => join(process.env.TEST_UNDECLARED_OUTPUTS_DIR ?? tmpdir(), name);

test("web polish: user Markdown, contrasting Send and independent searchable model/thinking selections", browserOptions, async () => {
  const models = Array.from({ length: 300 }, (_, index) => ({ provider: index < 150 ? "provider-a" : "provider-b", id: `model-${index}`, name: `Model ${index}`, thinkingLevels: ["off", "low", "medium", "high", "xhigh"] }));
  const sessionId = sid(1);
  const session = listed(sessionId, "Polish", 1);
  session.metadata.pi = { model: { provider: models[0].provider, id: models[0].id, name: models[0].name }, thinkingLevel: "medium" };
  const markdown = "**User bold**, *emphasis*, `inline`, [docs](https://example.test) and [unsafe](javascript:alert)\n\n- item\n\n```ts\nconst answer = 42;\n```";
  const cloud = await startCloud(new Map([[sessionId, [record(1, { role: "user", content: markdown })]]]), [session], { models });
  let app;
  try {
    app = await startApp(cloud);
    const page = await app.browser.newPage({ viewport: { width: 1100, height: 800 } });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`${app.appUrl}/__tests__/chat/${hostId}/${sessionId}`, { waitUntil: "networkidle" });
    const bubble = page.locator(".user-bubble").first();
    assert.equal(await bubble.locator("strong").textContent(), "User bold");
    assert.equal(await bubble.locator("em").textContent(), "emphasis");
    assert.equal(await bubble.getByRole("link", { name: "docs" }).getAttribute("href"), "https://example.test");
    assert.equal(await bubble.locator('a[href^="javascript:"]').count(), 0);
    assert.ok((await bubble.locator("pre code").textContent()).includes("const answer = 42"));
    const field = page.getByRole("textbox", { name: "Message", exact: true });
    await field.fill("**Pending bold** and `pending code`");
    const send = page.getByRole("button", { name: "Send", exact: true });
    await page.waitForFunction(() => document.querySelector(".send-button.ready") && !document.querySelector(".send-button").disabled);
    for (const theme of ["light", "dark"]) {
      await page.evaluate(theme => { document.documentElement.dataset.appearance = theme; }, theme);
      await page.waitForFunction(theme => getComputedStyle(document.querySelector(".send-button.ready")).color === (theme === "dark" ? "rgb(0, 0, 0)" : "rgb(255, 255, 255)"), theme);
      const colors = await send.evaluate(button => {
        const style = getComputedStyle(button);
        return { foreground: style.color, background: style.backgroundColor, icon: getComputedStyle(button.querySelector("svg")).color };
      });
      assert.notEqual(colors.foreground, colors.background, `${theme}: Send arrow contrasts with its circle`);
      assert.equal(colors.icon, colors.foreground);
      assert.equal(colors.foreground, theme === "dark" ? "rgb(0, 0, 0)" : "rgb(255, 255, 255)");
      await page.screenshot({ path: output(`web-polish-${theme}.png`) });
    }
    await page.getByRole("button", { name: "Model: Model 0 · Medium", exact: true }).click();
    const dialog = page.getByRole("dialog", { name: "Model settings" });
    await dialog.waitFor();
    await dialog.getByRole("radio", { name: "Medium", exact: true }).waitFor({ timeout: 5000 });
    assert.equal(await dialog.getByRole("option").count(), 0, "the model catalog does not push thinking down the popup");
    await page.screenshot({ path: output("web-polish-model-settings.png") });
    await dialog.getByRole("button", { name: "Choose model", exact: true }).click();
    const search = dialog.getByRole("combobox", { name: "Search models" });
    await search.waitFor();
    assert.equal(await dialog.getByRole("option").count(), 300);
    const bounds = await dialog.boundingBox();
    assert.ok(bounds.height < 500 && bounds.x >= 0 && bounds.x + bounds.width <= 1101);
    await search.fill("PROVIDER-B 242");
    assert.equal(await dialog.getByRole("option").count(), 1);
    await search.press("Enter");
    await page.getByRole("button", { name: "Model: Model 242 · Medium", exact: true }).waitFor();
    assert.equal(await field.inputValue(), "**Pending bold** and `pending code`");
    assert.equal(cloud.prompts.length, 0, "Enter in model search never sends the composer draft");
    assert.equal(cloud.modelSets.length, 1);
    assert.equal(cloud.modelSets[0].model.id, "model-242");
    assert.equal("thinkingLevel" in cloud.modelSets[0], false);
    const medium = dialog.getByRole("radio", { name: "Medium", exact: true });
    await medium.focus();
    await medium.press("ArrowRight");
    await page.getByRole("button", { name: "Model: Model 242 · High", exact: true }).waitFor();
    assert.equal(cloud.modelSets[1].thinkingLevel, "high");
    assert.equal("model" in cloud.modelSets[1], false, "thinking is a separate API selection");
    // Failure does not change the selected model or hide the error in a closed menu.
    cloud.rejectNextModelChange();
    await dialog.getByRole("button", { name: "Choose model", exact: true }).click();
    await search.fill("model-241");
    await search.press("Enter");
    await dialog.getByRole("alert").waitFor();
    assert.ok((await dialog.getByRole("alert").textContent()).includes("not signed in"));
    await search.press("Escape");
    await page.keyboard.press("Escape");
    await dialog.waitFor({ state: "detached" });
    // Both modes remain inside a phone viewport, including the long-catalog search page.
    await page.setViewportSize({ width: 390, height: 844 });
    await page.getByRole("button", { name: "Model: Model 242 · High", exact: true }).click();
    await dialog.getByRole("button", { name: "Choose model", exact: true }).click();
    const mobileBounds = await dialog.boundingBox();
    assert.ok(mobileBounds.x >= 0 && mobileBounds.x + mobileBounds.width <= 391, JSON.stringify(mobileBounds));
    await page.screenshot({ path: output("web-polish-model-search-mobile.png") });
    await search.press("Escape");
    await page.keyboard.press("Escape");
    await send.click();
    const pending = page.getByTestId("pending-prompt");
    await pending.locator("strong").waitFor();
    assert.equal(await pending.locator("strong").textContent(), "Pending bold");
    assert.equal(await pending.locator("code").textContent(), "pending code");
    assert.deepEqual(errors, []);
  } finally { await app?.close(); }
});

test("web polish: bracket navigation follows the displayed pinned, held and collapsed sidebar order", browserOptions, async () => {
  const now = Math.floor(Date.now() / 1000);
  const sessions = ["Zeta", "Alpha", "Omega", "Beta", "Delta", "Pinned"].map((name, index) => {
    const row = listed(sid(index + 1), name, 1);
    row.metadata.lastMessageAt = now - (index < 2 ? index + 1 : 1000000 + index);
    return row;
  });
  const cloud = await startCloud(new Map(sessions.map(session => [session.sessionId, [record(1, { role: "user", content: session.metadata.name })]])), sessions);
  let app;
  try {
    app = await startApp(cloud);
    const page = await app.browser.newPage({ viewport: { width: 1100, height: 800 } });
    await page.goto(`${app.appUrl}/__tests__/chat/${hostId}/${sid(1)}`, { waitUntil: "networkidle" });
    await page.getByRole("heading", { name: "Zeta", exact: true }).waitFor();
    await page.getByRole("button", { name: "Pin Pinned", exact: true }).click();
    await page.mouse.move(900, 400);
    const rows = page.locator(".chat-row");
    const names = () => rows.locator(".chat-row-name").allTextContents();
    const selected = () => page.locator('.chat-row[aria-current="page"] .chat-row-name').textContent();
    let order = await names();
    assert.equal(order[0], "Pinned");
    await rows.first().click();
    // Holding the pointer holds the UI's order even when recency changes underneath it.
    await page.locator(".chat-list").hover();
    order = await names();
    cloud.activity(sid(4), now + 60);
    await page.waitForTimeout(80);
    assert.deepEqual(await names(), order);
    for (let index = 1; index < order.length; index++) {
      await page.keyboard.press("Meta+BracketRight");
      await page.waitForFunction(name => document.querySelector('.chat-row[aria-current="page"] .chat-row-name')?.textContent === name, order[index]);
      assert.equal(await selected(), order[index]);
    }
    await page.keyboard.press("Meta+BracketRight");
    assert.equal(await selected(), order.at(-1), "the last row does not wrap");
    for (let index = order.length - 2; index >= 0; index--) {
      await page.keyboard.press("Meta+BracketLeft");
      await page.waitForFunction(name => document.querySelector('.chat-row[aria-current="page"] .chat-row-name')?.textContent === name, order[index]);
    }
    await page.mouse.move(900, 400);
    await page.getByRole("button", { name: /^Earlier/ }).click();
    const collapsed = await names();
    assert.ok(collapsed.length < order.length);
    await rows.first().click();
    for (let index = 1; index < collapsed.length; index++) {
      await page.keyboard.press("Meta+BracketRight");
      await page.waitForFunction(name => document.querySelector('.chat-row[aria-current="page"] .chat-row-name')?.textContent === name, collapsed[index]);
    }
    await page.keyboard.press("Meta+BracketRight");
    assert.equal(await selected(), collapsed.at(-1), "folded chats are not keyboard targets");
    await page.getByRole("button", { name: "Search chats", exact: true }).click();
    const before = page.url();
    await page.keyboard.press("Meta+BracketLeft");
    assert.equal(page.url(), before, "session shortcuts never navigate underneath an open dialog");
    assert.equal(await page.getByRole("textbox", { name: "Search chats" }).evaluate(field => field === document.activeElement), true);
  } finally { await app?.close(); }
});
