// The chat list, in Chrome against a fake cloud: "Mark all read" marks every chat seen on this
// browser at once, and it stays so after a reload.
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { test } from "node:test";
import { chromePath, hostId, listed, record, sid, startApp, startCloud } from "./fake-cloud.mjs";

test("mark all read marks every chat seen, and it stays so", {
  skip: !existsSync(chromePath) && "Set CHROME_PATH to a Chrome/Chromium executable to run this browser test",
  timeout: 120_000,
}, async () => {
  const chats = [1, 2, 3].map(sid);
  const transcripts = new Map(chats.map((id) => [id, [record(1, { role: "user", content: [{ type: "text", text: "hi" }] })]]));
  const cloud = await startCloud(transcripts, chats.map((id, n) => listed(id, `Chat ${n + 1}`, 1)));
  let app;
  try {
    app = await startApp(cloud);
    const page = await app.browser.newPage({ viewport: { width: 1100, height: 800 } });
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    // This browser started keeping track long ago: every chat has activity nobody here saw.
    await page.addInitScript(() => {
      if (!localStorage.getItem("sidebar.seenSessionsBaseline.v1")) localStorage.setItem("sidebar.seenSessionsBaseline.v1", "0");
    });
    await page.goto(`${app.appUrl}/__tests__/chat/${hostId}/${chats[0]}`, { waitUntil: "networkidle" });
    const dots = page.getByLabel("New activity");
    const markAll = page.getByRole("button", { name: "Mark all read" });
    // The open chat is seen; the other two are not.
    await markAll.waitFor();
    assert.equal(await dots.count(), 2);
    assert.equal(await markAll.getAttribute("title"), "Mark all read (2 chats)");
    await markAll.click();
    await markAll.waitFor({ state: "detached" });
    assert.equal(await dots.count(), 0, "every chat is seen");
    await page.reload({ waitUntil: "networkidle" });
    await page.getByRole("heading", { name: "Chat 1", exact: true }).waitFor();
    assert.equal(await dots.count(), 0, "and stays so");
    assert.equal(await markAll.count(), 0);
    assert.deepEqual(errors, []);
  } finally {
    await app?.close();
  }
});
