import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { test } from "node:test";
import { mockDictation } from "./dictation-fixture.mjs";
import { chromePath, hostId, listed, record, sid, startApp, startCloud } from "./fake-cloud.mjs";

test("web dictation previews stay provisional, even with an inference in flight at Stop", {
  skip: !existsSync(chromePath) && "Set CHROME_PATH to a Chrome executable",
  timeout: 45_000,
}, async () => {
  const a = sid(1), b = sid(2);
  const cloud = await startCloud(new Map([
    [a, [record(1, { role: "user", content: "History A" })]],
    [b, [record(1, { role: "user", content: "History B" })]],
  ]), [listed(a, "Preview origin", 1), listed(b, "Other chat", 1)]);
  const app = await startApp(cloud);
  try {
    const page = await app.browser.newPage();
    await page.addInitScript(mockDictation, { text: "final words", previewText: "unreliable excerpt" });
    await page.goto(`${app.appUrl}/__tests__/chat/${hostId}/${a}`);
    await page.getByText("History A").waitFor();
    const box = page.getByRole("textbox", { name: "Message" });
    const talk = page.getByRole("button", { name: "Talk", exact: true });
    const listening = page.getByRole("group", { name: "Listening" });
    const choose = name => page.getByRole("navigation", { name: "Chats" }).getByText(name, { exact: true }).click();
    const draftIs = text => page.waitForFunction(expected =>
      document.querySelector('textarea[aria-label="Message"]')?.value === expected, text);
    const waitForPreview = n => page.waitForFunction(count => window.dictationFixture.previews === count, n);
    const releasePreview = () => page.evaluate(() => window.dictationFixture.releasePreview());

    await box.fill("Draft A");
    await talk.click();
    await waitForPreview(1);
    await releasePreview();
    await listening.getByText("unreliable excerpt", { exact: true }).waitFor();
    assert.equal(cloud.prompts.length, 0);
    await listening.getByRole("button", { name: "Cancel" }).click();
    await draftIs("Draft A");

    await talk.click();
    await waitForPreview(2);
    await listening.getByRole("button", { name: "Send", exact: true }).click();
    await listening.getByText("Transcribing on this device…").waitFor();
    await choose("Other chat");
    await draftIs("");
    assert.equal(await page.evaluate(() => window.dictationFixture.inferences), 0, "final waits only for the existing call");
    await releasePreview();
    await page.waitForFunction(() => window.dictationFixture.inferences === 1);
    assert.equal(await page.evaluate(() => window.dictationFixture.previews), 2, "no new preview on Stop/Send flush");
    await draftIs("");
    await choose("Preview origin");
    await draftIs("Draft A final words");
    assert.equal(await page.getByText("unreliable excerpt", { exact: true }).count(), 0);
    assert.equal(cloud.prompts.length, 0, "leaving the origin disarms Send");
  } finally {
    await app.close();
  }
});
