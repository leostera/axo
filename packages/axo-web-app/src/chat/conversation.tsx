import { memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore, type ClipboardEvent, type KeyboardEvent, type TouchEvent, type WheelEvent } from "react";
import { AxoMascot } from "../axo-mascot.tsx";
import { Icon } from "./icons.tsx";
import { ElicitationCard, MessageView, PendingView, QuestionCard } from "./message-views.tsx";
import { appendTranscript, BrowserDictation, VoicePrompt, waveformHeight } from "./voice.ts";
import { ConversationFeed, type FeedItem } from "./feed.ts";
import { HoldRow } from "./tool-views.tsx";
import { chatTitle, type ChatWorkbench, type DraftAttachment } from "./workbench.ts";
import { ModelPicker, SendButton, SlashMenu } from "./composer-controls.tsx";
import { matchingCommands, slashQuery, withCommand } from "./pi-controls.ts";
import type { Delivery } from "./transcript.ts";
import { noteRender } from "./render-count.ts";

/** How close to the bottom still counts as following the conversation. */
const FOLLOW_SLACK_PX = 80;
/** How close to the top starts reading the page before. */
const OLDER_SLACK_PX = 400;

/**
 * The open chat, or a new one, as on the phone: no title (its name only takes room; screen readers
 * still hear it), the menu button, the Mac's trouble when it has any, the transcript, what Axo is
 * doing with a way to stop it, and the message box.
 */
export function Conversation({ workbench, wide, onShowChats, onToggleInfo, onApps, voice: givenVoice }: {
  workbench: ChatWorkbench;
  wide: boolean;
  onShowChats: () => void;
  onToggleInfo: () => void;
  /** Settings › Apps: what the Session can use, from the box's + menu (Plugins). */
  onApps?: () => void;
  /** Tests give their own; otherwise the browser's speech recognition, where there is one. */
  voice?: VoicePrompt | null;
}) {
  noteRender("Conversation");
  const host = workbench.openHost;
  const session = workbench.selectedSession;
  const selection = workbench.selection;
  const chat = session ? workbench.chat(session.sessionId) : null;
  const transcript = chat?.transcript ?? null;
  const online = host?.status === "online" && workbench.link === "connected";
  const voice = useMemo(() => givenVoice !== undefined ? givenVoice : BrowserDictation.supported ? new VoicePrompt(new BrowserDictation()) : null, [givenVoice]);

  // The rows, kept by the feed as the transcript changes; the list renders only as one is added.
  const feed = session && chat ? chat.feed : noFeed;
  const feedRef = useRef(feed);
  feedRef.current = feed;
  const sessionRef = useRef(session?.sessionId ?? null);
  sessionRef.current = session?.sessionId ?? null;
  const dismiss = useCallback((id: string) => {
    if (sessionRef.current) workbench.dismissPending(sessionRef.current, id);
  }, [workbench]);
  const scroller = useRef<HTMLDivElement>(null);
  /** The row the reader just opened or folded, where it was: the next layout keeps it there. */
  const held = useRef<ScrollAnchor | null>(null);
  const holdRow = useCallback((row: Element) => {
    const element = scroller.current;
    if (!element) return;
    held.current = { element: row, offset: row.getBoundingClientRect().top - element.getBoundingClientRect().top };
  }, []);
  const following = useRef(true);
  const lastScrollTop = useRef(0);
  const [showJump, setShowJump] = useState(false);
  const [hasNew, setHasNew] = useState(false);
  /**
   * The message at the top of the view and how far down the view it sat. Whatever goes in above it
   * (an older page, a loading note) moves the scroll by as much, so what is read stays put.
   */
  const anchor = useRef<ScrollAnchor | null>(null);
  const messageCount = transcript?.messages.length ?? 0;
  /** The newest row as of the last layout: a different one is something new below. */
  const seenLastRow = useRef<string | undefined>(undefined);

  // A new chat on screen starts at its newest message; before it is drawn, so it never shows
  // anywhere else first.
  useLayoutEffect(() => {
    following.current = true;
    anchor.current = null;
    seenLastRow.current = feed.items.at(-1)?.id;
    setShowJump(false);
    setHasNew(false);
    if (scroller.current) scrollToEnd(scroller.current);
  }, [session?.sessionId, selection?.kind]);

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

  // Where the transcript is scrolled to is decided here alone (RFD0040): whatever changes it (a row
  // added, a reply growing as its words come out, an older page on top) changes the column's size,
  // and this runs after layout and before paint. Following, the end; otherwise what is read stays
  // where it is, and a row added below says something is new.
  useLayoutEffect(() => {
    const element = scroller.current;
    const column = element?.firstElementChild;
    if (!element || !column) return;
    const observer = new ResizeObserver(() => {
      const last = feedRef.current.items.at(-1)?.id;
      const added = last !== seenLastRow.current;
      seenLastRow.current = last;
      const opened = held.current;
      held.current = null;
      if (opened) {
        // A row the reader opened or folded stays where it is; the end is followed again only if
        // it is still in view.
        restoreAnchor(element, opened);
        following.current = element.scrollHeight - element.scrollTop - element.clientHeight < 1;
        setShowJump(!following.current);
      } else if (following.current) scrollToEnd(element);
      else {
        restoreAnchor(element, anchor.current);
        if (added) setHasNew(true);
      }
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

  const send = async (delivery: Delivery = "interrupt") => {
    following.current = true;
    await workbench.send(delivery);
  };

  const working = Boolean(transcript?.working);
  const canStop = online && working && !chat?.stopping;
  // A stop goes at once, without asking: interrupting has to be quick, and a reply stopped by
  // mistake costs only sending the message again.
  const stopReply = () => {
    if (canStop && session) void workbench.stop(session.sessionId);
  };
  const history = chat?.history ?? { kind: "none" as const };
  const empty = !session || (messageCount === 0 && !transcript?.live.length && !chat?.waiting.length);
  const trouble = !host ? null
    : host.status !== "online" ? `${host.label} is offline`
      : chat?.restarting ? "Restarting Pi…"
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

          <HoldRow.Provider value={holdRow}><ConversationRows feed={feed} dismiss={dismiss} /></HoldRow.Provider>
          {session && workbench.questions(session.sessionId).map(question => (
            <ElicitationCard
              key={question.elicitation.id}
              question={question}
              canAnswer={online}
              onAnswer={(action, values) => void workbench.answerQuestion(question.elicitation.id, action, values)}
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
              <button className="plain-icon-button agent-activity-stop" onClick={() => stopReply()}
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
          onSend={delivery => void send(delivery)}
          onEscape={stopReply}
          onApps={onApps}
        />
      </footer>
    </section>
  );
}

/** The most a message can be: the Mac takes up to 16,000 bytes of text. */
export const maxMessageBytes = 16_000;
const encoder = new TextEncoder();

/**
 * The message box, as on the phone: one card, the words on top and a bar under them with + (photos,
 * files, the camera, plugins) on the left and the Mac, voice and Send on the right. It grows with
 * the words. While listening the box becomes the listening bar. With a keyboard, Enter sends and
 * Shift-Enter starts a new line; on a touch screen Return starts a new line and Send sends.
 */
function Composer({ workbench, wide, voice, placeholder, canSend, onSend, onEscape, onApps }: {
  workbench: ChatWorkbench;
  /** Wide, the Mac is chosen inside the box; narrow, from a chip floating above it. */
  wide: boolean;
  voice: VoicePrompt | null;
  placeholder: string;
  canSend: boolean;
  onSend: (delivery: Delivery) => void;
  /** Escape with nothing to cancel: stops the reply. */
  onEscape: () => void;
  onApps?: () => void;
}) {
  const draft = workbench.draft();
  const files = workbench.attachments();
  const field = useRef<HTMLTextAreaElement>(null);
  const picker = useRef<HTMLInputElement>(null);
  const photoPicker = useRef<HTMLInputElement>(null);
  const cameraPicker = useRef<HTMLInputElement>(null);
  const [dragging, setDragging] = useState(false);
  const hasDraft = draft.trim().length > 0 || files.length > 0;
  const bytes = encoder.encode(draft).length;
  const tooLong = bytes > maxMessageBytes;
  const ready = canSend && workbench.canSendDraft && !tooLong && !workbench.isSending;
  const attach = (list: FileList | null) => {
    if (!list?.length) return;
    workbench.attach([...list].map(file => ({ file, name: file.name || "pasted image" })));
  };
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
    if (transcript.delivery === "send" && canSend && !workbench.isSending) onSend("interrupt");
    else if (window.matchMedia("(pointer: fine)").matches) field.current?.focus();
  }, [voice?.version]);

  // The `/` list, for a chat whose Pi can be asked what it runs.
  const session = workbench.selectedSession;
  const query = session ? slashQuery(draft) : null;
  const [dismissedSlash, setDismissedSlash] = useState<string | null>(null);
  const [highlighted, setHighlighted] = useState(0);
  const slashOpen = query !== null && dismissedSlash !== draft;
  const commands = session ? workbench.chat(session.sessionId).commands : null;
  const matches = slashOpen && commands?.kind === "loaded" ? matchingCommands(commands.items, query) : [];
  useEffect(() => {
    if (slashOpen && session) void workbench.loadCommands(session.sessionId);
  }, [slashOpen, session?.sessionId]);
  useEffect(() => setHighlighted(0), [query]);
  const pickCommand = (command: (typeof matches)[number]) => {
    workbench.setDraft(withCommand(command));
    field.current?.focus();
  };

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (slashOpen && matches.length && !event.nativeEvent.isComposing) {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        setHighlighted((highlighted + (event.key === "ArrowDown" ? 1 : -1) + matches.length) % matches.length);
        return;
      }
      if ((event.key === "Enter" && !event.shiftKey && !touchTyping()) || event.key === "Tab") {
        event.preventDefault();
        pickCommand(matches[Math.min(highlighted, matches.length - 1)]!);
        return;
      }
    }
    if (slashOpen && event.key === "Escape") {
      event.preventDefault();
      setDismissedSlash(draft);
      return;
    }
    if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing && !touchTyping()) {
      event.preventDefault();
      // ↵ interrupts a working agent; ⌘↵ steers it, ⌥↵ waits for its reply.
      if (ready) onSend(event.metaKey || event.ctrlKey ? "steer" : event.altKey ? "followUp" : "interrupt");
    } else if (event.key === "Escape" && !hasDraft) {
      event.preventDefault();
      onEscape();
    }
  };

  // Pasted files are attached; pasted words go in as plain text where the caret is.
  const onPaste = (event: ClipboardEvent<HTMLTextAreaElement>) => {
    if (event.clipboardData.files.length) {
      event.preventDefault();
      attach(event.clipboardData.files);
      return;
    }
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
      {files.length ? (
        <ul className="composer-files" aria-label="Attached files">
          {files.map(file => <AttachmentChip key={file.id} file={file} onRemove={() => workbench.detach(file.id)} />)}
        </ul>
      ) : null}
      {slashOpen && !(voice && listening) ? (
        <SlashMenu state={commands} matches={matches} highlighted={highlighted} onHighlight={setHighlighted} onPick={pickCommand} />
      ) : null}
      {voice && listening ? <VoiceListeningBar voice={voice} canSend={canSend} /> : (
        <form className={dragging ? "composer dragging" : "composer"} onSubmit={event => {
          event.preventDefault();
          if (ready) onSend("interrupt");
        }}
        onDragOver={event => {
          if (!canSend || !event.dataTransfer.types.includes("Files")) return;
          event.preventDefault();
          setDragging(true);
        }}
        onDragLeave={() => setDragging(false)}
        onDrop={event => {
          if (!canSend) return;
          event.preventDefault();
          setDragging(false);
          attach(event.dataTransfer.files);
        }}>
          <textarea
            ref={field}
            rows={1}
            value={draft}
            placeholder={placeholder}
            aria-label="Message"
            aria-controls={slashOpen ? "slash-menu" : undefined}
            aria-activedescendant={slashOpen && matches.length ? `slash-${highlighted}` : undefined}
            enterKeyHint={touchTyping() ? "enter" : "send"}
            disabled={!canSend}
            onChange={event => workbench.setDraft(event.target.value)}
            onKeyDown={onKeyDown}
            onPaste={onPaste}
          />
          <input ref={picker} type="file" multiple hidden onChange={event => {
            attach(event.target.files);
            event.target.value = "";
          }} />
          <input ref={photoPicker} type="file" accept="image/*,video/*" multiple hidden onChange={event => {
            attach(event.target.files);
            event.target.value = "";
          }} />
          <input ref={cameraPicker} type="file" accept="image/*" capture="environment" hidden onChange={event => {
            attach(event.target.files);
            event.target.value = "";
          }} />
          <div className="composer-toolbar">
            <AddMenu disabled={!canSend} onPick={choice => {
              if (choice === "camera") cameraPicker.current?.click();
              else if (choice === "photos") photoPicker.current?.click();
              else if (choice === "files") picker.current?.click();
              else onApps?.();
            }} plugins={Boolean(onApps)} />
            {wide ? <HostPicker workbench={workbench} /> : null}
            <span className="spacer" />
            {session ? <ModelPicker workbench={workbench} session={session} disabled={!canSend} /> : null}
            {voice ? (
              <button type="button" className="round-button composer-mic"
                disabled={!canSend || voice.isBusy} onClick={() => void voice.start()}
                aria-label="Talk" title="Say your message; stop to read it first, or send it straight away">
                {voiceState === "requestingPermission" ? <span className="spinner" aria-hidden="true" /> : <Icon name="mic" size={20} />}
              </button>
            ) : null}
            <SendButton ready={ready} onSend={onSend} />
          </div>
        </form>
      )}
    </div>
  );
}

const noSubscribe = () => () => {};

type AddChoice = "camera" | "photos" | "files" | "plugins";

/**
 * The box's +: a menu above it of what can go with a message. The camera only where there is one
 * to point (a touch screen); plugins open Settings › Apps. Arrow keys move, Enter picks, Escape
 * closes.
 */
function AddMenu({ disabled, plugins, onPick }: { disabled: boolean; plugins: boolean; onPick: (choice: AddChoice) => void }) {
  const [open, setOpen] = useState(false);
  const menu = useRef<HTMLDivElement>(null);
  const button = useRef<HTMLButtonElement>(null);
  const choices: { id: AddChoice; label: string; icon: Parameters<typeof Icon>[0]["name"] }[] = [
    ...(touchTyping() ? [{ id: "camera" as const, label: "Camera", icon: "camera" as const }] : []),
    { id: "photos", label: "Photos", icon: "photo" },
    { id: "files", label: "Files", icon: "folder" },
    ...(plugins ? [{ id: "plugins" as const, label: "Plugins", icon: "plug" as const }] : []),
  ];
  useEffect(() => {
    if (!open) return;
    menu.current?.querySelector<HTMLButtonElement>("button")?.focus();
    const close = (event: PointerEvent) => {
      if (!menu.current?.contains(event.target as Node) && !button.current?.contains(event.target as Node)) setOpen(false);
    };
    window.addEventListener("pointerdown", close);
    return () => window.removeEventListener("pointerdown", close);
  }, [open]);
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    const items = [...(menu.current?.querySelectorAll<HTMLButtonElement>("button") ?? [])];
    const index = items.indexOf(document.activeElement as HTMLButtonElement);
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const next = (index + (event.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
      items[next]?.focus();
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      setOpen(false);
      button.current?.focus();
    }
  };
  return (
    <div className="add-menu-anchor">
      <button ref={button} type="button" className="round-button add-button" disabled={disabled}
        aria-label="Add photos, files and more" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(!open)}>
        <Icon name="plus" size={20} />
      </button>
      {open ? (
        <div ref={menu} className="add-menu" role="menu" aria-label="Add" onKeyDown={onKeyDown}>
          {choices.map(choice => (
            <button key={choice.id} type="button" role="menuitem" className="add-menu-item" onClick={() => {
              setOpen(false);
              onPick(choice.id);
            }}>
              <span className="add-menu-well"><Icon name={choice.icon} size={20} /></span>
              {choice.label}
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}

/** A file in the message box: a thumbnail for an image, its name otherwise, and how it is going. */
function AttachmentChip({ file, onRemove }: { file: DraftAttachment; onRemove: () => void }) {
  const preview = useObjectUrl(file.mimeType.startsWith("image/") && file.mimeType !== "image/heic" ? file.file : null);
  const status = file.state === "uploading" ? "Uploading…" : file.state === "failed" ? file.error ?? "Upload failed" : formatBytes(file.size);
  return (
    <li className={`composer-file ${file.state}`} title={`${file.name} · ${status}`}>
      {preview ? <img src={preview} alt="" /> : <span className="composer-file-icon"><Icon name="doc" size={18} /></span>}
      <span className="composer-file-text">
        <span className="composer-file-name">{file.name}</span>
        <small>{file.state === "uploading" ? <span className="spinner" aria-hidden="true" /> : null}{status}</small>
      </span>
      <button type="button" className="plain-icon-button" onClick={onRemove} aria-label={`Remove ${file.name}`}><Icon name="close" size={13} /></button>
    </li>
  );
}

/** An object URL for `blob` while the component shows it. */
function useObjectUrl(blob: Blob | null): string | null {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => {
    if (!blob) return;
    const created = URL.createObjectURL(blob);
    setUrl(created);
    return () => URL.revokeObjectURL(created);
  }, [blob]);
  return blob ? url : null;
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

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

/** The rows of a chat that does not exist yet: none. */
const noFeed = new ConversationFeed(false);

/**
 * The conversation's rows, as the feed keeps them: rendered when a row is added or removed, and
 * not when the conversation around them renders, nor when one of them changes.
 */
const ConversationRows = memo(function ConversationRows({ feed, dismiss }: { feed: ConversationFeed; dismiss: (id: string) => void }) {
  useSyncExternalStore(feed.subscribe, feed.getVersion);
  return <>{feed.items.map(item => <RowView key={item.id} item={item} dismiss={dismiss} />)}</>;
});

/** One row: rendered when its own row changes (a reply's words coming out), and only then. */
const RowView = memo(function RowView({ item, dismiss }: { item: FeedItem; dismiss: (id: string) => void }) {
  useSyncExternalStore(item.subscribe, item.getVersion);
  const row = item.row;
  if (row.kind === "waiting") return <PendingView prompt={row.prompt} onDismiss={() => dismiss(row.prompt.id)} />;
  return <MessageView message={row.message} working={row.working} live={row.live} enter={row.enter}
    revealed={row.reveal ? item.revealed ?? 0 : null} group={row.group} />;
});

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
