import captureUrl from "./dictation-capture.js?url&no-inline";
import { dictationSampleRate, maxDictationSamples, type ModelReply, type ModelRequest } from "./parakeet-assets.ts";
import { voiceMessages, type DictationEngine, type VoiceSetupProgress } from "./voice.ts";

export const dictationUnavailable = "On-device dictation needs a supported desktop browser.";

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
  private stopRequest: (() => void) | null = null;
  private capture: MicrophoneCapture | null = null;

  get audioLevel(): number { return this.capture?.audioLevel ?? 0; }

  async prepare(download: boolean, progress: (state: VoiceSetupProgress) => void): Promise<"ready" | "needsDownload"> {
    if (this.ready) return "ready";
    const reply = await this.request({ kind: "prepare", download }, progress);
    if (reply.kind !== "ready") return "needsDownload";
    this.ready = true;
    return "ready";
  }

  async start(interrupted: (message: string) => void, timeLimit: () => void): Promise<void> {
    const capture = new MicrophoneCapture(interrupted, timeLimit);
    this.capture = capture;
    await capture.start();
  }

  async finish(): Promise<string> {
    const capture = this.capture;
    if (!capture) return "";
    const pcm = await capture.finish();
    if (this.capture !== capture) return "";
    this.capture = null;
    const reply = await this.request({ kind: "transcribe", pcm });
    return reply.kind === "transcript" ? reply.text : "";
  }

  cancel(): void {
    this.capture?.close();
    this.capture = null;
    if (this.stopRequest) this.dispose();
  }

  dispose(): void {
    this.stopRequest?.();
    this.worker?.terminate();
    this.worker = null;
    this.ready = false;
  }

  private request(message: ModelRequest, progress?: (state: VoiceSetupProgress) => void): Promise<ModelReply> {
    const worker = this.worker ??= new Worker(new URL("./parakeet.worker.ts", import.meta.url), { type: "module" });
    return new Promise((resolve, reject) => {
      const cleanup = () => {
        window.clearTimeout(timeout);
        this.stopRequest = null;
        worker.onmessage = null;
        worker.onerror = null;
        worker.onmessageerror = null;
      };
      const fail = (message: string) => {
        cleanup();
        this.dispose();
        reject(new Error(message));
      };
      this.stopRequest = () => { cleanup(); reject(new DOMException("Cancelled", "AbortError")); };
      const timeout = window.setTimeout(() => fail("On-device dictation timed out. Try again."), message.kind === "prepare" ? 600_000 : 60_000);
      worker.onerror = worker.onmessageerror = () => fail("On-device dictation stopped. Try a desktop browser with more available memory.");
      worker.onmessage = ({ data }: MessageEvent<ModelReply>) => {
        if (data.kind === "downloading" || data.kind === "loading") return progress?.(data);
        if (data.kind === "failed") return fail(data.message);
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
  audioLevel = 0;

  constructor(private readonly interrupted: (message: string) => void, private readonly timeLimit: () => void) {}

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
    if (this.length >= maxDictationSamples && !this.finishing) this.timeLimit();
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
