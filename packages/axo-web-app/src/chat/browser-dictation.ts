import captureUrl from "./dictation-capture.js?url&no-inline";
import { dictationSampleRate, maxDictationSamples, modelAssets, parakeetCacheName, type ModelReply, type ModelRequest } from "./parakeet-assets.ts";
import { voiceMessages, type DictationEngine, type VoiceSetupProgress } from "./voice.ts";

export const dictationUnavailable = "On-device dictation needs a supported desktop browser.";

// The batch encoder is not interruptible without discarding the loaded model.
// Keep any work ahead of Stop to one short inference, never a queue.
const previewSamples = 2 * dictationSampleRate;
const previewInterval = 4 * dictationSampleRate;
const previewTimeBudgetMs = 1_200;

type PrepareResult = "ready" | "needsDownload";

interface Preparation {
  result: Promise<PrepareResult>;
  progress?: VoiceSetupProgress;
  onProgress?: (state: VoiceSetupProgress) => void;
}

export class BrowserDictation implements DictationEngine {
  static get supported(): boolean {
    if (!isSecureContext || !navigator.mediaDevices?.getUserMedia || !window.caches || !window.Worker
      || !window.AudioContext || !window.AudioWorkletNode || !window.WebAssembly) return false;
    // iPadOS can identify as macOS. This model needs desktop memory and storage budgets.
    return !/Android|Mobile/i.test(navigator.userAgent)
      && !(navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  }

  private worker: Worker | null = null;
  private ready = false;
  private preparation: Preparation | null = null;
  private stopRequest: (() => void) | null = null;
  private capture: MicrophoneCapture | null = null;
  private preview: Promise<void> | null = null;
  private previewsSlow = false;

  get audioLevel(): number { return this.capture?.audioLevel ?? 0; }

  /** Speculative setup never uses the download or microphone paths. */
  async prewarm(signal: AbortSignal): Promise<void> {
    try {
      if (signal.aborted || this.ready || this.preparation) return;
      // The last cached model file is a cheap setup hint. The worker checks every asset, including WASM.
      const tokenizer = await caches.match(modelAssets.tokenizer.url, { cacheName: parakeetCacheName });
      if (!tokenizer || signal.aborted || this.ready || this.preparation) return;
      const preparation = this.beginPrepare(false);
      const abort = () => {
        // Once Talk joins, only the explicit dictation lifecycle can cancel it.
        if (this.preparation === preparation && !preparation.onProgress) this.dispose();
      };
      signal.addEventListener("abort", abort, { once: true });
      try {
        await preparation.result;
      } finally {
        signal.removeEventListener("abort", abort);
      }
    } catch {
      // Background misses and failures never change the composer UI.
    }
  }

  async prepare(download: boolean, progress: (state: VoiceSetupProgress) => void): Promise<PrepareResult> {
    if (this.ready) return "ready";
    const preparation = this.preparation ?? this.beginPrepare(download);
    preparation.onProgress = progress;
    if (preparation.progress) progress(preparation.progress);
    return preparation.result;
  }

  private beginPrepare(download: boolean): Preparation {
    const preparation: Preparation = {
      result: this.request({ kind: "prepare", download }, state => {
        preparation.progress = state;
        preparation.onProgress?.(state);
      }).then((reply): PrepareResult => {
        if (this.preparation !== preparation || reply.kind !== "ready") return "needsDownload";
        this.ready = true;
        return "ready";
      }).finally(() => {
        if (this.preparation === preparation) this.preparation = null;
      }),
    };
    this.preparation = preparation;
    return preparation;
  }

  async start(interrupted: (message: string) => void, timeLimit: () => void, showPreview: (text: string) => void): Promise<void> {
    const capture = new MicrophoneCapture(interrupted, timeLimit, () => this.maybePreview(capture, showPreview));
    this.capture = capture;
    await capture.start();
  }

  private maybePreview(capture: MicrophoneCapture, showPreview: (text: string) => void): void {
    if (this.capture !== capture || !this.ready || this.preview || this.previewsSlow || document.hidden) return;
    const pcm = capture.previewAudio();
    if (!pcm) return;
    const start = performance.now();
    const preview = this.request({ kind: "transcribe", pcm }, undefined, true).then(reply => {
      if (this.capture !== capture) return;
      if (performance.now() - start > previewTimeBudgetMs) this.previewsSlow = true;
      if (capture.listening && reply.kind === "transcript") showPreview(reply.text.trim());
    }).catch(() => {
      if (this.capture === capture) this.previewsSlow = true;
    }).finally(() => {
      if (this.preview === preview) this.preview = null;
    });
    this.preview = preview;
  }

  async finish(): Promise<string> {
    const capture = this.capture;
    if (!capture) return "";
    // finish() closes preview admission synchronously, before flushing the last
    // worklet packet. A stale reply is ignored. At most the running call drains.
    const pcm = await capture.finish();
    await this.preview;
    if (this.capture !== capture) return "";
    if (!this.ready && await this.prepare(false, () => {}) !== "ready") {
      throw new Error("On-device dictation couldn't finish. Try again.");
    }
    if (this.capture !== capture) return "";
    this.capture = null;
    const reply = await this.request({ kind: "transcribe", pcm });
    return reply.kind === "transcript" ? reply.text : "";
  }

  cancel(): void {
    this.closeCapture();
    if (this.stopRequest) this.dispose();
  }

  dispose(): void {
    this.closeCapture();
    this.resetWorker();
  }

  private resetWorker(): void {
    this.preparation = null;
    this.stopRequest?.();
    this.worker?.terminate();
    this.worker = null;
    this.ready = false;
  }

  private closeCapture(): void {
    this.capture?.close();
    this.capture = null;
    this.preview = null;
  }

  private request(message: ModelRequest, progress?: (state: VoiceSetupProgress) => void, preview = false): Promise<ModelReply> {
    const worker = this.worker ??= new Worker(new URL("./parakeet.worker.ts", import.meta.url), { type: "module" });
    return new Promise((resolve, reject) => {
      const cleanup = () => {
        window.clearTimeout(timeout);
        this.stopRequest = null;
        worker.onmessage = null;
        worker.onerror = null;
        worker.onmessageerror = null;
      };
      const fail = (message: string, workerLost = true) => {
        cleanup();
        if (!preview) this.dispose();
        else if (workerLost) this.resetWorker(); // Keep the original capture for the final.
        reject(new Error(message));
      };
      this.stopRequest = () => { cleanup(); reject(new DOMException("Cancelled", "AbortError")); };
      const timeout = window.setTimeout(() => fail("On-device dictation timed out. Try again."), message.kind === "prepare" ? 600_000 : preview ? 4_000 : 60_000);
      worker.onerror = worker.onmessageerror = () => fail("On-device dictation stopped. Try a desktop browser with more available memory.");
      worker.onmessage = ({ data }: MessageEvent<ModelReply>) => {
        if (data.kind === "downloading" || data.kind === "loading") return progress?.(data);
        if (data.kind === "failed") return fail(data.message, false);
        cleanup();
        resolve(data);
      };
      try {
        if (message.kind === "transcribe") worker.postMessage(message, [message.pcm.buffer]);
        else worker.postMessage(message);
      } catch {
        fail(voiceMessages.interrupted);
      }
    });
  }
}

class MicrophoneCapture {
  private readonly audio = new AudioContext({ sampleRate: dictationSampleRate });
  private stream: MediaStream | null = null;
  private node: AudioWorkletNode | null = null;
  private chunks: Float32Array[] = [];
  private length = 0;
  private stopped: (() => void) | null = null;
  private closed = false;
  private finishing = false;
  private nextPreview = previewSamples;
  private audible = 0;
  audioLevel = 0;

  constructor(
    private readonly interrupted: (message: string) => void,
    private readonly timeLimit: () => void,
    private readonly recorded: () => void,
  ) {}

  get listening(): boolean { return !this.closed && !this.finishing; }

  previewAudio(): Float32Array | null {
    if (!this.listening || this.length < this.nextPreview || this.audible < dictationSampleRate / 5) return null;
    this.nextPreview = this.length + previewInterval;
    this.audible = 0;
    const pcm = new Float32Array(previewSamples);
    let end = previewSamples;
    for (let i = this.chunks.length - 1; i >= 0 && end > 0; i--) {
      const chunk = this.chunks[i]!;
      const count = Math.min(end, chunk.length);
      end -= count;
      pcm.set(chunk.subarray(chunk.length - count), end);
    }
    return pcm;
  }

  async start(): Promise<void> {
    const stream = await this.requestMicrophone();
    if (this.closed) {
      for (const track of stream.getTracks()) track.stop();
      return;
    }
    this.stream = stream;
    for (const track of stream.getAudioTracks()) track.onended = () => this.interrupted(voiceMessages.interrupted);
    await this.audio.audioWorklet.addModule(captureUrl);
    if (this.closed) return;
    const source = this.audio.createMediaStreamSource(stream);
    const node = new AudioWorkletNode(this.audio, "dictation-capture", { channelCount: 1, channelCountMode: "explicit" });
    this.node = node;
    node.onprocessorerror = () => this.interrupted(voiceMessages.interrupted);
    node.port.onmessage = ({ data }: MessageEvent<Float32Array | null>) => {
      if (data) this.record(data);
      else this.stopped?.();
    };
    source.connect(node).connect(this.audio.destination);
    await this.audio.resume();
  }

  private async requestMicrophone(): Promise<MediaStream> {
    try {
      return await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true }, video: false });
    } catch (error) {
      if (error instanceof DOMException && error.name === "NotAllowedError") throw new Error(voiceMessages.microphoneDenied);
      throw new Error("No microphone is available. Connect one and try again.");
    }
  }

  private record(samples: Float32Array): void {
    if (this.closed) return;
    const count = Math.min(samples.length, maxDictationSamples - this.length);
    if (!count) return;
    const audio = samples.subarray(0, count);
    this.chunks.push(audio);
    this.length += count;
    this.audioLevel = Math.sqrt(audio.reduce((sum, sample) => sum + sample * sample, 0) / count);
    if (this.audioLevel >= 0.003) this.audible = Math.min(previewSamples, this.audible + count);
    else this.audible = Math.max(0, this.audible - count);
    if (!this.listening) return;
    if (this.length >= maxDictationSamples) this.timeLimit();
    else this.recorded();
  }

  async finish(): Promise<Float32Array> {
    this.finishing = true;
    await new Promise<void>(resolve => {
      const timeout = window.setTimeout(() => this.stopped?.(), 250);
      this.stopped = () => { window.clearTimeout(timeout); resolve(); };
      this.node?.port.postMessage("stop");
    });
    const pcm = new Float32Array(this.length);
    let offset = 0;
    for (const chunk of this.chunks) {
      pcm.set(chunk, offset);
      offset += chunk.length;
    }
    this.close();
    return pcm;
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.stopped?.();
    this.stopped = null;
    this.node?.port.close();
    this.node?.disconnect();
    this.node = null;
    for (const track of this.stream?.getTracks() ?? []) track.stop();
    this.stream = null;
    this.chunks = [];
    this.length = 0;
    void this.audio.close().catch(() => {});
  }
}
