export type VoiceState =
  | { kind: "idle" }
  | { kind: "checking" }
  | { kind: "needsDownload" }
  | { kind: "downloading"; percent: number }
  | { kind: "loading" }
  | { kind: "requestingPermission" }
  | { kind: "listening" }
  | { kind: "finishing" }
  | { kind: "failed"; message: string };

export type VoiceDelivery = "draft" | "send";
export type VoiceSetupProgress = Extract<VoiceState, { kind: "downloading" | "loading" }>;

export interface VoiceTranscript {
  readonly text: string;
  readonly delivery: VoiceDelivery;
}

export function appendTranscript(draft: string, text: string): string {
  if (!draft) return text;
  return /\s$/.test(draft) ? draft + text : `${draft} ${text}`;
}

export interface DictationEngine {
  readonly audioLevel: number;
  prepare(download: boolean, progress: (state: VoiceSetupProgress) => void): Promise<"ready" | "needsDownload">;
  start(interrupted: (message: string) => void, timeLimit: () => void, preview: (text: string) => void): Promise<void>;
  finish(): Promise<string>;
  cancel(): void;
}

export const voiceMessages = {
  microphoneDenied: "Microphone access is off. Allow it for this site in the browser, then try again.",
  noSpeech: "Nothing was heard. Try again a little closer to the microphone.",
  interrupted: "Listening was interrupted. Try again.",
} as const;

export class VoicePrompt {
  state: VoiceState = { kind: "idle" };
  transcript: VoiceTranscript | null = null;
  preview = "";
  version = 0;
  private readonly listeners = new Set<() => void>();
  /** Setup and inference can report back after Cancel or a change of chat. */
  private generation = 0;

  private readonly engine: DictationEngine;

  constructor(engine: DictationEngine) {
    this.engine = engine;
  }

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getVersion = (): number => this.version;

  private set(state: VoiceState): void {
    this.state = state;
    this.version += 1;
    for (const listener of this.listeners) listener();
  }

  get isBusy(): boolean {
    return !["idle", "failed", "needsDownload"].includes(this.state.kind);
  }

  get audioLevel(): number {
    const level = this.engine.audioLevel;
    return Number.isFinite(level) ? Math.min(1, Math.max(0, level)) : 0;
  }

  async start(download = false): Promise<void> {
    if (this.isBusy || (download && this.state.kind !== "needsDownload")) return;
    this.transcript = null;
    const current = ++this.generation;
    this.set(download ? { kind: "downloading", percent: 0 } : { kind: "checking" });
    try {
      const readiness = await this.engine.prepare(download, progress => {
        if (current === this.generation) this.set(progress);
      });
      if (current !== this.generation) return;
      if (readiness === "needsDownload") return this.set({ kind: "needsDownload" });
      this.set({ kind: "requestingPermission" });
      await this.engine.start(
        message => { if (current === this.generation) this.cancel(message); },
        () => { if (current === this.generation) void this.finish("draft"); },
        text => {
          if (current !== this.generation || this.state.kind !== "listening" || this.preview === text) return;
          this.preview = text;
          this.set(this.state);
        },
      );
      if (current === this.generation) this.set({ kind: "listening" });
    } catch (error) {
      this.fail(error, current);
    }
  }

  async finish(delivery: VoiceDelivery): Promise<void> {
    if (this.state.kind !== "listening") return;
    const current = this.generation;
    this.preview = "";
    this.set({ kind: "finishing" });
    try {
      const text = (await this.engine.finish()).trim();
      if (current !== this.generation) return;
      if (!text) return this.set({ kind: "failed", message: voiceMessages.noSpeech });
      this.transcript = { text, delivery };
      this.set({ kind: "idle" });
    } catch (error) {
      this.fail(error, current);
    }
  }

  cancel(failure?: string): void {
    this.transcript = null;
    this.preview = "";
    this.generation += 1;
    this.engine.cancel();
    if (this.state.kind !== "idle") this.set(failure ? { kind: "failed", message: failure } : { kind: "idle" });
  }

  /** The screen has put this dictation in the box or sent it. */
  consume(): VoiceTranscript | null {
    const transcript = this.transcript;
    this.transcript = null;
    return transcript;
  }

  private fail(error: unknown, current: number): void {
    if (current === this.generation) this.cancel(error instanceof Error ? error.message : voiceMessages.interrupted);
  }
}

/** Quiet speech shows, silence stays flat, −18 dB and up fills the meter. */
export function waveformHeight(amplitude: number): number {
  if (!Number.isFinite(amplitude) || amplitude <= 0) return 0;
  const decibels = 20 * Math.log10(Math.min(1, amplitude));
  return Math.min(1, Math.max(0, (decibels + 60) / 42)) ** 0.7;
}
