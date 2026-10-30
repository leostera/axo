import { useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore, type ClipboardEvent, type KeyboardEvent } from "react";
import { AxoMascot } from "../axo-mascot.tsx";
import { Icon } from "./icons.tsx";
import { MessageView, PendingView, QuestionCard } from "./message-views.tsx";
import { Alert } from "./alert.tsx";
import { appendTranscript, BrowserDictation, VoicePrompt, waveformHeight } from "./voice.ts";
import { chatTitle, type ChatWorkbench } from "./workbench.ts";

/** How close to the bottom still counts as following the conversation. */
const FOLLOW_SLACK_PX = 80;
/** How close to the top starts reading the page before. */
const OLDER_SLACK_PX = 400;

/**
 * The open chat, or a new one, as on the phone: no title (its name only takes room; screen readers
 * still hear it), the menu button, the Mac's trouble when it has any, the transcript, what Axo is
 * doing with a way to stop it, and the message box.
 */
export function Conversation({ workbench, wide, onShowChats, onToggleInfo, voice: givenVoice }: {
  workbench: ChatWorkbench;
  wide: boolean;
  onShowChats: () => void;
  onToggleInfo: () => void;
  /** Tests give their own; otherwise the browser's speech recognition, where there is one. */
  voice?: VoicePrompt | null;
}) {
  const host = workbench.openHost;
  const session = workbench.selectedSession;
  const selection = workbench.selection;
  const chat = session ? workbench.chat(session.sessionId) : null;
  const transcript = chat?.transcript ?? null;
  const online = host?.status === "online" && workbench.link === "connected";
  const voice = useMemo(() => givenVoice !== undefined ? givenVoice : BrowserDictation.supported ? new VoicePrompt(new BrowserDictation()) : null, [givenVoice]);

  const scroller = useRef<HTMLDivElement>(null);
  const following = useRef(true);
  const [showJump, setShowJump] = useState(false);
  const [hasNew, setHasNew] = useState(false);
  const [confirmingStop, setConfirmingStop] = useState(false);
  /** The height before an older page went in above, to keep the view still. */
  const heightBeforeOlder = useRef<number | null>(null);
  const messageCount = transcript?.messages.length ?? 0;
  const firstId = transcript?.messages[0]?.id;

  // A new chat on screen starts at its newest message.
  useEffect(() => {
    following.current = true;
    setShowJump(false);
    setHasNew(false);
  }, [session?.sessionId, selection?.kind]);

  useLayoutEffect(() => {
    const element = scroller.current;
    if (!element) return;
    if (heightBeforeOlder.current !== null) {
      element.scrollTop += element.scrollHeight - heightBeforeOlder.current;
      heightBeforeOlder.current = null;
      return;
    }
    if (following.current) element.scrollTop = element.scrollHeight;
    else setHasNew(true);
  }, [workbench.version, firstId]);

  const onScroll = () => {
    const element = scroller.current;
    if (!element || !session) return;
    following.current = element.scrollHeight - element.scrollTop - element.clientHeight < FOLLOW_SLACK_PX;
    setShowJump(!following.current);
    if (following.current) setHasNew(false);
    if (element.scrollTop < OLDER_SLACK_PX && chat?.history.kind === "loaded" && chat.history.hasOlder) {
      heightBeforeOlder.current = element.scrollHeight;
      void workbench.loadOlderHistory(session.sessionId);
    }
  };

  const jumpToEnd = () => {
    const element = scroller.current;
    if (!element) return;
    following.current = true;
    setShowJump(false);
    setHasNew(false);
    element.scrollTo({ top: element.scrollHeight, behavior: "smooth" });
  };

  const send = async () => {
    following.current = true;
    await workbench.send();
  };

  const working = Boolean(transcript?.working);
  const canStop = online && working && !chat?.stopping;
  const history = chat?.history ?? { kind: "none" as const };
  const empty = !session || (messageCount === 0 && !transcript?.live.length && !chat?.pending.length);
  const trouble = !host ? null
    : host.status !== "online" ? `${host.label} is offline`
      : workbench.link === "reconnecting" ? `Reconnecting to ${host.label}…` : null;
  const activityTitle = chat?.stopping ? "Stopping…"
    : transcript?.question ? "Waiting for your answer"
      : transcript?.messages.some(message => message.tool?.status === "running") ? "Using tools…" : "Thinking…";

  return (
    <section className="conversation" aria-label="Conversation">
      <header className="layer-bar top conversation-header">
        <h1 className="visually-hidden">{chatTitle(session)}</h1>
        {wide ? <span className="circle-placeholder" /> : (
          <button className="circle-button" onClick={onShowChats} aria-label="Chats menu"><Icon name="menu" /></button>
        )}
        <span className="spacer" />
        {trouble ? <span className="host-trouble" role="status">{trouble}</span> : null}
        <span className="spacer" />
        <button className="circle-button" onClick={onToggleInfo} aria-label="Chat info"><Icon name="info" /></button>
      </header>

      <div className="transcript" ref={scroller} onScroll={onScroll} data-testid="transcript">
        <div className="transcript-column">
          {history.kind === "loadingOlder" ? <p className="history-note">Loading earlier messages…</p> : null}
          {history.kind === "loaded" && history.hasOlder ? (
            <button className="history-note link" onClick={() => {
              if (!session) return;
              heightBeforeOlder.current = scroller.current?.scrollHeight ?? null;
              void workbench.loadOlderHistory(session.sessionId);
            }}>Load earlier messages</button>
          ) : null}
          {history.kind === "failed" ? (
            <p className="history-note warning">Could not read this chat: {history.message} <button className="link" onClick={() => session && void workbench.loadHistory(session.sessionId)}>Try again</button></p>
          ) : null}
          {history.kind === "loading" && empty ? <p className="history-note">Loading the chat…</p> : null}

          {empty && history.kind !== "loading" ? (
            <div className="empty-chat">
              <AxoMascot className="empty-chat-mascot" />
              <h2>What are we working on?</h2>
              <p>{session ? "Nothing here yet." : !host ? "Pair a Mac to start chatting." : host.status === "online" ? "Send a message to start a chat." : "Your Mac is offline."}</p>
            </div>
          ) : null}

          {transcript?.messages.map(message => <MessageView key={message.id} message={message} working={transcript.working} />)}
          {transcript?.live.map(message => <MessageView key={message.id} message={message} working live />)}
          {session && chat?.pending.map(prompt => (
            <PendingView
              key={prompt.id}
              prompt={prompt}
              onEditAgain={() => {
                workbench.setDraft(prompt.text);
                workbench.dismissPending(session.sessionId, prompt.id);
              }}
              onDismiss={() => workbench.dismissPending(session.sessionId, prompt.id)}
            />
          ))}
          {session && transcript?.question ? (
            <QuestionCard
              question={transcript.question}
              canAnswer={online}
              onAnswer={answer => void workbench.answer(session.sessionId, answer)}
            />
          ) : null}
          {session && working ? (
            <div className="agent-activity" data-testid="agent-activity">
              <span className="agent-activity-icon"><Icon name="sparkles" size={18} /></span>
              <span className="agent-activity-title">{activityTitle}</span>
              <span className="spacer" />
              <span className="spinner" aria-hidden="true" />
              <button className="plain-icon-button agent-activity-stop" onClick={() => setConfirmingStop(true)}
                disabled={!canStop} aria-label="Stop the reply">
                <Icon name="closeCircle" size={22} />
              </button>
            </div>
          ) : null}
        </div>
      </div>

      <footer className="layer-bar bottom conversation-footer">
        {workbench.failure ? (
          <div className="chat-failure" role="alert">
            <span>{workbench.failure}</span>
            <button className="plain-icon-button" onClick={() => workbench.dismissFailure()} aria-label="Dismiss"><Icon name="close" size={14} /></button>
          </div>
        ) : null}
        {showJump ? (
          <button className={hasNew ? "jump-button with-label" : "jump-button"} onClick={jumpToEnd}
            aria-label={hasNew ? "Jump to new message" : "Jump to latest"}>
            <Icon name="arrowDown" size={18} />{hasNew ? <span>Jump to new message</span> : null}
          </button>
        ) : null}
        <Composer
          workbench={workbench}
          voice={voice}
          placeholder={!host ? "Your Mac is offline" : host.status !== "online" ? `${host.label} is offline` : "Message Axo"}
          canSend={Boolean(host && host.status === "online")}
          onSend={() => void send()}
          onEscape={() => { if (canStop) setConfirmingStop(true); }}
        />
      </footer>
      {confirmingStop ? (
        <Alert
          title="Stop the reply?"
          message="This stops everything the agent is doing now, including the tools it is running."
          confirm="Stop"
          cancel="Keep going"
          destructive
          onConfirm={() => {
            setConfirmingStop(false);
            if (session) void workbench.stop(session.sessionId);
          }}
          onCancel={() => setConfirmingStop(false)}
        />
      ) : null}
    </section>
  );
}

/** The most a message can be: the Mac takes up to 16,000 bytes of text. */
export const maxMessageBytes = 16_000;
const encoder = new TextEncoder();

/**
 * The message box, as on the phone. An empty box offers voice where Send goes; once something is
 * typed, Send. While listening the box becomes the listening bar. Enter sends and Shift-Enter
 * starts a new line.
 */
function Composer({ workbench, voice, placeholder, canSend, onSend, onEscape }: {
  workbench: ChatWorkbench;
  voice: VoicePrompt | null;
  placeholder: string;
  canSend: boolean;
  onSend: () => void;
  /** Escape with nothing to cancel: asks to stop the reply. */
  onEscape: () => void;
}) {
  const draft = workbench.draft();
  const field = useRef<HTMLTextAreaElement>(null);
  const hasDraft = draft.trim().length > 0;
  const bytes = encoder.encode(draft).length;
  const tooLong = bytes > maxMessageBytes;
  const ready = canSend && hasDraft && !tooLong && !workbench.isSending;
  /** Where the caret goes once a paste is in, after React has put the new words in the box. */
  const caret = useRef<number | null>(null);
  useSyncExternalStore(voice?.subscribe ?? noSubscribe, voice?.getVersion ?? zero);
  const voiceState = voice?.state.kind ?? "idle";
  const listening = voiceState === "listening" || voiceState === "finishing";

  useLayoutEffect(() => {
    const element = field.current;
    if (!element) return;
    element.style.height = "auto";
    element.style.height = `${Math.min(element.scrollHeight, 220)}px`;
    if (caret.current !== null) {
      element.setSelectionRange(caret.current, caret.current);
      caret.current = null;
    }
  }, [draft, listening]);

  useEffect(() => {
    if (window.matchMedia("(pointer: fine)").matches) field.current?.focus();
  }, [workbench.selection]);

  // Words said for one chat never land in another.
  useEffect(() => () => voice?.cancel(), [workbench.selection, voice]);

  // A finished dictation goes after what is typed, and is sent if Send ended it.
  useEffect(() => {
    const transcript = voice?.transcript;
    if (!voice || !transcript) return;
    voice.consume(transcript);
    workbench.setDraft(appendTranscript(workbench.draft(), transcript.text));
    if (transcript.delivery === "send" && canSend && !workbench.isSending) onSend();
    else if (window.matchMedia("(pointer: fine)").matches) field.current?.focus();
  }, [voice?.version]);

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
      event.preventDefault();
      if (ready) onSend();
    } else if (event.key === "Escape" && !hasDraft) {
      event.preventDefault();
      onEscape();
    }
  };

  // Pasted words go in as plain text where the caret is, whatever the clipboard also carries.
  const onPaste = (event: ClipboardEvent<HTMLTextAreaElement>) => {
    const text = event.clipboardData.getData("text/plain").replace(/\r\n?/g, "\n");
    if (!text) return;
    event.preventDefault();
    const element = event.currentTarget;
    const start = element.selectionStart ?? draft.length;
    const end = element.selectionEnd ?? draft.length;
    caret.current = start + text.length;
    workbench.setDraft(draft.slice(0, start) + text + draft.slice(end));
  };

  return (
    <div className="composer-stack">
      {voice ? <VoiceStatusCard voice={voice} /> : null}
      {tooLong ? <p className="composer-note" role="status">Too long to send: {bytes.toLocaleString()} of {maxMessageBytes.toLocaleString()} bytes.</p> : null}
      {voice && listening ? <VoiceListeningBar voice={voice} canSend={canSend} /> : (
        <form className="composer" onSubmit={event => {
          event.preventDefault();
          if (ready) onSend();
        }}>
          <textarea
            ref={field}
            rows={1}
            value={draft}
            placeholder={placeholder}
            aria-label="Message"
            disabled={!canSend}
            onChange={event => workbench.setDraft(event.target.value)}
            onKeyDown={onKeyDown}
            onPaste={onPaste}
          />
          {voice && !hasDraft ? (
            <button type="button" className={canSend ? "round-button primary" : "round-button"}
              disabled={!canSend || voice.isBusy} onClick={() => void voice.start()}
              aria-label="Talk" title="Say your message; stop to read it first, or send it straight away">
              {voiceState === "requestingPermission" ? <span className="spinner inverse" aria-hidden="true" /> : <Icon name="waveform" size={20} />}
            </button>
          ) : (
            <button className={ready ? "round-button primary" : "round-button"} disabled={!ready} aria-label="Send">
              <Icon name="arrowUp" size={20} />
            </button>
          )}
        </form>
      )}
    </div>
  );
}

const noSubscribe = () => () => {};
const zero = () => 0;

/** While listening, the message box becomes this: the words as heard, how loud, and what to do with them. */
function VoiceListeningBar({ voice, canSend }: { voice: VoicePrompt; canSend: boolean }) {
  const state = voice.state;
  const finishing = state.kind === "finishing";
  const heard = state.kind === "listening" ? state.heard : { settled: "", tentative: "" };
  const empty = !heard.settled && !heard.tentative;

  useEffect(() => {
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") voice.cancel();
      else if (event.key === "Enter" && !finishing) {
        event.preventDefault();
        void voice.finish(canSend ? "send" : "draft");
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [voice, finishing, canSend]);

  return (
    <div className="composer voice-listening" role="group" aria-label="Listening">
      <p className="voice-heard" aria-live="polite">
        {empty ? <span className="voice-placeholder">{finishing ? "Finishing…" : "Listening…"}</span> : (
          <>{heard.settled}{heard.settled && heard.tentative ? " " : ""}<span className="voice-tentative">{heard.tentative}</span></>
        )}
      </p>
      <div className="voice-controls">
        <button type="button" className="round-button inset" onClick={() => voice.cancel()} aria-label="Cancel"><Icon name="close" size={17} /></button>
        {finishing ? <span className="voice-finishing"><span className="spinner" aria-hidden="true" /></span> : <VoiceWaveform voice={voice} />}
        <button type="button" className="round-button inset" onClick={() => void voice.finish("draft")} disabled={finishing}
          aria-label="Stop" title="Put the words in the message box to read first"><Icon name="stopFill" size={16} /></button>
        <button type="button" className={canSend ? "round-button primary" : "round-button"} onClick={() => void voice.finish("send")}
          disabled={!canSend || finishing} aria-label="Send" title="Send what you said"><Icon name="arrowUp" size={20} /></button>
      </div>
    </div>
  );
}

const WAVEFORM_BARS = 30;

/** The microphone's loudness over the last second and a half, as bars. Only measured levels are drawn. */
function VoiceWaveform({ voice }: { voice: VoicePrompt }) {
  const [levels, setLevels] = useState<number[]>(() => Array(WAVEFORM_BARS).fill(0));
  useEffect(() => {
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const timer = window.setInterval(() => setLevels(previous => [...previous.slice(1), voice.audioLevel]), reduce ? 200 : 50);
    return () => window.clearInterval(timer);
  }, [voice]);
  return (
    <span className="voice-waveform" aria-hidden="true">
      {levels.map((level, index) => <span key={index} style={{ height: `${Math.max(3, waveformHeight(level) * 30)}px` }} />)}
    </span>
  );
}

/** Why voice did not work, above the box. */
function VoiceStatusCard({ voice }: { voice: VoicePrompt }) {
  if (voice.state.kind !== "failed") return null;
  return (
    <div className="voice-card" role="alert">
      <span className="voice-card-icon"><Icon name="micSlash" size={18} /></span>
      <span className="voice-card-message">{voice.state.message}</span>
      <button className="plain-icon-button" onClick={() => voice.dismissFailure()} aria-label="Dismiss"><Icon name="close" size={14} /></button>
    </div>
  );
}
