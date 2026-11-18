import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Container, SelectList, Spacer, Text } from "@earendil-works/pi-tui";

export interface PiElicitation {
  id: string;
  title: string;
  message: string;
  expiresAt: number;
}
export type PiElicitationAnswer = "accept" | "decline" | "cancel";

// Request text is data, not terminal control sequences. Preserve ordinary text and newlines.
export function terminalQuestion(text: string): string {
  return text.replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/gu, "");
}

export async function selectElicitation(context: ExtensionContext, request: PiElicitation,
  signal: AbortSignal): Promise<PiElicitationAnswer> {
  if (!context.hasUI || signal.aborted) return "cancel";
  const title = terminalQuestion(request.title), message = terminalQuestion(request.message);
  if (context.mode !== "tui") {
    const choice = await context.ui.select(`${title}\n${message}`, ["Yes", "No"], { signal });
    return choice === "Yes" ? "accept" : choice === "No" ? "decline" : "cancel";
  }
  return context.ui.custom<PiElicitationAnswer>((tui, theme, _keys, done) => {
    let finished = false;
    const finish = (answer: PiElicitationAnswer) => {
      if (finished) return;
      finished = true;
      signal.removeEventListener("abort", aborted);
      done(answer);
    };
    const aborted = () => finish("cancel");
    const container = new Container();
    container.addChild(new Text(theme.bold(title), 0, 0));
    container.addChild(new Text(message, 0, 0));
    container.addChild(new Spacer(1));
    const choices = new SelectList([
      { value: "accept", label: "Yes" }, { value: "decline", label: "No" },
    ], 2, {
      selectedPrefix: text => theme.fg("accent", text),
      selectedText: text => theme.fg("accent", text),
      description: text => theme.fg("muted", text),
      scrollInfo: text => theme.fg("dim", text),
      noMatch: text => theme.fg("dim", text),
    });
    choices.onSelect = item => finish(item.value === "accept" ? "accept" : "decline");
    choices.onCancel = () => finish("cancel");
    container.addChild(choices);
    signal.addEventListener("abort", aborted, { once: true });
    if (signal.aborted) aborted();
    return {
      render: (width: number) => container.render(width),
      invalidate: () => container.invalidate(),
      handleInput: (data: string) => { choices.handleInput(data); tui.requestRender(); },
      dispose: () => signal.removeEventListener("abort", aborted),
    };
  });
}

/** One owned UI prompt at a time. Dismissal, expiry and identity loss never become consent. */
export class PiElicitations {
  private active?: { request: PiElicitation; abort: AbortController; timer: ReturnType<typeof setTimeout> };
  private readonly settled = new Set<string>();
  private readonly queued: Array<{ request: PiElicitation; context: ExtensionContext; isCurrent: () => boolean }> = [];
  private closed = false;

  constructor(private readonly answer: (id: string, action: PiElicitationAnswer) => Promise<void>,
    private readonly show = selectElicitation, private readonly now = () => Date.now()) {}

  present(request: PiElicitation, context: ExtensionContext, isCurrent: () => boolean): "shown" | "busy" | "unavailable" | "stale" {
    if (this.closed || this.settled.has(request.id) || request.expiresAt <= this.now() || !isCurrent()) return "stale";
    if (!context.hasUI) return "unavailable";
    if (this.active?.request.id === request.id || this.queued.some(item => item.request.id === request.id)) return "stale";
    if (this.active) {
      if (this.queued.length >= 32) return "busy";
      this.queued.push({ request, context, isCurrent });
      return "shown";
    }
    const abort = new AbortController();
    const timer = setTimeout(() => this.dismiss(request.id), Math.min(300_000, request.expiresAt - this.now()));
    timer.unref();
    const active = { request, abort, timer };
    this.active = active;
    void (async () => this.show(context, request, abort.signal))().then(async action => {
      if (this.active !== active || abort.signal.aborted || !isCurrent() || request.expiresAt <= this.now()) return;
      this.remember(request.id);
      await this.answer(request.id, action);
    }).catch(() => {
      // No inferred answer and no automatic retry after UI or transport failure.
      if (!abort.signal.aborted && isCurrent()) context.ui.notify("Axo did not confirm your answer. Review the request in Axo.", "warning");
    }).finally(() => {
      clearTimeout(timer);
      if (this.active === active) this.active = undefined;
      this.showNext();
    });
    return "shown";
  }

  dismiss(id: string): void {
    this.remember(id);
    const queued = this.queued.findIndex(item => item.request.id === id);
    if (queued >= 0) this.queued.splice(queued, 1);
    if (this.active?.request.id !== id) return;
    const active = this.active;
    clearTimeout(active.timer);
    active.abort.abort();
  }

  disconnect(): void {
    for (const { request } of this.queued.splice(0)) this.remember(request.id);
    if (this.active) this.dismiss(this.active.request.id);
  }

  close(): void {
    this.closed = true;
    this.disconnect();
  }

  private showNext(): void {
    while (!this.active && !this.closed && this.queued.length) {
      const next = this.queued.shift()!;
      this.present(next.request, next.context, next.isCurrent);
    }
  }

  private remember(id: string): void {
    this.settled.add(id);
    if (this.settled.size > 128) this.settled.delete(this.settled.values().next().value!);
  }
}
