// Renders a measuring build (every cropped artboard widened on each side) in the Rive web
// runtime, drives every behaviour, and checks nothing is drawn outside the real artboard, so no
// pose is clipped in the apps.
import assert from "node:assert/strict";
import { test } from "node:test";
import { chromium, type Page } from "playwright-core";
import { buildMascot, MascotBounds, MascotContract } from "../src/mascot.ts";
import { startPreviewServer } from "./preview-server.ts";

const chromePath = process.env.CHROME_PATH ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const MARGIN = 400;

interface Box {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

const artboards = {
  [MascotContract.artboards.face]: MascotBounds.face,
  [MascotContract.artboards.mark]: MascotBounds.mark,
  [MascotContract.artboards.loader]: MascotBounds.loader,
};

/** Loads every cropped artboard at one pixel per unit and starts recording what each draws. */
async function startMeasuring(page: Page) {
  await page.evaluate(
    async ({ artboards, margin }) => {
      const { Rive, Layout, Fit, Alignment } = (window as any).rive;
      for (const mascot of (window as any).mascots) mascot.cleanup();
      document.body.replaceChildren();
      const measured: any[] = [];
      await Promise.all(
        Object.entries(artboards).map(
          ([artboard, bounds]: [string, any]) =>
            new Promise<void>((loaded, failed) => {
              const canvas = document.createElement("canvas");
              canvas.width = bounds.width + 2 * margin;
              canvas.height = bounds.height + 2 * margin;
              document.body.append(canvas);
              const rive = new Rive({
                src: "/axo.riv",
                canvas,
                artboard,
                stateMachines: "Mascot",
                autoplay: true,
                layout: new Layout({ fit: Fit.Contain, alignment: Alignment.Center }),
                onLoad: () => loaded(),
                onLoadError: (error: any) => failed(new Error(`${artboard}: ${error?.data ?? error}`)),
              });
              measured.push({ artboard, bounds, canvas, rive, boxes: {} });
            }),
        ),
      );
      const w = window as any;
      w.measured = measured;
      w.phase = "idle";
      w.input = (name: string, apply: (input: any) => void) => {
        for (const { rive } of measured) {
          const input = rive.stateMachineInputs("Mascot")?.find((i: any) => i.name === name);
          if (input) apply(input);
        }
      };
      // Every other frame, grow the current phase's box around every pixel drawn.
      let frame = 0;
      const sample = () => {
        if (frame++ % 2 === 0) {
          for (const entry of measured) {
            const { canvas, bounds } = entry;
            const pixels = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data;
            let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
            for (let y = 0; y < canvas.height; y += 2) {
              for (let x = 0; x < canvas.width; x += 2) {
                if (pixels[(y * canvas.width + x) * 4 + 3] > 16) {
                  if (x < left) left = x;
                  if (x > right) right = x;
                  if (y < top) top = y;
                  if (y > bottom) bottom = y;
                }
              }
            }
            if (right < 0) continue;
            // In logo units.
            const box = { left: left - margin + bounds.x, top: top - margin + bounds.y, right: right - margin + bounds.x, bottom: bottom - margin + bounds.y };
            const seen = (entry.boxes[w.phase] ??= { ...box });
            seen.left = Math.min(seen.left, box.left);
            seen.top = Math.min(seen.top, box.top);
            seen.right = Math.max(seen.right, box.right);
            seen.bottom = Math.max(seen.bottom, box.bottom);
          }
        }
        requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
    },
    { artboards, margin: MARGIN },
  );
}

const phase = (page: Page, name: string) => page.evaluate((name) => ((window as any).phase = name), name);
const set = (page: Page, input: string, value: number | boolean) =>
  page.evaluate(([input, value]) => (window as any).input(input, (i: any) => (i.value = value)), [input, value] as const);
const fire = (page: Page, input: string) => page.evaluate((input) => (window as any).input(input, (i: any) => i.fire()), input);

/** Every behaviour the apps drive, each recorded as its own phase. */
async function playEverything(page: Page) {
  const { bools, numbers, triggers } = MascotContract;
  await phase(page, "idle");
  await page.waitForTimeout(4500);

  await phase(page, "looking");
  await set(page, bools.tracking, true);
  for (const x of [-100, 0, 100]) {
    for (const y of [-100, 0, 100]) {
      await set(page, numbers.lookX, x);
      await set(page, numbers.lookY, y);
      await page.waitForTimeout(350);
    }
  }
  await set(page, bools.tracking, false);
  await page.waitForTimeout(500);

  await phase(page, "poke");
  await fire(page, triggers.poke);
  await page.waitForTimeout(1600);

  await phase(page, "annoyed");
  await fire(page, triggers.annoyed);
  await page.waitForTimeout(1600);

  await phase(page, "happy");
  await fire(page, triggers.happy);
  await page.waitForTimeout(1400);

  await phase(page, "squeezed");
  await set(page, bools.squeezed, true);
  await page.waitForTimeout(500);
  await set(page, bools.squeezed, false);

  await phase(page, "loading");
  await set(page, bools.loading, true);
  await page.waitForTimeout(4500);
  await set(page, bools.loading, false);
  await page.waitForTimeout(500);

  // The arms reach down out of the picture on purpose; only the sides and top count here.
  await phase(page, "covering");
  await set(page, bools.covering, true);
  await page.waitForTimeout(1200);
  await set(page, bools.covering, false);
  await page.waitForTimeout(600);
  await phase(page, "done");
}

test("every pose stays inside its artboard", { timeout: 120_000 }, async () => {
  const { server, url } = await startPreviewServer(0, buildMascot({ measuringMargin: MARGIN }));
  const browser = await chromium.launch({ executablePath: chromePath });
  try {
    const page = await browser.newPage();
    // tsx names the functions it compiles with a helper the page doesn't have.
    await page.addInitScript("window.__name = (f) => f");
    await page.goto(url);
    await page.waitForFunction(() => (window as any).mascots.every((m: any) => m.loaded), null, { timeout: 15_000 });
    await startMeasuring(page);
    await playEverything(page);
    const measured: { artboard: string; boxes: Record<string, Box> }[] = await page.evaluate(() =>
      (window as any).measured.map(({ artboard, boxes }: any) => ({ artboard, boxes })),
    );

    const report: string[] = [];
    const overflows: string[] = [];
    const check = (ok: boolean, message: string) => ok || overflows.push(message);
    for (const { artboard, boxes } of measured) {
      const bounds = artboards[artboard as keyof typeof artboards];
      const all = Object.entries(boxes).filter(([name]) => name !== "done");
      const union = (entries: [string, Box][]) =>
        entries.reduce(
          (u, [, b]) => ({ left: Math.min(u.left, b.left), top: Math.min(u.top, b.top), right: Math.max(u.right, b.right), bottom: Math.max(u.bottom, b.bottom) }),
          { left: Infinity, top: Infinity, right: -Infinity, bottom: -Infinity },
        );
      const reach = union(all);
      const withoutArms = union(all.filter(([name]) => name !== "covering"));
      report.push(`${artboard}: drawn x ${reach.left}…${reach.right}, y ${reach.top}…${withoutArms.bottom} (without arms); bounds x ${bounds.x}…${bounds.x + bounds.width}, y ${bounds.y}…${bounds.y + bounds.height}`);
      for (const [name, box] of all) {
        report.push(`  ${name}: x ${box.left}…${box.right}, y ${box.top}…${box.bottom}`);
        const where = `${artboard} ${name}`;
        check(box.left >= bounds.x, `${where} reaches left to ${box.left}, past ${bounds.x}`);
        check(box.top >= bounds.y, `${where} reaches up to ${box.top}, past ${bounds.y}`);
        check(box.right <= bounds.x + bounds.width, `${where} reaches right to ${box.right}, past ${bounds.x + bounds.width}`);
        if (name !== "covering") {
          check(box.bottom <= bounds.y + bounds.height, `${where} reaches down to ${box.bottom}, past ${bounds.y + bounds.height}`);
        }
      }
    }
    console.log(report.join("\n"));
    assert.deepEqual(overflows, [], report.join("\n"));
  } finally {
    await browser.close();
    server.close();
  }
});
