import { useEffect, useLayoutEffect, useRef, useState, type KeyboardEvent } from "react";
import { AxoMascot } from "../axo-mascot.tsx";
import { Icon } from "./icons.tsx";
import { MessageView, PendingView, QuestionCard } from "./message-views.tsx";
import { chatTitle, type ChatWorkbench, type Workspace } from "./workbench.ts";

/** How close to the bottom still counts as following the conversation. */
const FOLLOW_SLACK_PX = 80;
/** How close to the top starts reading the page before. */
const OLDER_SLACK_PX = 400;

/** The open chat, or a new one: the header, the transcript and the message box. */
export function Conversation({ workbench, wide, onShowChats, onToggleInfo }: {
  workbench: ChatWorkbench;
  wide: boolean;
  onShowChats: () => void;
  onToggleInfo: () => void;
}) {
  const host = workbench.openHost;
  const session = workbench.selectedSession;
  const selection = workbench.selection;
  const chat = session ? workbench.chat(session.sessionId) : null;
  const transcript = chat?.transcript ?? null;
  const workspaceName = selection?.kind === "new" && selection.workspaceId
    ? workbench.workspaces.find(workspace => workspace.workspaceId === selection.workspaceId)?.name
    : session?.workspaceName;
  const subtitle = [workspaceName, host?.label].filter(Boolean).join(" · ") || "No Mac";
  const online = host?.status === "online" && workbench.link === "connected";
  const [choices, setChoices] = useState<Workspace[] | null>(null);

  const scroller = useRef<HTMLDivElement>(null);
  const following = useRef(true);
  const [showJump, setShowJump] = useState(false);
  /** The height before an older page went in above, to keep the view still. */
  const heightBeforeOlder = useRef<number | null>(null);
  const messageCount = transcript?.messages.length ?? 0;
  const firstId = transcript?.messages[0]?.id;

  // A new chat on screen starts at its newest message.
  useEffect(() => {
    following.current = true;
    setShowJump(false);
    setChoices(null);
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
    else setShowJump(true);
  }, [workbench.version, firstId]);

  const onScroll = () => {
    const element = scroller.current;
    if (!element || !session) return;
    following.current = element.scrollHeight - element.scrollTop - element.clientHeight < FOLLOW_SLACK_PX;
    if (following.current) setShowJump(false);
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
    element.scrollTo({ top: element.scrollHeight, behavior: "smooth" });
  };

  const send = async () => {
    following.current = true;
    const outcome = await workbench.send();
    if (outcome.kind === "chooseWorkspace") setChoices(outcome.workspaces);
  };
  const sendIn = async (workspaceId: string) => {
    setChoices(null);
    following.current = true;
    await workbench.sendIn(workspaceId);
  };

  const history = chat?.history ?? { kind: "none" as const };
  const empty = !session || (messageCount === 0 && !transcript?.live.length && !chat?.pending.length);

  return (
    <section className="conversation" aria-label="Conversation">
      <header className="layer-bar top conversation-header">
        {wide ? <span className="circle-placeholder" /> : (
          <button className="circle-button" onClick={onShowChats} aria-label="Show chats"><Icon name="menu" /></button>
        )}
        <div className="conversation-title">
          <h1>{chatTitle(session)}</h1>
          <p>{subtitle}</p>
        </div>
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
              <h2>{session ? "Nothing said yet" : "What are we working on?"}</h2>
              <p>{session ? "Send a message to get going." : host ? "Send a message to start a chat." : "Pair a Mac to start chatting."}</p>
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
          {transcript?.working && !transcript.live.length && !transcript.question ? (
            <div className="working-dots" aria-label="Axo is working"><span /><span /><span /></div>
          ) : null}
          {session && transcript?.question ? (
            <QuestionCard
              question={transcript.question}
              canAnswer={online}
              onAnswer={answer => void workbench.answer(session.sessionId, answer)}
            />
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
          <button className="jump-button" onClick={jumpToEnd}><Icon name="arrowDown" size={16} /> Jump to new message</button>
        ) : null}
        {choices ? (
          <div className="workspace-choices" role="group" aria-label="Choose a workspace">
            <p>Start this chat in…</p>
            <div>
              {choices.map(workspace => (
                <button key={workspace.workspaceId} className="pill-button" onClick={() => void sendIn(workspace.workspaceId)}>{workspace.name}</button>
              ))}
              <button className="pill-button quiet" onClick={() => setChoices(null)}>Cancel</button>
            </div>
          </div>
        ) : null}
        <Composer
          workbench={workbench}
          placeholder={!host ? "Pair a Mac to chat" : host.status !== "online" ? `${host.label} is offline` : "Message Axo"}
          canSend={Boolean(host && host.status === "online")}
          working={Boolean(transcript?.working)}
          stopping={Boolean(chat?.stopping)}
          onSend={() => void send()}
          onStop={() => session && void workbench.stop(session.sessionId)}
        />
      </footer>
    </section>
  );
}

/** The message box: Enter sends, Shift-Enter starts a new line; while Axo works, it can stop. */
function Composer({ workbench, placeholder, canSend, working, stopping, onSend, onStop }: {
  workbench: ChatWorkbench;
  placeholder: string;
  canSend: boolean;
  working: boolean;
  stopping: boolean;
  onSend: () => void;
  onStop: () => void;
}) {
  const draft = workbench.draft();
  const field = useRef<HTMLTextAreaElement>(null);
  const hasDraft = draft.trim().length > 0;
  const showStop = working && !hasDraft;

  useLayoutEffect(() => {
    const element = field.current;
    if (!element) return;
    element.style.height = "auto";
    element.style.height = `${Math.min(element.scrollHeight, 220)}px`;
  }, [draft]);

  useEffect(() => {
    if (window.matchMedia("(pointer: fine)").matches) field.current?.focus();
  }, [workbench.selection]);

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
      event.preventDefault();
      if (canSend && hasDraft && !workbench.isSending) onSend();
    } else if (event.key === "Escape" && working) {
      event.preventDefault();
      onStop();
    }
  };

  return (
    <form className="composer" onSubmit={event => {
      event.preventDefault();
      if (showStop) onStop();
      else if (canSend && hasDraft) onSend();
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
      />
      {showStop ? (
        <button className="send-button stop" disabled={stopping || !canSend} aria-label={stopping ? "Stopping" : "Stop"}>
          <Icon name="stop" size={18} />
        </button>
      ) : (
        <button className={hasDraft && canSend ? "send-button ready" : "send-button"} disabled={!hasDraft || !canSend || workbench.isSending} aria-label="Send">
          <Icon name="arrowUp" size={20} />
        </button>
      )}
    </form>
  );
}
