/**
 * Voice prompting: a port of the phone's `VoicePrompt`. Tap to listen, see the words as they are
 * heard, then Stop to put them in the box or Send to send them. Words heard after a cancel never
 * come back, and a finished dictation is handed over once, as `transcript`.
 */

/** What has been heard so far: words the recogniser has settled on, and its guess at the last few. */
export interface HeardText {
  readonly settled: string;
  readonly tentative: string;
}

export type VoiceState =
  | { kind: "idle" }
  | { kind: "requestingPermission" }
  | { kind: "listening"; heard: HeardText }
  /** Listening stopped; the last words are being settled. */
  | { kind: "finishing" }
  | { kind: "failed"; message: string };

/** Only an explicit Send sends; Stop, or the recogniser ending, puts the words in the box. */
export type VoiceDelivery = "draft" | "send";

export interface VoiceTranscript {
  readonly id: number;
  readonly text: string;
  readonly delivery: VoiceDelivery;
}

/** After what is already typed: what was typed is kept, and nothing dictated is cut. */
export function appendTranscript(draft: string, text: string): string {
  if (!draft) return text;
  return /\s$/.test(draft) ? draft + text : `${draft} ${text}`;
}

/** The microphone and the recogniser, as one: the browser's speech recognition, or a test's. */
export interface DictationEngine {
  /** Loudness now, 0...1, read only while the waveform is on screen. */
  readonly audioLevel: number;
  /** Asks for the microphone; false when it is refused. */
  requestPermission(): Promise<boolean>;
  /** Starts listening; what is heard arrives through `heard`, and `interrupted` says it ended badly. */
  start(heard: (text: HeardText) => void, interrupted: (message: string) => void): Promise<void>;
  /** Stops listening and returns everything heard, settled. */
  finish(): Promise<string>;
  /** Stops listening and forgets what was heard. */
  cancel(): void;
}

export const voiceMessages = {
  microphoneDenied: "Microphone access is off. Allow it for this site in the browser, then try again.",
  noSpeech: "Nothing was heard. Try again a little closer to the microphone.",
  interrupted: "Listening was interrupted. Try again.",
} as const;

export class VoicePrompt {
  state: VoiceState = { kind: "idle" };
  /** The last finished dictation, for the screen to put in the box or send. */
  transcript: VoiceTranscript | null = null;
  version = 0;

  private readonly engine: DictationEngine;
  private readonly listeners = new Set<() => void>();
  /** Each dictation's own number: what an older one reports after a cancel is ignored. */
  private generation = 0;
  private transcripts = 0;

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

  get isListening(): boolean {
    return this.state.kind === "listening";
  }

  /** Doing something: the box waits, and so does switching chats. */
  get isBusy(): boolean {
    return this.state.kind === "requestingPermission" || this.state.kind === "listening" || this.state.kind === "finishing";
  }

  get audioLevel(): number {
    const level = this.engine.audioLevel;
    return Number.isFinite(level) ? Math.min(1, Math.max(0, level)) : 0;
  }

  /** Asks for the microphone and starts listening: one tap. */
  async start(): Promise<void> {
    if (this.isBusy) return;
    this.transcript = null;
    const current = ++this.generation;
    this.set({ kind: "requestingPermission" });
    if (!(await this.engine.requestPermission())) return this.fail(voiceMessages.microphoneDenied, current);
    if (current !== this.generation) return;
    this.set({ kind: "listening", heard: { settled: "", tentative: "" } });
    try {
      await this.engine.start(
        heard => {
          if (current === this.generation && this.isListening) this.set({ kind: "listening", heard });
        },
        message => {
          if (current === this.generation && this.isListening) this.cancel(message);
        },
      );
      if (current !== this.generation) this.engine.cancel();
    } catch (error) {
      if (current !== this.generation) return;
      this.engine.cancel();
      this.set({ kind: "failed", message: error instanceof Error ? error.message : String(error) });
    }
  }

  /** Stops listening; the words go to the box (`draft`) or are sent (`send`). */
  async finish(delivery: VoiceDelivery): Promise<void> {
    if (!this.isListening) return;
    const current = this.generation;
    this.set({ kind: "finishing" });
    try {
      const text = (await this.engine.finish()).trim();
      if (current !== this.generation) return;
      if (!text) return this.fail(voiceMessages.noSpeech, current);
      this.transcript = { id: ++this.transcripts, text, delivery };
      this.set({ kind: "idle" });
    } catch (error) {
      if (current !== this.generation) return;
      this.set({ kind: "failed", message: error instanceof Error ? error.message : String(error) });
    }
  }

  /** Stops whatever is happening and forgets it: nothing heard reaches the box. */
  cancel(failure: string | null = null): void {
    if (!this.isBusy) return;
    this.generation += 1;
    this.transcript = null;
    this.engine.cancel();
    this.set(failure ? { kind: "failed", message: failure } : { kind: "idle" });
  }

  dismissFailure(): void {
    if (this.state.kind === "failed") this.set({ kind: "idle" });
  }

  /** The screen has put `transcript` in the box or sent it. */
  consume(transcript: VoiceTranscript): void {
    if (this.transcript?.id === transcript.id) this.transcript = null;
  }

  private fail(message: string, current: number): void {
    if (current === this.generation) this.set({ kind: "failed", message });
  }
}

/** How tall a waveform bar is for a loudness: quiet speech shows, silence stays flat, −18 dB and up is full. */
export function waveformHeight(amplitude: number): number {
  if (!Number.isFinite(amplitude) || amplitude <= 0) return 0;
  const decibels = 20 * Math.log10(Math.min(1, amplitude));
  return Math.min(1, Math.max(0, (decibels + 60) / 42)) ** 0.7;
}

// MARK: - The browser's engine

interface RecognitionResult { readonly isFinal: boolean; readonly 0: { readonly transcript: string } }
interface RecognitionEvent { readonly results: ArrayLike<RecognitionResult> }
interface Recognition {
  lang: string;
  continuous: boolean;
  interimResults: boolean;
  onresult: ((event: RecognitionEvent) => void) | null;
  onerror: ((event: { error: string }) => void) | null;
  onend: (() => void) | null;
  start(): void;
  stop(): void;
  abort(): void;
}
type RecognitionConstructor = new () => Recognition;

function recognitionConstructor(): RecognitionConstructor | null {
  if (typeof window === "undefined") return null;
  const scope = window as unknown as { SpeechRecognition?: RecognitionConstructor; webkitSpeechRecognition?: RecognitionConstructor };
  return scope.SpeechRecognition ?? scope.webkitSpeechRecognition ?? null;
}

const recognitionErrors: Record<string, string> = {
  "not-allowed": voiceMessages.microphoneDenied,
  "service-not-allowed": "This browser does not allow speech recognition here.",
  "audio-capture": "No microphone is available.",
  network: "Speech recognition needs a network connection in this browser.",
  "language-not-supported": "This browser cannot recognise speech in your language.",
};

/** Joins pieces of speech with single spaces. */
function joined(...parts: string[]): string {
  return parts.map(part => part.trim()).filter(Boolean).join(" ");
}

/**
 * The browser's speech recognition, with the microphone measured on the side for the waveform.
 * Browsers end a recognition on their own after a pause or a minute; while the person is still
 * listening it starts again, keeping what was settled, so only Stop, Send or Cancel end it.
 */
export class BrowserDictation implements DictationEngine {
  static get supported(): boolean {
    return recognitionConstructor() !== null && typeof navigator !== "undefined" && Boolean(navigator.mediaDevices?.getUserMedia);
  }

  private stream: MediaStream | null = null;
  private audio: AudioContext | null = null;
  private analyser: AnalyserNode | null = null;
  private samples: Float32Array<ArrayBuffer> | null = null;
  private recognition: Recognition | null = null;
  /** Settled by recognitions that have ended. */
  private carried = "";
  private settled = "";
  private tentative = "";
  private listening = false;
  private ended: (() => void) | null = null;

  get audioLevel(): number {
    if (!this.analyser || !this.samples) return 0;
    this.analyser.getFloatTimeDomainData(this.samples);
    let sum = 0;
    for (const sample of this.samples) sum += sample * sample;
    return Math.sqrt(sum / this.samples.length);
  }

  async requestPermission(): Promise<boolean> {
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
      return true;
    } catch {
      return false;
    }
  }

  async start(heard: (text: HeardText) => void, interrupted: (message: string) => void): Promise<void> {
    const Recognition = recognitionConstructor();
    if (!Recognition) throw new Error("This browser cannot recognise speech.");
    this.carried = "";
    this.settled = "";
    this.tentative = "";
    this.listening = true;
    this.meter();
    const report = () => heard({ settled: joined(this.carried, this.settled), tentative: this.tentative.trim() });
    const begin = () => {
      const recognition = new Recognition();
      recognition.lang = navigator.language || "en-US";
      recognition.continuous = true;
      recognition.interimResults = true;
      recognition.onresult = event => {
        let settled = "";
        let tentative = "";
        for (let index = 0; index < event.results.length; index += 1) {
          const result = event.results[index]!;
          if (result.isFinal) settled += result[0].transcript;
          else tentative += result[0].transcript;
        }
        this.settled = settled;
        this.tentative = tentative;
        report();
      };
      recognition.onerror = event => {
        if (event.error === "no-speech" || event.error === "aborted") return;
        this.listening = false;
        interrupted(recognitionErrors[event.error] ?? `Speech recognition stopped (${event.error}).`);
      };
      recognition.onend = () => {
        if (this.recognition !== recognition) return;
        // What was still a guess counts: some browsers never settle the last words on stop.
        this.carried = joined(this.carried, this.settled, this.tentative);
        this.settled = "";
        this.tentative = "";
        if (this.listening) {
          begin();
          return;
        }
        this.recognition = null;
        this.ended?.();
      };
      this.recognition = recognition;
      recognition.start();
    };
    begin();
  }

  finish(): Promise<string> {
    this.listening = false;
    const recognition = this.recognition;
    if (!recognition) {
      this.release();
      return Promise.resolve(this.carried);
    }
    return new Promise(resolve => {
      const done = () => {
        clearTimeout(timer);
        this.ended = null;
        this.release();
        resolve(joined(this.carried, this.settled, this.tentative));
      };
      // A browser that never says it ended still hands over what it heard.
      const timer = setTimeout(() => {
        this.recognition = null;
        done();
      }, 2_000);
      this.ended = done;
      recognition.stop();
    });
  }

  cancel(): void {
    this.listening = false;
    this.ended = null;
    const recognition = this.recognition;
    this.recognition = null;
    recognition?.abort();
    this.carried = "";
    this.settled = "";
    this.tentative = "";
    this.release();
  }

  private meter(): void {
    if (!this.stream || this.audio) return;
    try {
      this.audio = new AudioContext();
      const source = this.audio.createMediaStreamSource(this.stream);
      this.analyser = this.audio.createAnalyser();
      this.analyser.fftSize = 1024;
      this.samples = new Float32Array(this.analyser.fftSize);
      source.connect(this.analyser);
    } catch {
      this.analyser = null;
    }
  }

  private release(): void {
    for (const track of this.stream?.getTracks() ?? []) track.stop();
    this.stream = null;
    void this.audio?.close().catch(() => {});
    this.audio = null;
    this.analyser = null;
    this.samples = null;
  }
}
