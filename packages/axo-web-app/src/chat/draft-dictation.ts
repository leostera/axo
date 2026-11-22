import { appendTranscript, VoicePrompt, type DictationEngine } from "./voice.ts";
import { maxMessageBytes, type ChatWorkbench } from "./workbench.ts";

const encoder = new TextEncoder();

/** Lives with the account's workbench rather than with a particular composer. */
export class DraftDictation {
  readonly voice: VoicePrompt;
  private origin: { key: string; left: boolean } | null = null;

  constructor(private readonly workbench: ChatWorkbench, private readonly engine: DictationEngine & {
    prewarm(signal: AbortSignal): Promise<void>;
    dispose(): void;
  }) {
    this.voice = new VoicePrompt(engine);
  }

  prewarm(signal: AbortSignal): Promise<void> {
    return this.engine.prewarm(signal);
  }

  /** Putting the composer away stops the microphone, not transcription of captured audio. */
  composerHidden(): void {
    if (this.origin && this.voice.state.kind !== "finishing") this.cancel();
  }

  get forSelection(): VoicePrompt | null {
    return !this.origin || this.origin.key === this.workbench.selectedDraftKey ? this.voice : null;
  }

  connect(): () => void {
    const stopVoice = this.voice.subscribe(() => this.voiceChanged());
    const stopWorkbench = this.workbench.subscribe(() => this.selectionChanged());
    return () => {
      stopWorkbench();
      stopVoice();
      this.origin = null;
      this.voice.cancel();
      this.engine.dispose();
    };
  }

  private selectionChanged(): void {
    const origin = this.origin;
    if (!origin || origin.key === this.workbench.selectedDraftKey) return;
    // Let recorded audio finish, but never submit it after leaving its draft.
    origin.left = true;
    if (this.voice.state.kind !== "finishing") this.cancel();
  }

  private voiceChanged(): void {
    const kind = this.voice.state.kind;
    if (!this.origin && (kind === "checking" || kind === "downloading")) {
      const key = this.workbench.selectedDraftKey;
      if (key) this.origin = { key, left: false };
    }
    if (kind === "failed" && this.origin?.left && !this.forSelection) this.cancel();
    if (kind !== "idle") return;

    const origin = this.origin;
    this.origin = null;
    const transcript = this.voice.consume();
    if (!origin || !transcript) return;
    const workbench = this.workbench;
    const draft = workbench.appendToDraft(origin.key, text => appendTranscript(text, transcript.text));
    const agentReady = workbench.selection?.kind !== "new"
      || workbench.availableCodingAgents?.includes(workbench.newChatAgent) === true;
    if (transcript.delivery === "send" && !origin.left && workbench.selectedDraftKey === origin.key
      && workbench.canSendToSelection && agentReady && encoder.encode(draft).length <= maxMessageBytes) {
      void workbench.send();
    }
  }

  private cancel(): void {
    this.origin = null;
    this.voice.cancel();
  }
}
