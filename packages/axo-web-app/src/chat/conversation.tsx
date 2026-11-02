import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore, type ClipboardEvent, type KeyboardEvent, type TouchEvent, type WheelEvent } from "react";
import { AxoMascot } from "../axo-mascot.tsx";
import { Icon } from "./icons.tsx";
import { MessageView, PendingView, QuestionCard, type Reveal } from "./message-views.tsx";
import { Alert } from "./alert.tsx";
import { appendTranscript, BrowserDictation, VoicePrompt, waveformHeight } from "./voice.ts";
import type { ChatMessage, ChatTranscript } from "./transcript.ts";
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

  const shown = useShownMessages(session?.sessionId ?? null, transcript);
  const scroller = useRef<HTMLDivElement>(null);
  const following = useRef(true);
  const lastScrollTop = useRef(0);
  const [showJump, setShowJump] = useState(false);
  const [hasNew, setHasNew] = useState(false);
  const [confirmingStop, setConfirmingStop] = useState(false);
  /**
   * The message at the top of the view and how far down the view it sat. Whatever goes in above it
   * (an older page, a loading note) moves the scroll by as much, so what is read stays put.
   */
  const anchor = useRef<ScrollAnchor | null>(null);
  const messageCount = transcript?.messages.length ?? 0;
  const firstId = transcript?.messages[0]?.id;
  const lastId = transcript?.live.at(-1)?.id ?? transcript?.messages.at(-1)?.id;
  const seenLastId = useRef(lastId);

  // A new chat on screen starts at its newest message.
  useEffect(() => {
    following.current = true;
    anchor.current = null;
    setShowJump(false);
    setHasNew(false);
  }, [session?.sessionId, selection?.kind]);

  useLayoutEffect(() => {
    const element = scroller.current;
    if (!element) return;
    const grew = lastId !== seenLastId.current;
    seenLastId.current = lastId;
    if (following.current) {
      scrollToEnd(element);
    } else {
      restoreAnchor(element, anchor.current);
      if (grew) setHasNew(true);
    }
    anchor.current = findAnchor(element);
  }, [workbench.version, firstId]);

  // The bars float over the transcript, as in the phone app: the transcript leaves room under its
  // last message for however tall the message box has grown, and stays at the end if it was there.
  const section = useRef<HTMLElement>(null);
  const footer = useRef<HTMLElement>(null);
  useLayoutEffect(() => {
    const bar = footer.current;
    if (!bar) return;
    const fit = () => {
      section.current?.style.setProperty("--footer-height", `${bar.offsetHeight}px`);
      const element = scroller.current;
      if (element && following.current) scrollToEnd(element);
    };
    fit();
    const observer = new ResizeObserver(fit);
    observer.observe(bar);
    return () => observer.disconnect();
  }, []);

  // A reply let out a word at a time, or held messages showing once it is out, grow the transcript
  // with nothing new from the Mac: the view follows the end, or keeps what is read where it is.
  useLayoutEffect(() => {
    const element = scroller.current;
    const column = element?.firstElementChild;
    if (!element || !column) return;
    const observer = new ResizeObserver(() => {
      if (following.current) scrollToEnd(element);
      else restoreAnchor(element, anchor.current);
      anchor.current = findAnchor(element);
    });
    observer.observe(column);
    return () => observer.disconnect();
  }, []);

  const onScroll = () => {
    const element = scroller.current;
    if (!element || !session) return;
    // Near the end follows again, unless the view is on its way up from there.
    const fromEnd = element.scrollHeight - element.scrollTop - element.clientHeight;
    const goingUp = element.scrollTop < lastScrollTop.current - 0.5;
    lastScrollTop.current = element.scrollTop;
    following.current = fromEnd < 1 || (fromEnd < FOLLOW_SLACK_PX && !goingUp);
    setShowJump(!following.current);
    if (following.current) setHasNew(false);
    anchor.current = findAnchor(element);
    if (element.scrollTop < OLDER_SLACK_PX && chat?.history.kind === "loaded" && chat.history.hasOlder) {
      void workbench.loadOlderHistory(session.sessionId);
    }
  };

  // Scrolling up leaves the end at once, before the first scroll event: a reply growing meanwhile
  // must not pull the view back down mid-fling.
  const leaveEnd = () => {
    if (!following.current) return;
    following.current = false;
    setShowJump(true);
  };
  const onWheel = (event: WheelEvent<HTMLDivElement>) => { if (event.deltaY < 0) leaveEnd(); };
  const touchY = useRef<number | null>(null);
  const onTouchStart = (event: TouchEvent<HTMLDivElement>) => { touchY.current = event.touches[0]?.clientY ?? null; };
  const onTouchMove = (event: TouchEvent<HTMLDivElement>) => {
    const y = event.touches[0]?.clientY;
    // A finger moving down the screen scrolls the transcript up.
    if (y !== undefined && touchY.current !== null && y > touchY.current + 2) leaveEnd();
    touchY.current = y ?? null;
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
    <section className="conversation" aria-label="Conversation" ref={section}>
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

      <div className="transcript" ref={scroller} onScroll={onScroll} onWheel={onWheel}
        onTouchStart={onTouchStart} onTouchMove={onTouchMove} data-testid="transcript">
        <div className="transcript-column">
          {history.kind === "loadingOlder" ? <p className="history-note">Loading earlier messages…</p> : null}
          {history.kind === "loaded" && history.hasOlder ? (
            <button className="history-note link" onClick={() => {
              if (!session) return;
              void workbench.loadOlderHistory(session.sessionId);
            }}>Load earlier messages</button>
          ) : null}
          {history.kind === "failed" ? (
            <p className="history-note warning">Could not read this chat: {history.message} <button className="link" onClick={() => session && void workbench.openChat(session.sessionId)}>Try again</button></p>
          ) : null}
          {history.kind === "loading" && empty ? <p className="history-note">Loading the chat…</p> : null}

          {empty && history.kind !== "loading" ? (
            <div className="empty-chat">
              <AxoMascot className="empty-chat-mascot" />
              <h2>What are we working on?</h2>
              <p>{session ? "Nothing here yet." : !host ? "Pair a Mac to start chatting." : host.status === "online" ? "Send a message to start a chat." : "Your Mac is offline."}</p>
            </div>
          ) : null}

          {shown.map(({ message, live, enter, reveal }) => (
            <MessageView key={message.key} message={message} working={Boolean(transcript?.working)} live={live} enter={enter} reveal={reveal} />
          ))}
          {session && chat?.pending.map(prompt => (
            <PendingView
              key={prompt.id}
              prompt={prompt}
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

      <footer className="layer-bar bottom conversation-footer" ref={footer}>
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
          wide={wide}
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
 * typed, Send. While listening the box becomes the listening bar. With a keyboard, Enter sends and
 * Shift-Enter starts a new line; on a touch screen Return starts a new line and Send sends.
 */
function Composer({ workbench, wide, voice, placeholder, canSend, onSend, onEscape }: {
  workbench: ChatWorkbench;
  /** Wide, the Mac is chosen inside the box; narrow, from a chip floating above it. */
  wide: boolean;
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
    if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing && !touchTyping()) {
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
      {!wide ? <HostPicker workbench={workbench} floating /> : null}
      {tooLong ? <p className="composer-note" role="status">Too long to send: {bytes.toLocaleString()} of {maxMessageBytes.toLocaleString()} bytes.</p> : null}
      {voice && listening ? <VoiceListeningBar voice={voice} canSend={canSend} /> : (
        <form className="composer" onSubmit={event => {
          event.preventDefault();
          if (ready) onSend();
        }}>
          {wide ? <HostPicker workbench={workbench} /> : null}
          <textarea
            ref={field}
            rows={1}
            value={draft}
            placeholder={placeholder}
            aria-label="Message"
            enterKeyHint={touchTyping() ? "enter" : "send"}
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

/**
 * Which Mac the chat is on. On a new chat it is the choice of where to start it: tap, pick a Mac,
 * send. On a chat already going it only says where it is.
 */
function HostPicker({ workbench, floating = false }: { workbench: ChatWorkbench; floating?: boolean }) {
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  const host = workbench.openHost;
  const choosing = workbench.selection?.kind === "new" && workbench.hosts.length > 1;
  useEffect(() => {
    if (!open) return;
    const close = (event: PointerEvent) => { if (!root.current?.contains(event.target as Node)) setOpen(false); };
    const escape = (event: globalThis.KeyboardEvent) => { if (event.key === "Escape") setOpen(false); };
    window.addEventListener("pointerdown", close);
    window.addEventListener("keydown", escape);
    return () => { window.removeEventListener("pointerdown", close); window.removeEventListener("keydown", escape); };
  }, [open]);
  if (!host) return null;
  const face = (
    <>
      <Icon name="laptop" size={15} />
      <span className="host-picker-label">{host.label}</span>
      <span className={`mac-dot ${host.status}`} aria-hidden="true" />
    </>
  );
  return (
    <div className={floating ? "host-picker floating" : "host-picker"} ref={root}>
      {choosing ? (
        <button type="button" className="host-picker-button" aria-haspopup="menu" aria-expanded={open}
          aria-label={`Start on ${host.label}`} title="Choose the Mac to start this chat on" onClick={() => setOpen(!open)}>
          {face}<Icon name="arrowDown" size={11} />
        </button>
      ) : (
        <span className="host-picker-button static" title={`This chat is on ${host.label}`} aria-label={`On ${host.label}`}>{face}</span>
      )}
      {open ? (
        <div className="host-menu" role="menu" aria-label="Start on">
          {workbench.hosts.map(candidate => (
            <button key={candidate.hostId} type="button" role="menuitemradio" aria-checked={candidate.hostId === host.hostId}
              className="host-menu-item" disabled={candidate.status !== "online"}
              onClick={() => { workbench.chooseHost(candidate.hostId); setOpen(false); }}>
              <Icon name={candidate.hostId === host.hostId ? "check" : "laptop"} size={15} />
              <span className="host-picker-label">{candidate.label}</span>
              <small>{candidate.status === "online" ? "Online" : "Offline"}</small>
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}

type ShownMessage = { message: ChatMessage; live: boolean; enter: boolean; reveal: Reveal | null };

/**
 * What the transcript shows, in order: its recorded messages, then the reply being written.
 *
 * What the chat opened with, and older pages read in above, are history and just appear. So does a
 * batch caught up at once, as after a reconnect: it was written while nobody watched. What is
 * written while the chat is on screen is presented: a reply (and its thinking) seen live, or arriving
 * on its own, is let out a word at a time, from its first live words through its record, and
 * nothing after it shows until all of it is out; anything else rises in. The person's own messages
 * were on screen already, as pending.
 */
function useShownMessages(sessionId: string | null, transcript: ChatTranscript | null): ShownMessage[] {
  const state = useRef({ sessionId: null as string | null, known: new Set<string>(), entering: new Set<string>(), revealing: new Set<string>(), done: new Set<string>() }).current;
  const [, setRevealed] = useState(0);
  const onDone = useCallback((key: string) => {
    if (state.done.has(key)) return;
    state.done.add(key);
    setRevealed(count => count + 1);
  }, [state]);
  const reveals = useMemo(() => ({ final: { final: true, onDone }, writing: { final: false, onDone } }), [onDone]);

  const messages = transcript?.messages ?? [];
  const live = transcript?.live ?? [];
  const all = [...messages.map(message => ({ message, live: false })), ...live.map(message => ({ message, live: true }))];
  if (state.sessionId !== sessionId || (state.known.size === 0 && messages.length > 0)) {
    // A chat just opened, or its history just came in: what is recorded is history.
    state.sessionId = sessionId;
    state.known = new Set(messages.map(message => message.key));
    state.entering = new Set();
    state.revealing = new Set();
    state.done = new Set();
  }
  let lastKnown = -1;
  all.forEach(({ message }, index) => { if (state.known.has(message.key)) lastKnown = index; });
  const arrived = all.filter(({ message }, index) => !state.known.has(message.key) && index > lastKnown && message.role !== "user");
  // Pieces of one record (thinking, words, tool calls) share its id before the `#`.
  const caughtUp = new Set(arrived.filter(({ live: isLive }) => !isLive).map(({ message }) => message.id.split("#")[0])).size > 1;
  for (const { message } of all) state.known.add(message.key);
  for (const { message, live: isLive } of arrived) {
    const text = message.role === "assistant" || message.role === "thinking";
    if (text && (isLive || !caughtUp)) state.revealing.add(message.key);
    else if (!caughtUp) state.entering.add(message.key);
  }

  const shown: ShownMessage[] = [];
  for (const [index, { message, live: isLive }] of all.entries()) {
    const revealing = state.revealing.has(message.key);
    const final = !isLive || index < all.length - 1;
    shown.push({ message, live: isLive, enter: state.entering.has(message.key), reveal: revealing ? (final ? reveals.final : reveals.writing) : null });
    // What comes after a reply waits until all of it is out.
    if (revealing && !state.done.has(message.key)) break;
  }
  return shown;
}

/**
 * Scrolls only when the view is not there already. Setting the scroll position at all, even to
 * where it is, ends the momentum of a fling on macOS and iOS, so the view would stop dead.
 */
function setScrollTop(scroller: HTMLElement, top: number): void {
  const target = Math.max(0, Math.min(top, scroller.scrollHeight - scroller.clientHeight));
  if (Math.abs(scroller.scrollTop - target) >= 1) scroller.scrollTop = target;
}

function scrollToEnd(scroller: HTMLElement): void {
  setScrollTop(scroller, scroller.scrollHeight);
}

type ScrollAnchor = { element: Element; offset: number };

/** The first message still showing at the top of the transcript; notes come and go, so never one. */
function findAnchor(scroller: HTMLElement): ScrollAnchor | null {
  const top = scroller.getBoundingClientRect().top;
  const column = scroller.firstElementChild;
  if (!column) return null;
  for (const element of Array.from(column.children)) {
    if (element.classList.contains("history-note")) continue;
    const box = element.getBoundingClientRect();
    if (box.bottom > top) return { element, offset: box.top - top };
  }
  return null;
}

/** Scrolls so the anchor sits where it was, whatever went in or came out above it. */
function restoreAnchor(scroller: HTMLElement, anchor: ScrollAnchor | null): void {
  if (!anchor || !anchor.element.isConnected) return;
  const offset = anchor.element.getBoundingClientRect().top - scroller.getBoundingClientRect().top;
  setScrollTop(scroller, scroller.scrollTop + offset - anchor.offset);
}

/** Typing on a touch screen, where Return has to be how a new line goes in. */
const touchTyping = () => window.matchMedia("(pointer: coarse)").matches;
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
