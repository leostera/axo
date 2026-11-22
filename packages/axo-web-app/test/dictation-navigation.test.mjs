import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { test } from "node:test";
import { mockDictation } from "./dictation-fixture.mjs";
import { chromePath, hostId, listed, record, sid, startApp, startCloud } from "./fake-cloud.mjs";

test("delayed dictation returns to its original draft across conversation navigation", {
  skip: !existsSync(chromePath) && "Set CHROME_PATH to a Chrome executable",
  timeout: 45_000,
}, async () => {
  const a = sid(1), b = sid(2);
  const cloud = await startCloud(new Map([
    [a, [record(1, { role: "user", content: "History A" })]],
    [b, [record(1, { role: "user", content: "History B" })]],
  ]), [listed(a, "Dictation origin", 1), listed(b, "Other chat", 1)]);
  const app = await startApp(cloud);
  try {
    const page = await app.browser.newPage({ viewport: { width: 1200, height: 850 } });
    await page.addInitScript(mockDictation, { text: "dictated words" });
    await page.goto(`${app.appUrl}/__tests__/chat/${hostId}/${a}`);
    const box = page.getByRole("textbox", { name: "Message" });
    const talk = page.getByRole("button", { name: "Talk", exact: true });
    const listening = page.getByRole("group", { name: "Listening" });
    const choose = async name => {
      await page.getByRole("navigation", { name: "Chats" }).getByText(name, { exact: true }).click();
      await page.getByRole("heading", { name, exact: true }).waitFor();
    };
    const draftIs = text => page.waitForFunction(expected =>
      document.querySelector('textarea[aria-label="Message"]')?.value === expected, text, { timeout: 3_000 });
    let inferences = 0;
    const finish = async action => {
      await page.evaluate(() => { window.dictationFixture.hold = true; });
      await talk.click();
      await listening.getByRole("button", { name: action, exact: true }).click();
      await page.waitForFunction(n => window.dictationFixture.inferences === n, ++inferences);
    };
    const release = () => page.evaluate(() => window.dictationFixture.release());

    await page.getByText("History A", { exact: true }).waitFor();
    await box.fill("Draft A");
    await choose("Other chat");
    await box.fill("Draft B");
    await choose("Dictation origin");
    await finish("Stop");
    await choose("Other chat");
    await draftIs("Draft B");
    await choose("Dictation origin");
    await release();
    await draftIs("Draft A dictated words");
    assert.equal(cloud.prompts.length, 0);

    // Returning before completion doesn't re-arm Send after leaving its chat.
    await finish("Send");
    await choose("Other chat");
    await draftIs("Draft B");
    await choose("Dictation origin");
    await release();
    await draftIs("Draft A dictated words dictated words");
    assert.equal(cloud.prompts.length, 0);

    // A result can also arrive while a different chat is being edited.
    await finish("Send");
    await choose("Other chat");
    await box.fill("Edited B");
    await release();
    await draftIs("Edited B");
    await choose("Dictation origin");
    await draftIs("Draft A dictated words dictated words dictated words");
    assert.equal(cloud.prompts.length, 0);

    await finish("Send");
    await listening.getByRole("button", { name: "Cancel" }).click();
    await release();
    await draftIs("Draft A dictated words dictated words dictated words");
    assert.equal(cloud.prompts.length, 0);

    await page.getByRole("button", { name: "New chat", exact: true }).click();
    await box.fill("Unsent new chat");
    await finish("Stop");
    await choose("Other chat");
    await release();
    await draftIs("Edited B");
    await page.getByRole("button", { name: "New chat", exact: true }).click();
    await draftIs("Unsent new chat dictated words");
    assert.equal(cloud.prompts.length, 0);

    await choose("Dictation origin");
    await box.fill("Draft during disconnect");
    await finish("Send");
    cloud.pause();
    for (const socket of cloud.wss.clients) socket.close();
    await page.getByText(/Reconnecting to/).waitFor();
    await release();
    await draftIs("Draft during disconnect dictated words");
    cloud.resume();
    await page.getByText(/Reconnecting to/).waitFor({ state: "hidden" });
    assert.equal(cloud.prompts.length, 0, "reconnect does not retry a dictation Send");

    await box.fill("Explicit send");
    await finish("Send");
    // Selecting the same chat replaces a Selection object, not its draft.
    await choose("Dictation origin");
    await release();
    await draftIs("");
    assert.deepEqual(cloud.prompts.map(prompt => [prompt.sessionId, prompt.text]), [[a, "Explicit send dictated words"]]);
  } finally {
    await app.close();
  }
});
