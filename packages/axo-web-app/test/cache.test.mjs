import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { test } from "node:test";
import { chromePath, hostId, listed, record, sid, startApp, startCloud } from "./fake-cloud.mjs";

test("refresh paints cached chats and drafts before the cloud replies; focus follows readiness, not reconnects", {
  skip: !existsSync(chromePath) && "Set CHROME_PATH to run the browser test", timeout: 60_000,
}, async () => {
  const sessionId = sid(1);
  const transcripts = new Map([[sessionId, [record(1, { role: "user", content: "Cached conversation" })]]]);
  const cloud = await startCloud(transcripts, [listed(sessionId, "Cached chat", 1)]);
  let app;
  try {
    app = await startApp(cloud);
    const context = await app.browser.newContext({ viewport: { width: 1280, height: 900 } });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`${app.appUrl}/__tests__/chat/${hostId}/${sessionId}`, { waitUntil: "domcontentloaded" });
    const field = page.getByRole("textbox", { name: "Message", exact: true });
    await page.getByText("Cached conversation", { exact: true }).waitFor();
    await page.waitForFunction(() => document.activeElement?.getAttribute("aria-label") === "Message");
    await field.fill("Unsent draft survives refresh");
    // No sleep for the debounce: pagehide must flush the last keystroke itself.
    cloud.pause();
    await page.reload({ waitUntil: "domcontentloaded" });
    await page.getByText("Cached conversation", { exact: true }).waitFor();
    assert.equal(await field.inputValue(), "Unsent draft survives refresh");
    assert.equal(await field.isDisabled(), true);
    assert.ok((await page.locator(".chat-list").textContent()).includes("Cached chat"));
    assert.ok(page.url().endsWith(`/${hostId}/${sessionId}`));
    const screenshot = join(process.env.TEST_UNDECLARED_OUTPUTS_DIR ?? tmpdir(), "axo-web-cache.png");
    await page.screenshot({ path: screenshot });
    console.log(`Cached conversation screenshot: ${screenshot}`);
    transcripts.set(sessionId, [record(1, { role: "user", content: "Fresh authoritative conversation" })]);
    cloud.resume();
    await page.getByText("Fresh authoritative conversation", { exact: true }).waitFor();
    assert.equal(await page.getByText("Cached conversation", { exact: true }).count(), 0);
    await page.waitForFunction(() => document.activeElement?.getAttribute("aria-label") === "Message");
    assert.equal(await field.isEnabled(), true);
    assert.equal(await field.inputValue(), "Unsent draft survives refresh");
    // Becoming ready must not take focus away from a search opened while reconnecting.
    cloud.pause();
    await page.reload({ waitUntil: "domcontentloaded" });
    await page.getByText("Fresh authoritative conversation", { exact: true }).waitFor();
    await page.getByRole("button", { name: "Search chats", exact: true }).click();
    await page.waitForFunction(() => document.activeElement?.getAttribute("aria-label") === "Search chats");
    cloud.resume();
    await page.waitForFunction(() => !document.querySelector("textarea[aria-label=Message]")?.disabled);
    assert.equal(await page.getByRole("textbox", { name: "Search chats", exact: true }).evaluate(element => document.activeElement === element), true);
    // A sign-out/storage clear in a second tab must stop this tab repopulating the cache.
    const second = await page.context().newPage();
    await second.goto(`${app.appUrl}/__tests__/chat/${hostId}/${sessionId}`, { waitUntil: "domcontentloaded" });
    await second.getByText("Fresh authoritative conversation", { exact: true }).waitFor();
    const key = "axo.chats.v1.fixture-browser-account";
    await page.waitForFunction(key => localStorage.getItem(key) !== null, key);
    await second.getByRole("button", { name: "Settings", exact: true }).click();
    await second.getByRole("button", { name: "Sign out", exact: true }).click();
    await page.waitForTimeout(100); // Let the cross-document storage event run.
    await page.getByRole("button", { name: "Close Search", exact: true }).click();
    await field.fill("Typing after another tab signed out");
    await page.waitForTimeout(400); // Longer than the persistence debounce.
    assert.equal(await page.evaluate(key => localStorage.getItem(key), key), null);
    await second.close();
    assert.deepEqual(errors, []);
  } finally { await app?.close(); }
});
