import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { test } from "node:test";
import { chromePath, hostId, listed, record, sid, startApp, startCloud } from "./fake-cloud.mjs";
import { mockDictation } from "./dictation-fixture.mjs";

test("global inbox reaches both devices and Yes followed by voice Send never interrupts", {
  skip: !existsSync(chromePath) && "Chrome/Chromium required", timeout: 60_000,
}, async () => {
  const cloud = await startCloud(new Map([
    [sid(1), [record(1, { role: "user", content: "Original chat", timestamp: 1000 }), record(2, { role: "user", content: "One more", timestamp: 2000 })]],
    [sid(2), [record(1, { role: "user", content: "A different chat" })]],
  ]), [listed(sid(1), "Original", 2), listed(sid(2), "Different", 1)]);
  let app;
  try {
    app = await startApp(cloud);
    const pages = [];
    for (const [session, viewport] of [[sid(1), { width: 1180, height: 900 }], [sid(2), { width: 390, height: 844 }], [sid(1), { width: 1000, height: 800 }]]) {
      const page = await app.browser.newPage({ viewport });
      await page.addInitScript(() => {
        window.__notices = [];
        window.__permissionRequests = 0;
        class FakeNotification {
          static permission = "granted";
          static async requestPermission() { window.__permissionRequests++; return "granted"; }
          constructor(title, options) {
            this.entry = { title, ...options, closed: false, open: () => this.onclick?.() };
            window.__notices.push(this.entry);
          }
          close() { this.entry.closed = true; }
        }
        window.Notification = FakeNotification;
      });
      await page.addInitScript(mockDictation, { text: "These are my recorded words." });
      await page.goto(`${app.appUrl}/__tests__/chat/${hostId}/${session}`, { waitUntil: "networkidle" });
      pages.push(page);
    }
    const [desktop, phone, otherDevice] = pages;
    for (const [page, title] of [[desktop, "Original"], [phone, "Different"]]) {
      const heading = page.getByRole("heading", { level: 1, name: title, exact: true });
      await heading.waitFor();
      assert.ok((await heading.boundingBox()).width > 30, "the active chat title is visible, not screen-reader-only");
    }
    await desktop.getByText("One more", { exact: true }).waitFor();
    assert.equal(await desktop.locator(".user-message time:visible").count(), 1);
    const emptyBell = desktop.getByTestId("elicitation-bell");
    assert.equal(await emptyBell.isDisabled(), true);
    await emptyBell.evaluate(button => button.click());
    assert.equal(await desktop.getByRole("dialog", { name: "Requests", exact: true }).isVisible(), false);
    await desktop.getByRole("button", { name: "Settings", exact: true }).click();
    const settings = desktop.getByRole("dialog", { name: "Settings", exact: true });
    await settings.getByRole("heading", { name: "Notifications", exact: true }).waitFor();
    await settings.getByText("Desktop notifications", { exact: true }).waitFor();
    await settings.getByRole("button", { name: "Close Settings", exact: true }).click();
    await desktop.getByRole("button", { name: "Talk", exact: true }).click();
    await desktop.getByRole("group", { name: "Listening", exact: true }).waitFor();
    cloud.holdAnswers();
    const question = {
      id: "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f81", sessionId: sid(1), kind: "confirm", askedBy: "agent",
      message: "A private request to review (fixture).", createdAt: Date.now(), expiresAt: Date.now() + 300_000,
    };
    cloud.ask(question);
    cloud.ask(question); // replay is not another request or native notification
    for (const page of pages) {
      await page.waitForFunction(() => document.querySelector('[data-testid="elicitation-bell"]')?.getAttribute("aria-label") === "Requests, 1 pending");
      assert.equal(await page.locator('.chats-panel .panel-footer [data-testid="elicitation-bell"]').count(), 1);
      await page.waitForFunction(() => window.__notices.length === 1);
      assert.equal(await page.evaluate(() => window.__permissionRequests), 0);
      assert.ok(!(await page.evaluate(() => JSON.stringify(window.__notices))).includes("private request"));
      const colors = await page.getByTestId("elicitation-bell").evaluate(element => {
        const root = getComputedStyle(document.documentElement);
        const resolve = name => {
          const probe = document.createElement("span");
          probe.style.color = root.getPropertyValue(name);
          document.body.append(probe);
          const color = getComputedStyle(probe).color;
          probe.remove();
          return color;
        };
        return { bell: getComputedStyle(element).color, badge: getComputedStyle(element.querySelector(".elicitation-count")).backgroundColor,
          orange: resolve("--orange"), red: resolve("--red") };
      });
      assert.equal(colors.bell, colors.orange);
      assert.equal(colors.badge, colors.red);
    }
    // Sending from a second device before Yes cannot bypass the same-Session fence.
    await otherDevice.locator("textarea").fill("A detail from the other device");
    await otherDevice.getByRole("button", { name: "Send", exact: true }).click();
    await otherDevice.waitForFunction(() => !document.querySelector("textarea")?.disabled);
    assert.equal(cloud.prompts.length, 1);
    assert.notEqual(cloud.prompts[0].delivery, "interrupt");

    // No floating conversation bell. Notifications still open the global inbox while the
    // sidebar is hidden/inert, without changing this device's selected conversation.
    assert.equal(await phone.getByTestId("elicitation-bell").evaluate(element => Boolean(element.closest("[inert]"))), true);
    await phone.evaluate(() => window.__notices[0].open());
    const phoneInbox = phone.getByRole("dialog", { name: "Requests", exact: true });
    await phoneInbox.getByText(question.message, { exact: true }).waitFor();
    assert.ok(phone.url().endsWith(sid(2)));
    await phoneInbox.getByRole("button", { name: "Close requests" }).click();

    await phone.getByRole("button", { name: "Chats menu", exact: true }).click();
    const sidebarBell = phone.getByRole("navigation", { name: "Chats", exact: true }).getByTestId("elicitation-bell");
    await phone.waitForFunction(() => {
      const sidebar = document.querySelector(".chats-panel").getBoundingClientRect();
      const conversation = document.querySelector(".layer-conversation").getBoundingClientRect();
      return sidebar.left >= 0 && Math.abs(conversation.left - sidebar.right) < 1;
    });
    const placement = await sidebarBell.evaluate(element => {
      const bell = element.getBoundingClientRect();
      const footer = element.closest("footer").getBoundingClientRect();
      return { position: getComputedStyle(element).position, contained: bell.left >= footer.left && bell.right <= footer.right && bell.top >= footer.top && bell.bottom <= footer.bottom };
    });
    assert.equal(placement.position, "relative");
    assert.ok(placement.contained, "the bell belongs to the sidebar footer, not the conversation overlay");
    const output = process.env.TEST_UNDECLARED_OUTPUTS_DIR;
    if (output) {
      await phone.screenshot({ path: resolve(output, "web-requests-sidebar-phone.png") });
      await desktop.screenshot({ path: resolve(output, "web-requests-sidebar-desktop.png") });
    }
    await sidebarBell.click();
    await phoneInbox.getByText(question.message, { exact: true }).waitFor();
    if (output) await phone.screenshot({ path: resolve(output, "web-requests-phone.png") });

    const inline = desktop.getByTestId("transcript").getByRole("group", { name: "The agent asks you" });
    assert.equal(await inline.count(), 1, "a replay never duplicates the inline card");
    assert.equal(await phone.getByTestId("transcript").getByText(question.message).count(), 0, "other chats stay private");
    await inline.getByText("Approval required", { exact: true }).waitFor();
    await inline.getByRole("button", { name: "Yes", exact: true }).click();
    await phoneInbox.waitFor({ state: "hidden" });
    await inline.waitFor({ state: "hidden" });
    assert.equal(await desktop.getByTestId("elicitation-bell").isDisabled(), true);
    assert.equal(await phone.getByTestId("elicitation-bell").isDisabled(), true);
    await desktop.getByRole("group", { name: "Listening", exact: true }).waitFor();
    await desktop.getByRole("button", { name: "Send", exact: true }).click();
    await desktop.waitForFunction(() => document.querySelector("textarea")?.disabled);
    assert.equal(cloud.answers.length, 1);
    assert.equal(cloud.prompts.length, 1, "the voice Send waits for acknowledgment of Yes");
    cloud.releaseAnswers();
    await desktop.waitForFunction(() => !document.querySelector("textarea")?.disabled);
    assert.equal(cloud.prompts.length, 2);
    assert.equal(cloud.prompts[1].text, "These are my recorded words.");
    assert.notEqual(cloud.prompts[1].delivery, "interrupt");
    for (const page of pages) {
      await page.waitForFunction(() => window.__notices.every(notice => notice.closed));
      await page.waitForFunction(() => document.querySelector('[data-testid="elicitation-bell"]')?.getAttribute("aria-label") === "Requests, 0 pending");
    }
    cloud.ask(question); // a late replay after settlement must not resurrect the bell
    // A distinct request is an ordering fence: both replay and marker have now been processed.
    const marker = { ...question, id: "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f82", sessionId: sid(2), message: "A short-lived request.", createdAt: Date.now(), expiresAt: Date.now() + 2_000 };
    cloud.ask(marker);
    await phone.waitForFunction(() => !document.querySelector('[data-testid="elicitation-bell"]').disabled);
    await phone.getByTestId("elicitation-bell").click();
    await phoneInbox.getByText(marker.message, { exact: true }).waitFor();
    // Observe each device concurrently: waiting for one to expire before observing the next
    // would miss that next device's short-lived pending state.
    await Promise.all(pages.map(async page => {
      await page.waitForFunction(() => window.__notices.length === 2);
      await page.waitForFunction(() => document.querySelector('[data-testid="elicitation-bell"]')?.getAttribute("aria-label") === "Requests, 1 pending");
      await page.waitForFunction(() => document.querySelector('[data-testid="elicitation-bell"]')?.getAttribute("aria-label") === "Requests, 0 pending");
      await page.waitForFunction(() => window.__notices.every(notice => notice.closed));
    }));
  } finally {
    if (app) await app.close(); else { cloud.wss.close(); cloud.http.close(); }
  }
});
