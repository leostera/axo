import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex } from "@noble/hashes/utils.js";
import { env } from "onnxruntime-web";
import wasmUrl from "onnxruntime-web/ort-wasm-simd-threaded.jsep.wasm?url";
import { ParakeetModel } from "parakeet.js/parakeet";
import { dictationSampleRate, modelAssets, modelBytes, runtimeBytes, type Asset, type ModelReply, type ModelRequest } from "./parakeet-assets.ts";

const runtime: Asset = {
  url: new URL(wasmUrl, self.location.href).href,
  bytes: runtimeBytes,
  sha256: "5febcf74919ee7ba3c7e838290c9ef2c03d6da297f06a8facfd7d22f623d7cd9",
};
const assets = [modelAssets.encoder, modelAssets.decoder, modelAssets.tokenizer];
const cacheName = "axo-parakeet-v1";

let model: ParakeetModel | undefined;

function report(reply: ModelReply): void {
  self.postMessage(reply);
}

/** Hash both fresh and cached bytes before handing them to ORT. Keep the large assets as blobs. */
async function verifiedBlob(response: Response, asset: Asset, progress: (bytes: number) => void): Promise<Blob | null> {
  if (!response.ok || !response.body) return null;
  const hash = sha256.create();
  const reader = response.body.getReader();
  const chunks: BlobPart[] = [];
  let received = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      received += value.byteLength;
      if (received > asset.bytes) return null;
      hash.update(value);
      chunks.push(value);
      progress(received);
    }
    if (received !== asset.bytes || bytesToHex(hash.digest()) !== asset.sha256) return null;
    return new Blob(chunks);
  } finally {
    await reader.cancel();
  }
}

async function readAsset(
  cache: Cache, asset: Asset, download: boolean, progress: (bytes: number) => void,
): Promise<Blob | null> {
  const cached = await cache.match(asset.url);
  if (cached) {
    const blob = await verifiedBlob(cached, asset, () => {});
    if (blob) return blob;
    await cache.delete(asset.url);
  }
  if (!download) return null;
  const response = await fetch(asset.url, { credentials: "omit", cache: "no-store" });
  const blob = await verifiedBlob(response, asset, progress);
  if (!blob) throw new Error("A dictation file failed verification. Try downloading it again.");
  try {
    await cache.put(asset.url, new Response(blob));
  } catch {
    throw new Error("Dictation couldn't save its files. Free up browser storage and try again.");
  }
  return blob;
}

async function prepare(download: boolean): Promise<void> {
  if (model) return report({ kind: "ready" });
  const cache = await caches.open(cacheName).catch(() => {
    throw new Error("Dictation needs browser storage. Check your browser settings and try again.");
  });
  if (!download && !(await Promise.all(assets.map(asset => cache.match(asset.url)))).every(Boolean)) {
    return report({ kind: "needsDownload" });
  }

  let loaded = 0;
  let shownPercent = -1;
  const urls: string[] = [];
  try {
    for (const asset of assets) {
      const blob = await readAsset(cache, asset, download, bytes => {
        const percent = Math.min(99, Math.floor(100 * (loaded + bytes) / modelBytes));
        if (percent === shownPercent) return;
        shownPercent = percent;
        report({ kind: "downloading", percent });
      });
      if (!blob) return report({ kind: "needsDownload" });
      loaded += asset.bytes;
      urls.push(URL.createObjectURL(blob));
    }
    report({ kind: "loading" });
    // The loader JS is bundled from the locked npm tarball; ORT instantiates only this checked binary.
    if (!env.wasm.wasmBinary) {
      const binary = await readAsset(cache, runtime, true, () => {});
      if (!binary) throw new Error("Dictation runtime is missing.");
      env.wasm.wasmPaths = { wasm: runtime.url }; // Keep the loader bundled; do not use a runtime CDN.
      env.wasm.wasmBinary = await binary.arrayBuffer();
    }
    model = await ParakeetModel.fromUrls({
      encoderUrl: urls[0]!,
      decoderUrl: urls[1]!,
      tokenizerUrl: urls[2]!,
      backend: "wasm",
      cpuThreads: 1,
      preprocessorBackend: "js",
      nMels: 128,
    }).catch(error => {
      console.error("Parakeet initialization failed", error);
      throw new Error("On-device dictation couldn't start. Try a desktop browser with more available memory.");
    });
    report({ kind: "ready" });
  } finally {
    for (const url of urls) URL.revokeObjectURL(url);
  }
}

async function transcribe(pcm: Float32Array): Promise<void> {
  if (!model) throw new Error("Dictation isn't ready. Try again.");
  // Don't ask the decoder to invent text for a silent recording. Pad short clips for the encoder.
  if (!pcm.some(sample => Math.abs(sample) >= 0.001)) return report({ kind: "transcript", text: "" });
  const audio = pcm.length < 4_000 ? new Float32Array(4_000) : pcm;
  if (audio !== pcm) audio.set(pcm);
  try {
    const { utterance_text } = await model.transcribe(audio, dictationSampleRate, { returnTimestamps: false });
    report({ kind: "transcript", text: utterance_text });
  } catch (error) {
    console.error("Parakeet inference failed", error);
    throw new Error("Couldn't transcribe this recording on your device. Try a shorter recording.");
  }
}

self.addEventListener("message", async ({ data }: MessageEvent<ModelRequest>) => {
  try {
    if (data.kind === "prepare") await prepare(data.download);
    else await transcribe(data.pcm);
  } catch (error) {
    report({ kind: "failed", message: error instanceof TypeError ? "Couldn't download dictation. Check your connection and try again."
      : error instanceof Error ? error.message : "On-device dictation stopped. Try again." });
  }
});
