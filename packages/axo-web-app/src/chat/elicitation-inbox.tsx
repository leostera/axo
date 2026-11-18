import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { createPortal } from "react-dom";
import { Icon } from "./icons.tsx";
import { ElicitationCard } from "./message-views.tsx";
import { chatTitle, type ChatWorkbench } from "./workbench.ts";
import { ElicitationNotifications } from "./elicitation-notifications.ts";

function permission(): NotificationPermission | "unavailable" {
  return typeof Notification === "undefined" ? "unavailable" : Notification.permission;
}

/** A person-wide inbox, independent of navigation, conversation subscriptions and scrollback. */
export function ElicitationInbox({ workbench }: { workbench: ChatWorkbench }) {
  useSyncExternalStore(workbench.subscribe, workbench.getVersion);
  const [now, setNow] = useState(Date.now);
  const [open, setOpen] = useState(false);
  const [allowed, setAllowed] = useState(permission);
  const dialog = useRef<HTMLDialogElement>(null);
  const notifications = useMemo(() => new ElicitationNotifications(), [workbench]);
  const questions = workbench.questions().filter(question => question.elicitation.expiresAt > now)
    .sort((a, b) => a.elicitation.createdAt - b.elicitation.createdAt || a.elicitation.id.localeCompare(b.elicitation.id));
  useEffect(() => {
    const timer = setInterval(() => { setNow(Date.now()); setAllowed(permission()); }, 1_000);
    return () => clearInterval(timer);
  }, []);
  useEffect(() => () => notifications.dispose(), [notifications]);
  useEffect(() => {
    notifications.update(questions.map(question => question.elicitation), allowed === "granted", id => {
      const notification = new Notification("Axo needs your answer", {
        body: "A Session has a request waiting. Open Axo to review it.",
        tag: `axo.elicitation.${id}`,
      });
      notification.onclick = () => {
        if (!workbench.questions().some(question => question.elicitation.id === id && question.elicitation.expiresAt > Date.now())) return;
        window.focus(); setOpen(true);
      };
      return { close: () => { notification.onclick = null; notification.close(); } };
    });
  }, [questions.map(question => question.elicitation.id).join(), allowed, notifications]);
  useEffect(() => { if (questions.length === 0) setOpen(false); }, [questions.length]);
  useEffect(() => {
    if (open && questions.length > 0) dialog.current?.showModal();
    else dialog.current?.close();
  }, [open]);

  return <>
    <button className={`circle-button elicitation-bell${questions.length ? " has-requests" : ""}`}
      data-testid="elicitation-bell" aria-label={`Requests, ${questions.length} pending`}
      title={questions.length ? "Requests" : "No pending requests"} disabled={questions.length === 0}
      onClick={() => { if (questions.length) setOpen(true); }}>
      <Icon name="bell" size={19} />
      {questions.length ? <span className="elicitation-count" aria-live="polite">{questions.length}</span> : null}
    </button>
    {/* Keep notification-opened requests usable while the sidebar is hidden or inert. */}
    {createPortal(<dialog ref={dialog} className="elicitation-inbox" aria-label="Requests"
      onClose={() => setOpen(false)} onCancel={() => setOpen(false)} onKeyDown={event => event.stopPropagation()}
      onClick={event => { if (event.target === event.currentTarget) setOpen(false); }}>
      {open ? <section onClick={event => event.stopPropagation()}>
        <header className="sheet-header">
          <h2>Requests {questions.length ? `(${questions.length})` : ""}</h2>
          <button className="circle-button" aria-label="Close requests" onClick={() => setOpen(false)}><Icon name="close" /></button>
        </header>
        <div className="elicitation-inbox-list">
          {questions.map(question => {
            const host = workbench.hosts.find(host => host.hostId === question.hostId);
            const session = host?.sessions.find(session => session.sessionId === question.elicitation.sessionId);
            return <article key={question.elicitation.id}>
              <p className="elicitation-origin">{host?.label ?? "Mac"} · {chatTitle(session)}</p>
              <ElicitationCard question={question} canAnswer={host?.status === "online" && workbench.link === "connected"}
                onAnswer={(action, values) => void workbench.answerQuestion(question.elicitation.id, action, values)} />
            </article>;
          })}
        </div>
      </section> : null}
    </dialog>, document.body)}
  </>;
}
