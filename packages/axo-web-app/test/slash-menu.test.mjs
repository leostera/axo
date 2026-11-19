import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { test } from "node:test";
import { chromePath, hostId, listed, sid, startApp, startCloud } from "./fake-cloud.mjs";

for (const viewport of [{ width: 1100, height: 800 }, { width: 390, height: 600 }, { width: 900, height: 360 }]) {
  test(`slash menu: all commands, scrolling and keyboard visibility at ${viewport.width}x${viewport.height}`,
    { skip: !existsSync(chromePath), timeout: 60_000 }, async () => {
      const commands = Array.from({ length: 60 }, (_, n) => ({
        name: `command-${String(n).padStart(2, "0")}`,
        description: "A useful command with enough explanation to check that long descriptions stay compact and readable",
        source: n % 2 ? "skill" : "prompt",
      }));
      const session = sid(1);
      const cloud = await startCloud(new Map([[session, []]]), [listed(session, "Commands", 0)], { commands });
      let app;
      try {
        app = await startApp(cloud);
        const page = await app.browser.newPage({ viewport });
        const errors = [];
        page.on("pageerror", error => errors.push(error.message));
        await page.goto(`${app.appUrl}/__tests__/chat/${hostId}/${session}`, { waitUntil: "networkidle" });
        const field = page.getByRole("textbox", { name: "Message", exact: true });
        await field.fill("/");
        const menu = page.getByRole("listbox", { name: "Commands" });
        await menu.getByRole("option").last().waitFor();
        assert.equal(await menu.getByRole("option").count(), 60, "commands beyond the former eight-row cutoff are reachable");
        const nameBox = await menu.locator(".slash-name").first().boundingBox();
        const descriptionBox = await menu.locator(".slash-description").first().boundingBox();
        assert.ok(nameBox.x + nameBox.width <= descriptionBox.x, "commands stay left of their descriptions");
        assert.ok(Math.abs(nameBox.y - descriptionBox.y) < 4, "command and description share one row");
        const geometry = await menu.evaluate(element => {
          const r = element.getBoundingClientRect();
          return { top: r.top, bottom: r.bottom, height: r.height, scroll: element.scrollHeight, client: element.clientHeight };
        });
        assert.ok(geometry.top >= 8 && geometry.bottom <= viewport.height);
        assert.ok(geometry.height <= 322 && geometry.scroll > geometry.client);
        assert.equal(await menu.locator(".slash-name").first().evaluate(e => getComputedStyle(e).fontSize), "13px");
        const visibleSelection = async () => {
          await page.waitForFunction(() => {
            const menu = document.querySelector(".slash-menu"), row = menu?.querySelector('[aria-selected="true"]');
            if (!menu || !row) return false;
            const m = menu.getBoundingClientRect(), r = row.getBoundingClientRect();
            return r.top >= m.top && r.bottom <= m.bottom;
          });
        };
        await field.press("End");
        assert.equal(await menu.getByRole("option").last().getAttribute("aria-selected"), "true");
        await visibleSelection();
        assert.ok(await menu.evaluate(e => e.scrollTop > 0));
        await field.press("Home");
        await visibleSelection();
        assert.ok(await menu.evaluate(e => e.scrollTop <= 4), "Home reveals the first row, allowing list padding");
        await field.press("ArrowUp");
        await visibleSelection();
        assert.equal(await menu.getByRole("option").last().getAttribute("aria-selected"), "true");
        await field.press("ArrowDown");
        await visibleSelection();
        const rect = await menu.boundingBox();
        await page.mouse.move(rect.x + rect.width / 2, rect.y + rect.height / 2);
        await page.mouse.wheel(0, 500);
        await page.waitForFunction(() => document.querySelector(".slash-menu").scrollTop > 100);
        const scrolled = await menu.evaluate(e => e.scrollTop);
        await page.mouse.wheel(0, -500);
        await page.waitForFunction(previous => document.querySelector(".slash-menu").scrollTop < previous, scrolled);
        for (const appearance of ["light", "dark"]) {
          await page.evaluate(value => { document.documentElement.dataset.appearance = value; }, appearance);
          await page.screenshot({ path: join(process.env.TEST_UNDECLARED_OUTPUTS_DIR ?? tmpdir(), `slash-menu-${viewport.width}-${appearance}.png`) });
        }
        await field.fill("/command-59");
        await page.waitForFunction(() => document.querySelectorAll(".slash-row").length === 1);
        await field.press("Tab");
        assert.equal(await field.inputValue(), "/command-59 ");
        assert.equal(cloud.prompts.length, 0, "choosing a command never sends it");
        assert.equal(await field.evaluate(e => e === document.activeElement), true);
        assert.deepEqual(errors, []);
      } finally {
        await app?.close();
      }
    });
}
