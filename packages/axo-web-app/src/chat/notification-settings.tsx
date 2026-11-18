import { useEffect, useState } from "react";
import { Icon } from "./icons.tsx";

function permission(): NotificationPermission | "unavailable" {
  return typeof Notification === "undefined" ? "unavailable" : Notification.permission;
}

/** Permission belongs in Settings, never behind an actionable-request indicator. */
export function NotificationSettings() {
  const [state, setState] = useState(permission);
  useEffect(() => {
    const timer = setInterval(() => setState(permission()), 1_000);
    return () => clearInterval(timer);
  }, []);
  const enable = async () => {
    try { setState(await Notification.requestPermission()); }
    catch { setState(permission()); }
  };
  return <>
    <h3 className="sheet-section">Notifications</h3>
    <div className="grouped">
      <div className="grouped-row">
        <Icon name="bell" size={18} />
        <span className="grouped-label">Desktop notifications</span>
        {state === "default"
          ? <button className="pill-button" onClick={() => void enable()}>Enable desktop notifications</button>
          : <span>{state === "granted" ? "Enabled" : state === "denied" ? "Blocked" : "Unavailable"}</span>}
      </div>
    </div>
    <p className="sheet-note">{state === "denied"
      ? "Allow notifications in your browser’s site settings. Pending requests still appear in chats."
      : state === "granted"
        ? "Requests notify you on this browser. Change permission in your browser’s site settings."
        : state === "unavailable"
          ? "This browser does not support desktop notifications. Requests still appear in chats."
          : "Get notified when a Session needs your answer."}</p>
  </>;
}
