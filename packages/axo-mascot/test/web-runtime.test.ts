// Loads assets/mascot/axo.riv in the Rive web runtime (headless Chrome) and checks it blinks.
import assert from "node:assert/strict";
import { test } from "node:test";
import { chromium } from "playwright-core";
import { MascotContract } from "../src/mascot.ts";
import { startPreviewServer } from "./preview-server.ts";

const chromePath = process.env.CHROME_PATH ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

test("every artboard loads with the Mascot state machine and blinks on the trigger", async () => {
  const { server, url } = await startPreviewServer();
  const browser = await chromium.launch({ executablePath: chromePath });
  try {
    const page = await browser.newPage();
    await page.goto(url);
    await page.waitForFunction(
      () => (window as any).mascotErrors.length > 0 || (window as any).mascots.every((m: any) => m.loaded),
      null,
      { timeout: 15_000 },
    );
    const loaded = await page.evaluate(() => ({
      errors: (window as any).mascotErrors as string[],
      mascots: (window as any).mascots.map((m: any) => ({
        stateMachines: m.stateMachineNames as string[],
        inputs: m.stateMachineInputs("Mascot").map((input: any) => input.name) as string[],
      })),
    }));
    assert.deepEqual(loaded.errors, []);
    assert.equal(loaded.mascots.length, Object.keys(MascotContract.artboards).length);
    for (const mascot of loaded.mascots) {
      assert.deepEqual(mascot.stateMachines, [MascotContract.stateMachine]);
      assert.deepEqual(mascot.inputs, [MascotContract.triggers.blink]);
    }

    const face = page.locator('canvas[data-artboard="Face"]');
    await page.waitForTimeout(300);
    const open = await face.screenshot();
    await page.click("#blink");
    await page.waitForTimeout(90);
    const closed = await face.screenshot();
    assert.notDeepEqual(closed, open, "the blink trigger closes the eyes");
  } finally {
    await browser.close();
    server.close();
  }
});
