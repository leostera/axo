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
    await page.getByRole("button", { name: "Thinking: Medium", exact: true }).click();
    const dialog = page.locator(".model-menu[role=dialog]");
    await dialog.waitFor();
    await dialog.getByRole("radio", { name: "Medium", exact: true }).waitFor({ timeout: 5000 });
    assert.equal(await dialog.getByRole("option").count(), 0, "the model catalog does not push thinking down the popup");
    await page.screenshot({ path: output("web-polish-model-settings.png") });
    assert.equal(await dialog.getByRole("button", { name: "Choose model" }).count(), 0);
    await page.getByRole("button", { name: /^Model:/ }).click();
    const search = dialog.getByRole("combobox", { name: "Search models" });
    await search.waitFor();
    assert.equal(await dialog.getByRole("option").count(), 300);
    const bounds = await dialog.boundingBox();
    assert.ok(bounds.height < 500 && bounds.x >= 0 && bounds.x + bounds.width <= 1101);
    await search.fill("PROVIDER-B 242");
    assert.equal(await dialog.getByRole("option").count(), 1);
    await search.press("Enter");
    await page.getByRole("button", { name: "Model: Model 242", exact: true }).waitFor();
    assert.equal(await field.inputValue(), "**Pending bold** and `pending code`");
    assert.equal(cloud.prompts.length, 0, "Enter in model search never sends the composer draft");
    assert.equal(cloud.modelSets.length, 1);
    assert.equal(cloud.modelSets[0].model.id, "model-242");
    assert.equal("thinkingLevel" in cloud.modelSets[0], false);
    await page.getByRole("button", { name: /^Thinking:/ }).click();
    const medium = dialog.getByRole("radio", { name: "Medium", exact: true });
    await medium.focus();
    await medium.press("ArrowRight");
    await page.getByRole("button", { name: "Thinking: High", exact: true }).waitFor();
    assert.equal(cloud.modelSets[1].thinkingLevel, "high");
    assert.equal("model" in cloud.modelSets[1], false, "thinking is a separate API selection");
    // Failure does not change the selected model or hide the error in a closed menu.
    cloud.rejectNextModelChange();
    await page.getByRole("button", { name: /^Model:/ }).click();
    await search.fill("model-241");
    await search.press("Enter");
    await dialog.getByRole("alert").waitFor();
    assert.ok((await dialog.getByRole("alert").textContent()).includes("not signed in"));
    await search.press("Escape");
    await page.keyboard.press("Escape");
    await dialog.waitFor({ state: "detached" });
    // Both modes remain inside a phone viewport, including the long-catalog search page.
    await page.setViewportSize({ width: 390, height: 844 });
    await page.getByRole("button", { name: /^Model:/ }).click();
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

test("history never animates on load or cache refresh, but incoming replies still do", browserOptions, async () => {
  const sessionId = sid(1);
  const cloud = await startCloud(new Map([[sessionId, [record(1, { role: "user", content: "Old question" }), record(2, { role: "assistant", timestamp: 2, content: "Old answer" })]]]), [listed(sessionId, "History", 2)]);
  let app;
  try {
    app = await startApp(cloud);
    const context = await app.browser.newContext({ viewport: { width: 1100, height: 800 } });
    await context.addInitScript(() => {
      window.__historyAnimations = [];
      new MutationObserver(() => {
        if (document.querySelector(".word-in, .message-enter")) window.__historyAnimations.push("animated message");
      }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ["class"] });
    });
    const page = await context.newPage();
    const url = `${app.appUrl}/__tests__/chat/${hostId}/${sessionId}`;
    await page.goto(url, { waitUntil: "networkidle" });
    assert.deepEqual(await page.evaluate(() => window.__historyAnimations), []);
    await page.evaluate(() => window.dispatchEvent(new Event("pagehide")));
    await page.close();
    // Exactly one missed reply defeats the old batch-size heuristic. This is history, not incoming.
    const missed = "A past reply written while this browser was closed. ".repeat(40);
    cloud.write(sessionId, { role: "assistant", timestamp: 3, content: missed });
    const restored = await context.newPage();
    await restored.goto(url, { waitUntil: "networkidle" });
    await restored.getByText(missed.trim(), { exact: true }).waitFor();
    assert.deepEqual(await restored.evaluate(() => window.__historyAnimations), [], "cached-to-live replacement never mounts animated words or entry classes");
    cloud.status(sessionId, "working");
    cloud.progress(sessionId, { message: { role: "assistant", timestamp: Date.now(), content: [{ type: "text", text: "An actually incoming reply with new words appearing now" }] } });
    await restored.waitForFunction(() => window.__historyAnimations.length > 0);
    assert.ok(await restored.locator(".word-in").count() > 0, "incoming words retain their animation");
    await context.close();
  } finally { await app?.close(); }
});

test("bracket navigation holds the visible order while opening unread sessions marks them read", browserOptions, async () => {
  const now = Math.floor(Date.now() / 1000);
  const sessions = ["A", "B", "C", "D"].map((name, index) => {
    const row = listed(sid(index + 1), name, 1);
    row.metadata.lastMessageAt = now - 600 - index;
    return row;
  });
  const cloud = await startCloud(new Map(sessions.map(row => [row.sessionId, [record(1, { role: "user", content: row.metadata.name })]])), sessions);
  let app;
  try {
    app = await startApp(cloud);
    const page = await app.browser.newPage({ viewport: { width: 1100, height: 800 } });
    await page.addInitScript(() => localStorage.setItem("sidebar.seenSessionsBaseline.v1", "0"));
    await page.goto(`${app.appUrl}/__tests__/chat/${hostId}/${sid(4)}`, { waitUntil: "networkidle" });
    const names = () => page.locator(".chat-row-name").allTextContents();
    const order = await names();
    assert.deepEqual(order, ["A", "B", "C", "D"], "old sessions stay Earlier even while unread");
    assert.equal(await page.locator('.chat-section[aria-label="Earlier"] .chat-row-name.unseen').count(), 3);
    assert.equal(await page.locator('.chat-section[aria-label="Active"]').count(), 0);
    for (const name of ["C", "B", "A"]) {
      await page.keyboard.press("Meta+BracketLeft");
      await page.waitForFunction(name => {
        const selected = document.querySelector('.chat-row[aria-current="page"] .chat-row-name');
        return selected?.textContent === name && !selected.classList.contains("unseen");
      }, name);
      assert.deepEqual(await names(), order, "reading a session must not move the navigation targets");
    }
    await page.keyboard.press("Meta+BracketLeft");
    assert.equal(await page.locator('.chat-row[aria-current="page"] .chat-row-name').textContent(), "A");
    // Leaving keyboard navigation releases the hold and normal grouping resumes.
    await page.getByRole("textbox", { name: "Message", exact: true }).click();
    await page.waitForFunction(() => document.querySelectorAll(".chat-section").length === 1);
  } finally { await app?.close(); }
});

test("an Active chat stays Active while viewed but opening Earlier does not promote it", browserOptions, async () => {
  const now = Math.floor(Date.now() / 1000);
  const sessions = ["Viewed", "Other"].map((name, index) => {
    const row = listed(sid(index + 1), name, 1);
    row.metadata.lastMessageAt = now - 5;
    return row;
  });
  const cloud = await startCloud(new Map(sessions.map(row => [row.sessionId, [record(1, { role: "user", content: row.metadata.name })]])), sessions);
  let app;
  try {
    app = await startApp(cloud);
    const page = await app.browser.newPage({ viewport: { width: 1100, height: 800 } });
    await page.clock.install({ time: new Date(now * 1000) });
    await page.goto(`${app.appUrl}/__tests__/chat/${hostId}/${sid(1)}`, { waitUntil: "networkidle" });
    assert.equal(await page.locator('.chat-section[aria-label="Active"] .chat-row-name').count(), 2);
    await page.clock.fastForward(4 * 60_000);
    await page.waitForFunction(() => document.querySelectorAll('.chat-section[aria-label="Earlier"] .chat-row-name').length === 1);
    assert.deepEqual(await page.locator('.chat-section[aria-label="Active"] .chat-row-name').allTextContents(), ["Viewed"]);
    await page.locator(".chat-row-name").filter({ hasText: /^Other$/ }).click();
    await page.getByRole("textbox", { name: "Message", exact: true }).click();
    await page.waitForFunction(() => document.querySelectorAll('.chat-section[aria-label="Earlier"] .chat-row-name').length === 2);
    assert.equal(await page.locator('.chat-section[aria-label="Active"]').count(), 0);
  } finally { await app?.close(); }
});

test("mark all read clears badges without moving unread Earlier chats on desktop and phone", browserOptions, async () => {
  const now = Math.floor(Date.now() / 1000);
  const sessions = ["A", "B", "C"].map((name, index) => {
    const row = listed(sid(index + 1), name, 1);
    row.metadata.lastMessageAt = now - 600 - index;
    return row;
  });
  const cloud = await startCloud(new Map(sessions.map(row => [row.sessionId, [record(1, { role: "user", content: row.metadata.name })]])), sessions);
  let app;
  try {
    app = await startApp(cloud);
    for (const viewport of [{ width: 1100, height: 800 }, { width: 390, height: 844 }]) {
      const page = await app.browser.newPage({ viewport });
      await page.addInitScript(() => {
        localStorage.setItem("sidebar.seenSessionsBaseline.v1", "0");
        localStorage.setItem("sidebar.grouping.v1", JSON.stringify({ unseenStayActive: true }));
      });
      await page.goto(`${app.appUrl}/__tests__/chat/${hostId}/${sid(1)}`, { waitUntil: "networkidle" });
      if (viewport.width < 600) await page.getByRole("button", { name: "Chats menu" }).click();
      const earlier = page.locator('.chat-section[aria-label="Earlier"]');
      assert.equal(await earlier.locator(".chat-row-name.unseen").count(), 2);
      assert.equal(await page.locator('.chat-section[aria-label="Active"]').count(), 0);
      const order = await earlier.locator(".chat-row-name").allTextContents();
      await page.getByRole("button", { name: "Mark all read", exact: true }).click();
      await page.waitForFunction(() => !document.querySelector(".chat-row-name.unseen"));
      assert.deepEqual(await earlier.locator(".chat-row-name").allTextContents(), order);
      assert.equal(await page.locator('.chat-section[aria-label="Active"]').count(), 0);
      await page.close();
    }
  } finally { await app?.close(); }
});

test("host icons distinguish platforms and retain them through cached reconnect", browserOptions, async () => {
  const base = { hostGeneration: sid(100), online: true, lastSeenAt: "2026-11-14T12:00:00.000Z" };
  const hosts = [
    { ...base, hostId, label: "Linux server", hostKind: "linux" },
    { ...base, hostId: sid(101), label: "Windows PC", hostKind: "windows" },
    { ...base, hostId: sid(102), label: "MacBook", hostKind: "macos", model: { identifier: "MacBookPro18,3" } },
    { ...base, hostId: sid(103), label: "Unknown computer", hostKind: "macos" },
  ];
  const cloud = await startCloud(new Map([[sid(1), [record(1, { role: "user", content: "Hello from Linux" })]]]), [listed(sid(1), "Icons", 1)], { hosts });
  let app;
  try {
    app = await startApp(cloud);
    const page = await app.browser.newPage({ viewport: { width: 1100, height: 800 } });
    await page.goto(`${app.appUrl}/__tests__/chat/${hostId}/${sid(1)}`, { waitUntil: "networkidle" });
    await page.locator('.host-picker [data-icon="linux"]').waitFor();
    await page.getByRole("button", { name: "Account and computers", exact: true }).click();
    for (const [label, icon] of [["Linux server", "linux"], ["Windows PC", "windows"], ["MacBook", "laptop"], ["Unknown computer", "desktop"]]) {
      assert.equal(await page.locator(".mac-row-wrap", { hasText: label }).locator(".mac-icon").getAttribute("data-icon"), icon);
    }
    for (const theme of ["light", "dark"]) {
      await page.evaluate(theme => { document.documentElement.dataset.appearance = theme; }, theme);
      await page.screenshot({ path: output(`web-host-icons-${theme}.png`) });
    }
    await page.evaluate(() => window.dispatchEvent(new Event("pagehide")));
    cloud.pause();
    await page.reload({ waitUntil: "domcontentloaded" });
    await page.locator('.host-picker [data-icon="linux"]').waitFor();
    await page.locator(".host-picker .mac-dot.offline").waitFor();
    cloud.resume();
    await page.locator(".host-picker .mac-dot.online").waitFor();
  } finally { await app?.close(); }
});
