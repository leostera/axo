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
      assert.deepEqual(mascot.inputs, [
        ...Object.values(MascotContract.triggers),
        ...Object.values(MascotContract.bools),
        ...Object.values(MascotContract.numbers),
      ]);
    }

    const face = page.locator('canvas[data-artboard="Face"]');
    await page.waitForTimeout(300);
    const open = await face.screenshot();
    await page.click("#blink");
    await page.waitForTimeout(90);
    const closed = await face.screenshot();
    assert.notDeepEqual(closed, open, "the blink trigger closes the eyes");

    // Each behaviour changes the picture.
    const settle = async () => {
      await page.waitForTimeout(400);
      return face.screenshot();
    };
    const calm = await settle();
    await page.check("#covering");
    const covered = await settle();
    assert.notDeepEqual(covered, calm, "the hands come up");
    await page.uncheck("#covering");
    await page.mouse.move(5, 5);
    await page.mouse.down();
    const looking = await settle();
    await page.mouse.up();
    assert.notDeepEqual(looking, calm, "the eyes follow the pointer");
    const loader = page.locator('canvas[data-artboard="Loader"]');
    const loaderStill = await loader.screenshot();
    await page.check("#loading");
    await page.waitForTimeout(1000);
    assert.notDeepEqual(await loader.screenshot(), loaderStill, "loading moves it");
    await page.uncheck("#loading");
    await page.check("#squeezed");
    assert.notDeepEqual(await settle(), calm, "squeezed shuts its eyes >_<");
    await page.uncheck("#squeezed");
    await page.click("#poke");
    await page.waitForTimeout(80);
    assert.notDeepEqual(await face.screenshot(), calm, "a poke surprises it");
    await page.waitForTimeout(1200);
    await page.click("#annoyed");
    await page.waitForTimeout(300);
    assert.notDeepEqual(await face.screenshot(), calm, "annoyed squeezes its eyes shut");
    await page.waitForTimeout(1400);
    await page.click("#happy");
    await page.waitForTimeout(300);
    assert.notDeepEqual(await face.screenshot(), calm, "happy smiles with its eyes");
    await page.waitForTimeout(1400);
    await page.click("#scream");
    await page.waitForTimeout(300);
    assert.notDeepEqual(await face.screenshot(), calm, "scream opens its eyes and mouth wide");
  } finally {
    await browser.close();
    server.close();
  }
});
