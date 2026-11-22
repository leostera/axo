import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir, arch, platform, cpus } from "node:os";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { test } from "node:test";
import { chromium } from "playwright-core";
import { chromePath, hostId, listed, record, sid, startApp, startCloud } from "./fake-cloud.mjs";

const fixture = process.env.AXO_PARAKEET_FIXTURE;
const resultsPath = process.env.AXO_PARAKEET_BENCH_RESULTS;
const expected = process.env.AXO_PARAKEET_TEXT || "The blue notebook is on the kitchen table.";
const words = text => text.toLowerCase().match(/[a-z]+/g)?.join(" ");

// Opt-in: downloads ~696 MB, with a normal Chrome profile (private mode can fail the cache quota).
test("real Parakeet WASM: microphone to Stop/Send, cancellation, offline cache and integrity", {
  skip: (!fixture || !existsSync(chromePath)) && "set AXO_PARAKEET_FIXTURE to a synthetic speech WAV and install Chrome",
  timeout: resultsPath ? 600_000 : 300_000,
}, async () => {
  const profile = await mkdtemp(join(tmpdir(), "axo-web-parakeet-"));
  const session = sid(1);
  const cloud = await startCloud(new Map([[session, [record(1, { role: "user", content: "Original chat" })]]]), [listed(session, "Original", 1)]);
  const wav = (await readFile(fixture)).toString("base64");
  let app;
  try {
    app = await startApp(cloud, () => chromium.launchPersistentContext(profile, {
      executablePath: chromePath, headless: true, viewport: { width: 1440, height: 960 }, args: ["--no-sandbox"],
    }));
    const external = [];
    const blockedModel = [];
    const writes = [];
    let runtimeDownloads = 0;
    let allowDownload = true;
    await app.browser.route("**/*", route => {
      const request = route.request();
      const url = new URL(request.url());
      if (!/^https?:$/.test(url.protocol)) return route.continue();
      if (url.origin === app.appUrl) {
        if (url.pathname.endsWith(".wasm") && url.pathname.includes("ort-wasm") && !url.searchParams.has("url")) runtimeDownloads++;
        if (!["GET", "HEAD"].includes(request.method())) writes.push(request.url());
        return route.continue();
      }
      const model = url.hostname === "huggingface.co" || url.hostname.endsWith(".hf.co");
      if (model && request.method() === "GET" && !allowDownload) blockedModel.push(url.href);
      else external.push({ host: url.hostname, method: request.method() });
      return allowDownload && model && request.method() === "GET" ? route.continue() : route.abort();
    });
    const page = await app.browser.newPage();
    page.on("console", message => { if (message.type() === "error") console.log(message.text()); });
    page.on("pageerror", error => console.log(error.message));
    page.on("requestfailed", request => {
      if (request.url().startsWith(app.appUrl)) console.log(request.url(), request.failure());
    });
    await page.addInitScript(base64 => {
      window.dictationMicCalls = 0;
      window.dictationWorkerReplies = [];
      const RealWorker = window.Worker;
      window.Worker = class extends RealWorker {
        constructor(url, options) {
          super(url, options);
          if (String(url).includes("parakeet.worker")) {
            this.addEventListener("message", ({ data }) => window.dictationWorkerReplies.push(data.kind));
          }
        }
      };
      document.addEventListener("click", event => {
        if (!event.target.closest('button[aria-label="Talk"]')) return;
        const clickMs = performance.now();
        window.dictationLatency = new Promise(resolve => {
          const observer = new MutationObserver(() => {
            if (!document.querySelector('[aria-label="Listening"]')) return;
            observer.disconnect();
            resolve({ clickToListeningMs: performance.now() - clickMs, clickMs });
          });
          observer.observe(document, { childList: true, subtree: true });
        });
      }, true);
      navigator.mediaDevices.getUserMedia = async () => {
        window.dictationMicCalls++;
        const audio = new AudioContext();
        const destination = audio.createMediaStreamDestination();
        const source = audio.createBufferSource();
        const bytes = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
        source.buffer = await audio.decodeAudioData(bytes.buffer);
        source.connect(destination);
        const [track] = destination.stream.getAudioTracks();
        const stop = track.stop.bind(track);
        track.stop = () => { stop(); void audio.close(); };
        window.playDictationFixture = () => new Promise(resolve => {
          source.onended = () => setTimeout(resolve, 100);
          source.start();
        });
        return destination.stream;
      };
    }, wav);
    const path = `${app.appUrl}/__tests__/chat/${hostId}/${session}`;
    const box = page.getByRole("textbox", { name: "Message" });
    const talk = page.getByRole("button", { name: "Talk" });
    const listening = page.getByRole("group", { name: "Listening" });
    // Let Vite finish dependency discovery before interacting with this first load.
    await page.goto(path, { waitUntil: "networkidle" });
    await page.getByText("Original chat", { exact: true }).waitFor();
    assert.deepEqual(await page.evaluate(() => window.dictationWorkerReplies), [], "fresh setup does not prepare in the background");
    await box.fill("Typed draft.");
    const download = page.getByRole("button", { name: "Download", exact: true });
    // The dev server may reload once when it first discovers the worker's dependencies.
    const initialLoad = page.waitForEvent("framenavigated", { predicate: frame => frame === page.mainFrame(), timeout: 10_000 });
    await talk.click();
    if (await Promise.race([initialLoad.then(() => true), download.waitFor({ timeout: 10_000 }).then(() => false)])) {
      await talk.click();
      await download.waitFor({ timeout: 10_000 });
    }
    assert.equal(external.filter(request => request.host === "huggingface.co").length, 0);
    assert.equal(await page.evaluate(() => typeof window.playDictationFixture), "undefined");
    const cold = performance.now();
    await download.click();
    await listening.waitFor({ timeout: 180_000 });
    const coldMs = Math.round(performance.now() - cold);
    await page.evaluate(() => window.playDictationFixture());
    const stop = performance.now();
    const writesBeforeStop = writes.length;
    await listening.getByRole("button", { name: "Stop" }).click();
    await box.waitFor({ timeout: 60_000 });
    const draft = await box.inputValue();
    assert.equal(words(draft), words(`Typed draft. ${expected}`));
    assert.equal(writes.length, writesBeforeStop, "Stop doesn't upload audio or submit a prompt");
    assert.equal(cloud.prompts.length, 0);
    console.log({ coldMs, stopMs: Math.round(performance.now() - stop), draft });

    await talk.click();
    await listening.getByRole("button", { name: "Cancel" }).click();
    assert.equal(await box.inputValue(), draft);
    assert.equal(cloud.prompts.length, 0);

    allowDownload = false;
    await page.reload();
    await page.getByText("Original chat", { exact: true }).waitFor();
    await box.fill("");
    const cached = performance.now();
    await talk.click();
    await listening.waitFor({ timeout: 60_000 });
    const cachedMs = Math.round(performance.now() - cached);
    await page.evaluate(() => window.playDictationFixture());
    await listening.getByRole("button", { name: "Send" }).click();
    await page.waitForFunction(() => !document.querySelector('[aria-label="Listening"]') && Boolean(document.querySelector('textarea')));
    assert.equal(cloud.prompts.length, 1);
    assert.equal(words(cloud.prompts[0].text), words(expected));
    assert.deepEqual(blockedModel, [], "a reload reuses disk cache without any model-origin network attempt");
    assert.equal(runtimeDownloads, 1, "a reload reuses the checked WASM binary too");
    assert.ok(external.every(({ host, method }) => method === "GET" && (host === "huggingface.co" || host.endsWith(".hf.co"))), JSON.stringify(external));
    console.log({ cachedMs, sent: cloud.prompts[0].text });

    if (resultsPath) {
      const results = {
        schemaVersion: 1,
        generatedAt: new Date().toISOString(),
        commit: execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim(),
        dirty: Boolean(execFileSync("git", ["status", "--porcelain"], { encoding: "utf8" }).trim()),
        environment: { platform: platform(), arch: arch(), cpu: cpus()[0]?.model, chrome: await page.evaluate(() => navigator.userAgent), app: "local Vite + fake cloud" },
        config: { samplesPerDelay: 5, delayMs: [0, 20000] },
        notes: "Real Talk click to Listening DOM, after page reload with a verified disk cache. Real WASM model and Web Audio graph; synthetic getUserMedia stream (no physical mic or permission prompt).",
        samples: [],
      };
      for (let i = 0; i < results.config.samplesPerDelay; i++) {
        for (const delayMs of results.config.delayMs) {
          await page.reload();
          await talk.waitFor();
          await page.waitForFunction(() => !document.querySelector('button[aria-label="Talk"]').disabled);
          const visible = await page.evaluate(() => performance.now());
          if (delayMs) await new Promise(done => setTimeout(done, delayMs));
          assert.equal(await page.evaluate(() => window.dictationMicCalls), 0);
          await talk.click();
          await listening.waitFor({ timeout: 60_000 });
          const { clickToListeningMs, clickMs } = await page.evaluate(() => window.dictationLatency);
          assert.equal(await page.evaluate(() => window.dictationMicCalls), 1);
          assert.deepEqual(blockedModel, []);
          assert.equal(runtimeDownloads, 1);
          results.samples.push({ delayMs, observedDelayMs: Math.round(clickMs - visible), clickToListeningMs: Math.round(clickToListeningMs) });
          console.log("Reload benchmark", results.samples.at(-1));
          await writeFile(resultsPath, JSON.stringify(results, null, 2) + "\n");
          await listening.getByRole("button", { name: "Cancel" }).click();
        }
      }
    }

    // With a complete cache, the worker reaches ready before Talk, but the mic stays closed.
    await page.reload();
    await page.waitForFunction(() => window.dictationWorkerReplies.includes("ready"), undefined, { timeout: 60_000 });
    assert.equal(await page.evaluate(() => window.dictationMicCalls), 0);
    await box.waitFor();
    assert.equal(await download.count(), 0);
    assert.deepEqual(blockedModel, []);
    assert.equal(runtimeDownloads, 1);

    // A partial cache must not cause a model or WASM fetch, even when every model file is present.
    await page.evaluate(async () => {
      const cache = await caches.open("axo-parakeet-v1");
      const runtime = (await cache.keys()).find(key => new URL(key.url).pathname.endsWith(".wasm"));
      const backup = await caches.open("dictation-test-runtime-backup");
      await backup.put(runtime, await cache.match(runtime));
      await cache.delete(runtime);
    });
    await page.reload();
    await page.waitForFunction(() => window.dictationWorkerReplies.includes("needsDownload"));
    assert.equal(await download.count(), 0, "a background miss doesn't prompt");
    assert.equal(await page.evaluate(() => window.dictationMicCalls), 0);
    assert.deepEqual(blockedModel, []);
    assert.equal(runtimeDownloads, 1);
    await talk.click();
    await download.waitFor();
    assert.equal(await page.evaluate(() => window.dictationMicCalls), 0);
    await page.evaluate(async () => {
      const cache = await caches.open("axo-parakeet-v1");
      const backup = await caches.open("dictation-test-runtime-backup");
      const [runtime] = await backup.keys();
      await cache.put(runtime, await backup.match(runtime));
      await caches.delete("dictation-test-runtime-backup");
    });

    // Unsupported browsers keep the normal message composer.
    const mobile = await app.browser.newPage();
    await mobile.addInitScript(() => Object.defineProperty(navigator, "userAgent", { value: "Android Mobile" }));
    await mobile.goto(path);
    await mobile.getByRole("button", { name: "On-device dictation needs a supported desktop browser." }).waitFor();
    await mobile.getByRole("textbox", { name: "Message" }).fill("Typing still works");
    await mobile.close();

    // A same-length cache replacement cannot get as far as the microphone or ONNX parser.
    await page.evaluate(async () => {
      const cache = await caches.open("axo-parakeet-v1");
      const tokenizer = (await cache.keys()).find(key => key.url.endsWith("/vocab.txt"));
      const length = (await (await cache.match(tokenizer)).arrayBuffer()).byteLength;
      await cache.put(tokenizer, new Response(new Uint8Array(length)));
    });
    await page.reload();
    await page.getByText("Original chat", { exact: true }).waitFor();
    await box.fill("Preserve this draft");
    await talk.click();
    await download.waitFor({ timeout: 60_000 });
    assert.equal(await box.inputValue(), "Preserve this draft");
    assert.equal(await page.evaluate(() => typeof window.playDictationFixture), "undefined");
  } finally {
    await app?.close();
    await rm(profile, { recursive: true, force: true });
  }
});
