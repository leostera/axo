/** The few symbols the chat uses, drawn after their SF Symbols counterparts on the phone. */
export type IconName =
  | "menu" | "info" | "person" | "gear" | "compose" | "arrowUp" | "laptop" | "copy" | "check"
  | "close" | "terminal" | "pencil" | "doc" | "search" | "wrench" | "warning" | "pair" | "arrowDown"
  | "micSlash" | "waveform" | "stopFill" | "sparkles" | "closeCircle" | "share" | "question" | "moon" | "signOut" | "plug" | "mail" | "chevronLeft" | "chevronRight" | "calendar" | "folder" | "table" | "contacts" | "presentation" | "checklist" | "video" | "cloud" | "paperclip"
  | "pin" | "pinFill" | "plus" | "mic" | "camera" | "photo" | "chevronDown" | "restart";

const paths: Record<IconName, string> = {
  menu: "M5 9h14M5 15h14",
  info: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Zm0-10v6m0-9.5v.5",
  person: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Zm0-8a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm-6 5.5c1.2-2 3.4-3 6-3s4.8 1 6 3",
  gear: "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm7.4-3c0-.5 0-1-.1-1.4l2-1.6-2-3.4-2.4 1a7.6 7.6 0 0 0-2.4-1.4L14 2.6h-4l-.5 2.6c-.9.3-1.7.8-2.4 1.4l-2.4-1-2 3.4 2 1.6a7.7 7.7 0 0 0 0 2.8l-2 1.6 2 3.4 2.4-1c.7.6 1.5 1.1 2.4 1.4l.5 2.6h4l.5-2.6c.9-.3 1.7-.8 2.4-1.4l2.4 1 2-3.4-2-1.6c.1-.4.1-.9.1-1.4Z",
  compose: "M11 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-5M18.5 2.5a2.1 2.1 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5Z",
  arrowUp: "M12 19V5m-6 6 6-6 6 6",
  arrowDown: "M12 5v14m6-6-6 6-6-6",
  laptop: "M5 6a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v9H5V6Zm-3 11h20l-1 2H3l-1-2Z",
  copy: "M9 9h10a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H9a1 1 0 0 1-1-1V10a1 1 0 0 1 1-1Zm-4 6H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1",
  check: "m5 12 5 5L20 7",
  close: "M6 6l12 12M18 6 6 18",
  terminal: "M4 4h16a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1Zm3 5 3 3-3 3m5 0h5",
  pencil: "M4 20h4L19 9l-4-4L4 16v4Zm9-13 4 4M13 20h7",
  doc: "M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8l-5-5Zm0 0v5h5M9 13h6m-6 4h6",
  search: "M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14Zm5-2 5 5",
  wrench: "M14.7 6.3a4 4 0 0 0 5 5l-9.4 9.4a2.1 2.1 0 0 1-3-3l9.4-9.4a4 4 0 0 0-2-2Zm0 0L18 3l3 3-3.3 3.3",
  warning: "M12 4 2.5 20h19L12 4Zm0 6v4m0 3v.5",
  pair: "M12 3v12m-4-4 4 4 4-4M4 15v4a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-4",
  micSlash: "M15 9.3V6a3 3 0 0 0-5.7-1.3M9 9v3a3 3 0 0 0 4.6 2.5M18 11a6 6 0 0 1-1 3.3M6 11a6 6 0 0 0 9.5 4.9M12 17v4m-3 0h6M4 4l16 16",
  waveform: "M4 10v4M8 7v10M12 4v16M16 7v10M20 10v4",
  stopFill: "M8 7h8a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1Z",
  sparkles: "M10 3.5 11.6 8 16 9.5 11.6 11 10 15.5 8.4 11 4 9.5 8.4 8 10 3.5ZM17.5 13l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8.8-2.2Z",
  closeCircle: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Zm-3-12 6 6m0-6-6 6",
  question: "M12 20c4.4 0 8-3.1 8-7s-3.6-7-8-7-8 3.1-8 7c0 1.6.6 3.1 1.6 4.3L5 21l3.7-1.6c1 .4 2.1.6 3.3.6Zm-2-9a2 2 0 1 1 2.8 1.8c-.5.3-.8.7-.8 1.2m0 2.2v.3",
  moon: "M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5Z",
  signOut: "M14 4H6a1 1 0 0 0-1 1v14a1 1 0 0 0 1 1h8M10 12h11m-3-3 3 3-3 3",
  share: "M12 3v12M8 7l4-4 4 4M6 11H5a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-8a1 1 0 0 0-1-1h-1",
  plug: "M9 3v5m6-5v5M7 8h10v3a5 5 0 0 1-10 0V8Zm5 8v5",
  calendar: "M5 5h14a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1Zm-1 5h16M8 3v4m8-4v4",
  folder: "M3 6a1 1 0 0 1 1-1h5l2 2h9a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V6Z",
  table: "M4 4h16a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1Zm-1 6h18M3 15h18M9 10v10",
  contacts: "M9 12a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm-5 7c.8-2.4 2.7-4 5-4s4.2 1.6 5 4M16 7h5m-5 4h5m-3 4h3",
  presentation: "M3 4h18M4 4v11a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1V4M12 16v4m-4 0h8M8 12l3-3 2 2 3-3",
  checklist: "M4 6l1.5 1.5L8 5m-4 7l1.5 1.5L8 11m-4 7l1.5 1.5L8 17M11 6h9m-9 6h9m-9 6h9",
  video: "M4 7a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7Zm12 3.5 4-2.5v8l-4-2.5",
  cloud: "M7 18a4 4 0 0 1-.6-7.96A6 6 0 0 1 18 9a4.5 4.5 0 0 1-.5 9H7Z",
  paperclip: "M20 11.5 12 19.5a4.6 4.6 0 0 1-6.5-6.5l8-8a3 3 0 0 1 4.3 4.3l-8 8a1.5 1.5 0 0 1-2.1-2.1l7.3-7.3",
  chevronLeft: "m15 5-7 7 7 7",
  chevronDown: "m5 9 7 7 7-7",
  restart: "M20 12a8 8 0 1 1-2.3-5.7M20 4v4.5h-4.5",
  pin: "M9 3h6l-1 6 3 3v2H7v-2l3-3-1-6Zm3 11v7",
  pinFill: "M9 3h6l-1 6 3 3v2H7v-2l3-3-1-6Zm3 11v7",
  plus: "M12 4v16M4 12h16",
  mic: "M12 14a3 3 0 0 0 3-3V6a3 3 0 0 0-6 0v5a3 3 0 0 0 3 3Zm-6-3a6 6 0 0 0 12 0m-6 6v4",
  camera: "M4 8a1 1 0 0 1 1-1h3l1.5-2h5L16 7h3a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V8Zm8 8a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7Z",
  photo: "M5 4h14a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1Zm-1 12 4.5-4.5 4 4 2.5-2.5L20 18M15.5 9.5a1 1 0 1 0 0-.01",
  chevronRight: "m9 5 7 7-7 7",
  mail: "M4 5h16a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1Zm0 1 8 7 8-7",
};

/** Drawn filled, as their ".fill" SF Symbols are. */
const filled: ReadonlySet<IconName> = new Set(["stopFill", "sparkles", "pinFill"]);

export function Icon({ name, size = 20 }: { name: IconName; size?: number }) {
  const solid = filled.has(name);
  return (
    <svg className="icon" width={size} height={size} viewBox="0 0 24 24" fill={solid ? "currentColor" : "none"} stroke="currentColor"
      strokeWidth={solid ? 1 : 1.8} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d={paths[name]} />
    </svg>
  );
}
