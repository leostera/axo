/** The few symbols the chat uses, drawn after their SF Symbols counterparts on the phone. */
export type IconName =
  | "menu" | "info" | "person" | "gear" | "compose" | "arrowUp" | "stop" | "laptop" | "copy" | "check"
  | "close" | "chevron" | "terminal" | "pencil" | "doc" | "search" | "wrench" | "warning" | "pair" | "arrowDown"
  | "clock" | "listIndent";

const paths: Record<IconName, string> = {
  menu: "M5 9h14M5 15h14",
  info: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Zm0-10v6m0-9.5v.5",
  person: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Zm0-8a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm-6 5.5c1.2-2 3.4-3 6-3s4.8 1 6 3",
  gear: "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm7.4-3c0-.5 0-1-.1-1.4l2-1.6-2-3.4-2.4 1a7.6 7.6 0 0 0-2.4-1.4L14 2.6h-4l-.5 2.6c-.9.3-1.7.8-2.4 1.4l-2.4-1-2 3.4 2 1.6a7.7 7.7 0 0 0 0 2.8l-2 1.6 2 3.4 2.4-1c.7.6 1.5 1.1 2.4 1.4l.5 2.6h4l.5-2.6c.9-.3 1.7-.8 2.4-1.4l2.4 1 2-3.4-2-1.6c.1-.4.1-.9.1-1.4Z",
  compose: "M11 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-5M18.5 2.5a2.1 2.1 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5Z",
  arrowUp: "M12 19V5m-6 6 6-6 6 6",
  arrowDown: "M12 5v14m6-6-6 6-6-6",
  stop: "M8 7h8a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1Z",
  laptop: "M5 6a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v9H5V6Zm-3 11h20l-1 2H3l-1-2Z",
  copy: "M9 9h10a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H9a1 1 0 0 1-1-1V10a1 1 0 0 1 1-1Zm-4 6H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1",
  check: "m5 12 5 5L20 7",
  close: "M6 6l12 12M18 6 6 18",
  chevron: "m7 9 5 5 5-5",
  terminal: "M4 4h16a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1Zm3 5 3 3-3 3m5 0h5",
  pencil: "M4 20h4L19 9l-4-4L4 16v4Zm9-13 4 4M13 20h7",
  doc: "M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8l-5-5Zm0 0v5h5M9 13h6m-6 4h6",
  search: "M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14Zm5-2 5 5",
  wrench: "M14.7 6.3a4 4 0 0 0 5 5l-9.4 9.4a2.1 2.1 0 0 1-3-3l9.4-9.4a4 4 0 0 0-2-2Zm0 0L18 3l3 3-3.3 3.3",
  warning: "M12 4 2.5 20h19L12 4Zm0 6v4m0 3v.5",
  pair: "M12 3v12m-4-4 4 4 4-4M4 15v4a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-4",
  clock: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Zm0-13v4.5l3 2",
  listIndent: "M4 6h16M9 12h11M9 18h11M4 11.5v1M4 17.5v1",
};

export function Icon({ name, size = 20 }: { name: IconName; size?: number }) {
  return (
    <svg className="icon" width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor"
      strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d={paths[name]} />
    </svg>
  );
}
