// Export the real Rive mascot for watchOS, where the Apple Rive runtime is unavailable.
// bazel run //packages/axo-mascot:export_watch_assets -- "$PWD/assets/watchos/Brand.xcassets"
import { mkdir, writeFile } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { chromium, type Browser } from "playwright-core";
import { startPreviewServer } from "../test/preview-server.ts";

const output = process.argv[2];
if (!output || !isAbsolute(output)) throw new Error("Pass an absolute output catalog path");
const { server, url } = await startPreviewServer();
let browser: Browser | undefined;
try {
  browser = await chromium.launch({
    executablePath: process.env.CHROME_PATH ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  });
  const page = await browser.newPage({ deviceScaleFactor: 2 });
  await page.goto(url);
  await page.waitForFunction(() => (window as any).mascots.every((m: any) => m.loaded));
  await page.evaluate(() => {
    for (const mascot of (window as any).mascots) {
      mascot.canvas.style.width = "532px";
      mascot.canvas.style.height = "302px";
      mascot.resizeDrawingSurfaceToCanvas();
      const inputs = mascot.stateMachineInputs("Mascot");
      inputs.find((i: any) => i.name === "tracking").value = true;
      inputs.find((i: any) => i.name === "lookX").value = 0;
      inputs.find((i: any) => i.name === "lookY").value = 0;
    }
  });
  await page.waitForTimeout(150);
  await mkdir(output, { recursive: true });
  await writeFile(join(output, "Contents.json"), JSON.stringify({ info: { author: "xcode", version: 1 } }, null, 2) + "\n");
  for (const [name, artboard, happy] of [["AxoFace", "Face", false], ["AxoMark", "Mark", false], ["AxoHappy", "Face", true]] as const) {
    if (happy) {
      await page.evaluate(() => {
        const mascot = (window as any).mascots.find((m: any) => m.canvas.dataset.artboard === "Face");
        mascot.stateMachineInputs("Mascot").find((i: any) => i.name === "happy").fire();
      });
      await page.waitForTimeout(300);
    }
    const png = await page.evaluate((artboard) => {
      const canvas = document.querySelector(`canvas[data-artboard="${artboard}"]`) as HTMLCanvasElement;
      return canvas.toDataURL("image/png").split(",")[1]!;
    }, artboard);
    const directory = join(output, name + ".imageset");
    await mkdir(directory, { recursive: true });
    await writeFile(join(directory, name + ".png"), Buffer.from(png, "base64"));
    await writeFile(join(directory, "Contents.json"), JSON.stringify({
      images: [{ filename: name + ".png", idiom: "universal" }],
      info: { author: "xcode", version: 1 },
      properties: { "template-rendering-intent": artboard === "Mark" ? "template" : "original" },
    }, null, 2) + "\n");
    console.log(`Exported ${name} from ${artboard}`);
  }
} finally {
  server.close();
  await browser?.close();
}
