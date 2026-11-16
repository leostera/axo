import assert from "node:assert/strict";
import { once } from "node:events";
import { existsSync } from "node:fs";
import { test } from "node:test";
import { chromePath, hostId, listed, record, sid, startApp, startCloud } from "./fake-cloud.mjs";

for (const [name, viewport] of [
  ["desktop", { width: 1180, height: 900 }],
  ["phone", { width: 390, height: 844 }],
]) test(`Jump skips 200 replies and fetches the unseen tail without animations (${name})`, {
  skip: !existsSync(chromePath) && "Chrome/Chromium required", timeout: 60_000,
}, async () => {
  const chat = sid(1);
  const history = Array.from({ length: 30 }, (_, i) => record(i + 1, { role: "user", content: `History ${i + 1}` }));
  const cloud = await startCloud(new Map([[chat, history]]), [listed(chat, "Jump", history.length)]);
  let app;
  try {
    app = await startApp(cloud);
    const page = await app.browser.newPage({ viewport });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`${app.appUrl}/__tests__/chat/${hostId}/${chat}`, { waitUntil: "networkidle" });
    await page.getByText("History 30", { exact: true }).waitFor();
    await page.getByTestId("transcript").evaluate(element => { element.scrollTop = 50; });
    for (let i = 0; i < 200; i++) cloud.write(chat, {
      role: "assistant", timestamp: 1_700_000_001_000 + i,
      content: [{ type: "text", text: `Backlog ${i}: ${"a reply waiting to be revealed ".repeat(60)}` }],
    });
    cloud.write(chat, { role: "user", content: "The local tail before fetching" });
    await page.getByRole("button", { name: "Jump to new message", exact: true }).waitFor();
    await page.waitForFunction(() => document.querySelector(".word-in"));
    cloud.pause();
    // Only a new read can discover these: they have not been broadcast to the browser.
    for (let i = 0; i < 10; i++) history.push(record(history.length + 1, {
      role: "assistant", timestamp: 1_700_000_002_000 + i,
      content: [{ type: "text", text: i === 9 ? "The fetched newest message" : `Unseen reply ${i}` }],
    }));
    const opened = once(cloud.http, "session-open");
    await page.getByRole("button", { name: "Jump to new message", exact: true }).click();
    const [request] = await opened;
    assert.equal(request.sessionId, chat);
    assert.ok(request.have, "fetch from the held cursor instead of discarding loaded history");
    // Even with the read deliberately blocked, local presentation must finish immediately.
    await page.getByText("The local tail before fetching", { exact: true }).waitFor();
    assert.equal(await page.locator(".word-in, .message-enter").count(), 0);
    cloud.resume();
    await page.getByText("The fetched newest message", { exact: true }).waitFor();
    cloud.progress(chat, { message: {
      role: "assistant", timestamp: 1_700_000_003_000,
      content: [{ type: "text", text: "New live words are fully visible too" }],
    } });
    await page.getByText("New live words are fully visible too", { exact: true }).waitFor();
    await page.waitForFunction(() => {
      const element = document.querySelector("[data-testid=transcript]");
      return element && element.scrollHeight - element.clientHeight - element.scrollTop < 2;
    });
    assert.equal(await page.locator(".word-in, .message-enter").count(), 0);
    assert.equal(cloud.prompts.length, 0);
    assert.deepEqual(errors, []);
  } finally {
    if (app) await app.close(); else { cloud.wss.close(); cloud.http.close(); }
  }
});
