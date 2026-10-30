import { useEffect, useRef } from "react";

/** A question that needs an answer before going on, as the phone's alerts ask it. */
export function Alert({ title, message, confirm, cancel, destructive = false, onConfirm, onCancel }: {
  title: string;
  message: string;
  confirm: string;
  cancel: string;
  destructive?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  const cancelButton = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    cancelButton.current?.focus();
    const onKeyDown = (event: KeyboardEvent) => {
      // An Escape already handled (the one that opened this alert) is not also a cancel.
      if (event.key === "Escape" && !event.defaultPrevented) {
        event.preventDefault();
        onCancel();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onCancel]);
  return (
    <div className="alert-backdrop" onClick={onCancel}>
      <section className="alert" role="alertdialog" aria-modal="true" aria-label={title} onClick={event => event.stopPropagation()}>
        <div className="alert-copy">
          <h2>{title}</h2>
          <p>{message}</p>
        </div>
        <div className="alert-buttons">
          <button ref={cancelButton} className="alert-cancel" onClick={onCancel}>{cancel}</button>
          <button className={destructive ? "alert-confirm destructive" : "alert-confirm"} onClick={onConfirm}>{confirm}</button>
        </div>
      </section>
    </div>
  );
}
