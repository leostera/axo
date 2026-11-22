import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { test } from "node:test";
import { modelAssets, parakeetCacheName } from "../src/chat/parakeet-assets.ts";
import { mockDictation } from "./dictation-fixture.mjs";
import { chromePath, hostId, listed, record, sid, startApp, startCloud } from "./fake-cloud.mjs";

test("only a visible composer prewarms; Talk joins it, and cancellation drops stale results", {
  skip: !existsSync(chromePath) && "install Chrome or set CHROME_PATH",
  timeout: 30_000,
}, async () => {
  const first = sid(1);
  const second = sid(2);
  const cloud = await startCloud(new Map([
    [first, [record(1, { role: "user", content: "First chat" })]],
    [second, [record(1, { role: "user", content: "Second chat" })]],
  ]), [listed(first, "First", 1), listed(second, "Second", 1)]);
  const app = await startApp(cloud);
  try {
    const page = await app.browser.newPage({ viewport: { width: 1440, height: 960 } });
    await page.goto(`${app.appUrl}/`, { waitUntil: "networkidle" });
    await page.evaluate(async ({ name, tokenizer }) => {
      const cache = await caches.open(name);
      await cache.put(tokenizer, new Response("mock tokenizer"));
    }, { name: parakeetCacheName, tokenizer: modelAssets.tokenizer.url });
    await page.addInitScript(mockDictation, { text: "must not land in the next chat", holdPrepare: true });
    await page.addInitScript(() => {
      window.testVisibility = "hidden";
      Object.defineProperty(document, "visibilityState", { get: () => window.testVisibility });
    });
    const setVisibility = visibility => page.evaluate(value => {
      window.testVisibility = value;
      document.dispatchEvent(new Event("visibilitychange"));
    }, visibility);
    const prepares = count => page.waitForFunction(n => window.dictationFixture.prepares.length === n, count);
    const release = index => page.evaluate(i => window.dictationFixture.pendingPrepares[i](), index);
    const state = () => page.evaluate(() => {
      const { prepares, terminated, micCalls } = window.dictationFixture;
      return { prepares, terminated, micCalls };
    });
    const talk = page.getByRole("button", { name: "Talk" });
    const cancel = page.getByRole("button", { name: "Cancel", exact: true });
    const listening = page.getByRole("group", { name: "Listening" });

    await page.goto(`${app.appUrl}/__tests__/chat/${hostId}/${first}`, { waitUntil: "networkidle" });
    await talk.waitFor();
    assert.deepEqual(await state(), { prepares: [], terminated: 0, micCalls: 0 });

    await setVisibility("visible");
    await prepares(1);
    assert.deepEqual(await state(), { prepares: [false], terminated: 0, micCalls: 0 });
    assert.equal(await cancel.count(), 0, "no status UI for speculative work");
    await setVisibility("hidden");
    assert.deepEqual(await state(), { prepares: [false], terminated: 1, micCalls: 0 });

    await setVisibility("visible");
    await prepares(2);
    await talk.click();
    await page.getByText("Loading on-device dictation…").waitFor();
    await setVisibility("hidden");
    assert.deepEqual(await state(), { prepares: [false, false], terminated: 1, micCalls: 0 });
    await cancel.click();
    await release(1);
    assert.deepEqual(await state(), { prepares: [false, false], terminated: 2, micCalls: 0 });
    await talk.waitFor();

    await setVisibility("visible");
    await prepares(3);
    await talk.click();
    await page.getByRole("navigation", { name: "Chats" }).getByRole("button", { name: /^Second/ }).click();
    await prepares(4);
    await release(2);
    assert.deepEqual(await state(), { prepares: [false, false, false, false], terminated: 3, micCalls: 0 });
    await page.setViewportSize({ width: 700, height: 960 });
    await page.getByRole("button", { name: "Chats menu" }).click();
    await release(3);
    assert.deepEqual(await state(), { prepares: [false, false, false, false], terminated: 4, micCalls: 0 });
    await page.getByRole("button", { name: "Conversation", exact: true }).click();
    await prepares(5);
    await talk.click();
    await release(4);
    await listening.waitFor();
    assert.deepEqual(await state(), { prepares: [false, false, false, false, false], terminated: 4, micCalls: 1 });

    // Neither speculative abort nor stacking the composer away should cancel captured audio.
    await page.evaluate(() => { window.dictationFixture.hold = true; });
    await listening.getByRole("button", { name: "Stop", exact: true }).click();
    await page.waitForFunction(() => window.dictationFixture.inferences === 1);
    await setVisibility("hidden");
    await page.getByRole("button", { name: "Chats menu" }).click();
    await page.evaluate(() => window.dictationFixture.release());
    await setVisibility("visible");
    await page.getByRole("button", { name: "Conversation", exact: true }).click();
    await page.waitForFunction(() => document.querySelector('textarea[aria-label="Message"]')?.value === "must not land in the next chat");
    assert.deepEqual(await state(), { prepares: [false, false, false, false, false], terminated: 4, micCalls: 1 });
    assert.equal(cloud.prompts.length, 0);
  } finally {
    await app.close();
  }
});
