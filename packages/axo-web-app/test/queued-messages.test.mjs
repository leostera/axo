import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { test } from "node:test";
import { chromePath, hostId, listed, record, sid, startApp, startCloud } from "./fake-cloud.mjs";

const chat = sid(1);
for (const [name, viewport] of [
  ["desktop", { width: 1180, height: 900 }],
  ["phone", { width: 390, height: 844 }],
]) {
  test(`queued prompts remain at the bottom as output streams and receipts arrive (${name})`, {
    skip: !existsSync(chromePath) && "Chrome/Chromium is required",
    timeout: 60_000,
  }, async () => {
    const history = Array.from({ length: 30 }, (_, i) => record(i + 1, {
      role: i % 2 ? "assistant" : "user",
      timestamp: 1_700_000_000_000 + i,
      content: [{ type: "text", text: `Earlier message ${i + 1}: checking the preview and its next step.` }],
    }));
    const cloud = await startCloud(new Map([[chat, history]]), [{ ...listed(chat, "Queue", history.length), status: "working" }]);
    let app;
    try {
      app = await startApp(cloud);
      const page = await app.browser.newPage({ viewport });
      const errors = [];
      page.on("pageerror", error => errors.push(error.message));
      await page.goto(`${app.appUrl}/__tests__/chat/${hostId}/${chat}`, { waitUntil: "networkidle" });
      await page.getByText("Earlier message 30:", { exact: false }).waitFor();
      const queue = (commandId, text) => cloud.custom(chat, "axo.command.queued",
        { commandId, text, delivery: "followUp", attachments: [] });
      const tail = () => page.evaluate(() => {
        const rows = [...document.querySelectorAll(".transcript-column > .message, .transcript-column > .tool-card")];
        const first = rows.findIndex(row => row.matches(".pending"));
        return first < 0 ? [] : rows.slice(first).map(row => ({
          waiting: row.matches(".pending"), text: row.textContent,
        }));
      });
      queue("queue-first", "Then check the image.");
      await page.getByTestId("pending-prompt").waitFor();
      cloud.write(chat, { role: "assistant", timestamp: 1_700_000_001_000, content: [{ type: "text", text: "Output after the first queued prompt." }] });
      await page.getByText("Output after the first queued prompt.", { exact: true }).waitFor();
      queue("queue-second", "Also check the recording.");
      await page.getByTestId("pending-prompt").nth(1).waitFor();
      cloud.write(chat, { role: "assistant", timestamp: 1_700_000_002_000, content: [
        { type: "text", text: "More output while both prompts wait." },
        { type: "toolCall", id: "queue-tool", name: "read", arguments: { path: "preview.ts" } },
      ] });
      await page.getByTestId("tool-card").waitFor();
      let rows = await tail();
      assert.equal(rows.length, 2);
      assert.ok(rows.every(row => row.waiting), "No output row may follow an unconsumed prompt");
      assert.match(rows[0].text, /Then check the image/);
      assert.match(rows[1].text, /Also check the recording/);

      // Changing the viewport while following keeps the tail visible too.
      await page.setViewportSize({ ...viewport, height: viewport.height - 200 });
      await page.waitForFunction(() => {
        const element = document.querySelector('[data-testid="transcript"]');
        return element.scrollHeight - element.clientHeight - element.scrollTop < 1;
      });
      await page.setViewportSize(viewport);

      // A fixed queue tail must not hide the new-output indicator from a reader in history.
      await page.getByTestId("transcript").evaluate(element => { element.scrollTop = 50; });
      await page.getByRole("button", { name: "Jump to latest", exact: true }).waitFor().catch(async error => {
        const state = await page.getByTestId("transcript").evaluate(element => ({
          top: element.scrollTop, height: element.clientHeight, content: element.scrollHeight,
          jump: document.querySelector(".jump-button")?.outerHTML,
        }));
        throw new Error(`${error.message}; scroll: ${JSON.stringify(state)}; errors: ${JSON.stringify(errors)}`);
      });
      cloud.write(chat, { role: "assistant", timestamp: 1_700_000_003_000, content: [{ type: "text", text: "New output above the waiting queue." }] });
      await page.getByRole("button", { name: "Jump to new message", exact: true }).waitFor();
      rows = await tail();
      assert.equal(rows.length, 2);
      assert.ok(rows.every(row => row.waiting));
      await page.getByRole("button", { name: "Jump to new message", exact: true }).click();
      await page.getByText("New output above the waiting queue.", { exact: true }).waitFor();
      const output = process.env.TEST_UNDECLARED_OUTPUTS_DIR;
      if (output) await page.screenshot({ path: resolve(output, `web-queue-tail-${name}.png`) });

      // Once picked up, the real user message occupies its normal place; only the other stays queued.
      cloud.custom(chat, "axo.command", { commandId: "queue-first" });
      cloud.write(chat, { role: "user", content: [{ type: "text", text: "Then check the image." }] });
      cloud.write(chat, { role: "assistant", timestamp: 1_700_000_004_000, content: [{ type: "text", text: "The image is checked." }] });
      await page.getByText("The image is checked.", { exact: true }).waitFor();
      await page.waitForFunction(() => document.querySelectorAll("[data-testid=pending-prompt]").length === 1);
      rows = await tail();
      assert.equal(rows.length, 1);
      assert.match(rows[0].text, /Also check the recording/);
      await page.reload({ waitUntil: "networkidle" });
      await page.getByTestId("pending-prompt").waitFor();
      rows = await tail();
      assert.equal(rows.length, 1);
      assert.ok(rows.every(row => row.waiting));
      assert.deepEqual(errors, []);
      assert.equal(cloud.prompts.length, 0, "Rendering/reordering must never send a prompt");
    } finally {
      if (app) await app.close();
      else { cloud.wss.close(); cloud.http.close(); }
    }
  });
}
