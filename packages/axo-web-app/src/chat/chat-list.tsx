import { useEffect, useMemo, useRef, useState, useSyncExternalStore, type PointerEvent as ReactPointerEvent } from "react";
import { Icon } from "./icons.tsx";
import {
  activeWindowChoices, chatSections, earlierLimitChoices, groupOrders, groupTitles, holdingSections, pinnedOrders,
  regroupIntervalChoices, rowOrderTitles, saveGrouping, savePins, saveSeen, storedGrouping, storedPins, storedSeen, unseenMarkerTitles,
  type ChatSection, type GroupingSettings, type RowOrder, type SessionPins, type SessionSeen,
} from "./sidebar.ts";
import { chatKey, chatTitle, lastActivity, shortAge, type ChatMenuEntry, type Host } from "./workbench.ts";

// MARK: - Store

/**
 * This browser's pins, seen marks and grouping settings, shared by the chat list and Settings, and
 * saved as they change. Read once, when first used, so a page without the list never touches storage.
 */
class ChatListStore {
  private state: { pins: SessionPins; seen: SessionSeen; settings: GroupingSettings } | null = null;
  private readonly listeners = new Set<() => void>();
  private version = 0;

  private get current() {
    return this.state ??= { pins: storedPins(), seen: storedSeen(Date.now()), settings: storedGrouping() };
  }
  get pins(): SessionPins { return this.current.pins; }
  get seen(): SessionSeen { return this.current.seen; }
  get settings(): GroupingSettings { return this.current.settings; }

  readonly subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  };
  readonly getVersion = () => this.version;

  togglePin(sessionId: string): void {
    this.current.pins = this.pins.toggled(sessionId);
    savePins(this.pins);
    this.changed();
  }

  markSeen(entry: ChatMenuEntry, now: number): void {
    const seen = this.seen.marked(entry, now);
    if (seen === this.seen) return;
    this.current.seen = seen;
    saveSeen(seen);
    this.changed();
  }

  /** "Mark all read": every chat seen, those listed and those on Macs not listed now. */
  markAllSeen(entries: readonly ChatMenuEntry[], now: number): void {
    const seen = this.seen.allMarked(entries, now);
    if (seen === this.seen) return;
    this.current.seen = seen;
    saveSeen(seen);
    this.changed();
  }

  setSettings(settings: GroupingSettings): void {
    this.current.settings = settings;
    saveGrouping(settings);
    this.changed();
  }

  private changed(): void {
    this.version += 1;
    for (const listener of this.listeners) listener();
  }
}

export const chatList = new ChatListStore();

export function useChatListStore(): ChatListStore {
  useSyncExternalStore(chatList.subscribe, chatList.getVersion);
  return chatList;
}

// MARK: - The list

/**
 * Every chat in its group, as the Mac's sidebar lists them: Pinned, then Active (working, asking,
 * just active, or not yet seen), then Earlier. Groups are worked out on a slow tick, so chats leave
 * Active a few at a time rather than one by one; rows hold still while the pointer is over the list.
 */
export function ChatList({ entries, showHost, asking, openChat, pageVisible, isSelected, onSelect }: {
  entries: ChatMenuEntry[];
  /** The chats whose agent waits for the person's answer (RFD0029). */
  asking: ReadonlySet<string>;
  showHost: boolean;
  /** The chat on screen, marked seen while the page shows it. */
  openChat: ChatMenuEntry | null;
  pageVisible: boolean;
  isSelected: (hostId: string, sessionId: string) => boolean;
  onSelect: (hostId: string, sessionId: string) => void;
}) {
  const store = useChatListStore();
  const { pins, seen, settings } = store;
  const clock = useClock(settings.regroupIntervalSeconds * 1000);
  const [menu, setMenu] = useState<{ entry: ChatMenuEntry; x: number; y: number } | null>(null);
  const [showAllEarlier, setShowAllEarlier] = useState(false);
  const [earlierFolded, setEarlierFolded] = useState(settings.earlierCollapsed);
  useEffect(() => setEarlierFolded(settings.earlierCollapsed), [settings.earlierCollapsed]);

  // The chat on screen is seen, and so is what lands in it while it shows.
  const openActivity = openChat ? lastActivity(openChat.session) : 0;
  useEffect(() => {
    if (openChat && pageVisible) store.markSeen(openChat, Date.now());
  }, [openChat?.session.sessionId, openActivity, pageVisible]);

  const live = useMemo(() => chatSections(entries, { pins, seen, now: clock, settings, asking }), [entries, pins, seen, clock, settings, asking]);
  const [held, setHeld] = useState<ChatSection[] | null>(null);
  const sections = holdingSections(held, live);

  return (
    <div className="chat-list" onPointerEnter={event => { if (event.pointerType === "mouse") setHeld(live); }} onPointerLeave={() => setHeld(null)}>
      {sections.map((section, index) => {
        const earlier = section.group === "earlier";
        const folded = earlier && earlierFolded;
        const limit = earlier && !showAllEarlier ? settings.earlierLimit : null;
        const shown = folded ? [] : limit === null ? section.entries : section.entries.slice(0, limit);
        const hidden = section.entries.length - shown.length;
        return (
          <section key={section.group} className={index === 0 ? "chat-section first" : "chat-section"} aria-label={groupTitles[section.group]}>
            {settings.showsGroupTitles ? (
              earlier ? (
                <button className="chat-group-title foldable" aria-expanded={!folded} onClick={() => setEarlierFolded(!folded)}>
                  {groupTitles.earlier}
                  <span className={folded ? "chat-group-chevron folded" : "chat-group-chevron"}><Icon name="chevronDown" size={11} /></span>
                  {folded ? <span className="chat-group-count">{section.entries.length}</span> : null}
                </button>
              ) : <h2 className="chat-group-title">{groupTitles[section.group]}</h2>
            ) : index > 0 ? <hr className="chat-group-rule" /> : null}
            {shown.map(entry => (
              <ChatRow key={chatKey(entry)} entry={entry} showHost={showHost}
                pinned={pins.has(entry.session.sessionId)}
                unseen={seen.isUnseen(entry) ? settings.unseenMarker : null}
                status={asking.has(entry.session.sessionId) ? "needsAttention" : entry.session.status}
                selected={isSelected(entry.host.hostId, entry.session.sessionId)}
                onSelect={() => onSelect(entry.host.hostId, entry.session.sessionId)}
                onTogglePin={() => store.togglePin(entry.session.sessionId)}
                onMenu={(x, y) => setMenu({ entry, x, y })} />
            ))}
            {hidden > 0 && !folded ? (
              <button className="chat-show-more" onClick={() => setShowAllEarlier(true)}>Show {hidden} more</button>
            ) : null}
            {earlier && showAllEarlier && settings.earlierLimit !== null && section.entries.length > settings.earlierLimit && !folded ? (
              <button className="chat-show-more" onClick={() => setShowAllEarlier(false)}>Show fewer</button>
            ) : null}
          </section>
        );
      })}
      {menu ? (
        <ChatRowMenu x={menu.x} y={menu.y} pinned={pins.has(menu.entry.session.sessionId)}
          onTogglePin={() => { store.togglePin(menu.entry.session.sessionId); setMenu(null); }}
          onClose={() => setMenu(null)} />
      ) : null}
    </div>
  );
}

/**
 * "Mark all read": every chat seen, on this browser, at once. Shown only while one has activity
 * nobody here looked at.
 */
export function MarkAllRead({ entries }: { entries: readonly ChatMenuEntry[] }) {
  const store = useChatListStore();
  const unseen = entries.filter(entry => store.seen.isUnseen(entry)).length;
  if (unseen === 0) return null;
  const label = `Mark all read (${unseen} ${unseen === 1 ? "chat" : "chats"})`;
  return (
    <button className="circle-button" onClick={() => store.markAllSeen(entries, Date.now())} aria-label="Mark all read" title={label}>
      <Icon name="check" />
    </button>
  );
}

/** The time groups are worked out at, moved every `interval` milliseconds. */
function useClock(interval: number): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), interval);
    return () => clearInterval(timer);
  }, [interval]);
  return now;
}

function StatusDot({ status }: { status: Host["sessions"][number]["status"] }) {
  switch (status) {
    case "working": return <span className="status-dot working" aria-label="Working" />;
    case "needsAttention": return <span className="status-dot attention" aria-label="Needs your attention" />;
    case "unavailable": return <span className="status-unavailable" aria-label="Stopped"><Icon name="warning" size={13} /></span>;
    default: return null;
  }
}

/**
 * A chat in the list, which opens it. A pinned chat keeps its pin; any other shows one under the
 * pointer. Right-click (or a long press on a touch screen) opens its menu.
 */
function ChatRow({ entry, showHost, pinned, unseen, status, selected, onSelect, onTogglePin, onMenu }: {
  entry: ChatMenuEntry;
  showHost: boolean;
  pinned: boolean;
  unseen: GroupingSettings["unseenMarker"] | null;
  status: Host["sessions"][number]["status"];
  selected: boolean;
  onSelect: () => void;
  onTogglePin: () => void;
  onMenu: (x: number, y: number) => void;
}) {
  const { host, session } = entry;
  // A long press opens the menu on a touch screen, where there is no right-click; the tap that
  // ends it does not also open the chat.
  const press = useRef<{ timer: ReturnType<typeof setTimeout>; fired: boolean } | null>(null);
  const endPress = () => { if (press.current) clearTimeout(press.current.timer); };
  const onPointerDown = (event: ReactPointerEvent) => {
    if (event.pointerType !== "touch") return;
    const { clientX, clientY } = event;
    const current = { fired: false, timer: setTimeout(() => { current.fired = true; onMenu(clientX, clientY); }, 500) };
    press.current = current;
  };
  const active = lastActivity(session);
  const now = useMinute();
  const bold = unseen === "dotAndBold" || unseen === "bold";
  const dot = unseen === "dotAndBold" || unseen === "dot";
  return (
    <div className={["chat-row-wrap", selected ? "selected" : "", pinned ? "pinned" : ""].join(" ").trim()}
      onContextMenu={event => { event.preventDefault(); endPress(); if (!press.current?.fired) onMenu(event.clientX, event.clientY); }}
      onPointerDown={onPointerDown} onPointerUp={endPress} onPointerCancel={endPress} onPointerMove={event => { if (event.pointerType === "touch" && (Math.abs(event.movementX) > 4 || Math.abs(event.movementY) > 4)) endPress(); }}>
      <button className={selected ? "chat-row selected" : "chat-row"} aria-current={selected ? "page" : undefined}
        onClick={() => { if (press.current?.fired) { press.current = null; return; } onSelect(); }}>
        {dot ? <span className="unseen-dot" aria-label="New activity" /> : null}
        <span className={bold ? "chat-row-name unseen" : "chat-row-name"}>{chatTitle(session)}</span>
        {showHost ? <span className="chat-row-host" title={`On ${host.label}`}>{host.label}</span> : null}
        <StatusDot status={status} />
        <span className="chat-row-age">{active > 0 ? shortAge(active, now) : ""}</span>
      </button>
      <button className="chat-row-pin plain-icon-button" onClick={onTogglePin}
        aria-label={pinned ? `Unpin ${chatTitle(session)}` : `Pin ${chatTitle(session)}`} aria-pressed={pinned}
        title={pinned ? "Unpin" : "Pin to the top"}>
        <Icon name={pinned ? "pinFill" : "pin"} size={13} />
      </button>
    </div>
  );
}

/** Ages only need to move once a minute. */
function useMinute(): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 60_000);
    return () => clearInterval(timer);
  }, []);
  return now;
}

/** A chat's menu, where the pointer was; Escape or a click elsewhere closes it. */
function ChatRowMenu({ x, y, pinned, onTogglePin, onClose }: { x: number; y: number; pinned: boolean; onTogglePin: () => void; onClose: () => void }) {
  const menu = useRef<HTMLDivElement>(null);
  useEffect(() => {
    menu.current?.querySelector("button")?.focus();
    const onKey = (event: KeyboardEvent) => { if (event.key === "Escape") onClose(); };
    const onDown = (event: PointerEvent) => { if (!menu.current?.contains(event.target as Node)) onClose(); };
    window.addEventListener("keydown", onKey);
    window.addEventListener("pointerdown", onDown);
    return () => { window.removeEventListener("keydown", onKey); window.removeEventListener("pointerdown", onDown); };
  }, [onClose]);
  const left = Math.min(x, window.innerWidth - 180);
  const top = Math.min(y, window.innerHeight - 60);
  return (
    <div ref={menu} className="context-menu" role="menu" style={{ left, top }}>
      <button role="menuitem" onClick={onTogglePin}><Icon name={pinned ? "pinFill" : "pin"} size={15} />{pinned ? "Unpin" : "Pin to the top"}</button>
    </div>
  );
}

// MARK: - Settings

/**
 * Settings › Chats: how the list groups chats, as the Mac's Settings › Sessions has it, saved in
 * this browser.
 */
export function ChatListSettings() {
  const store = useChatListStore();
  const settings = store.settings;
  const set = <K extends keyof GroupingSettings>(key: K, value: GroupingSettings[K]) => store.setSettings({ ...settings, [key]: value });
  const minutes = (value: number) => value < 60 ? `${value} ${value === 1 ? "minute" : "minutes"}` : "1 hour";
  const seconds = (value: number) => value < 60 ? `${value} seconds` : value === 60 ? "1 minute" : `${value / 60} minutes`;
  return (
    <>
      <h3 className="sheet-section">Chats</h3>
      <div className="grouped">
        <label className="grouped-row">
          <span className="grouped-label">Active for</span>
          <select aria-label="Active for" value={settings.activeWindowMinutes} onChange={event => set("activeWindowMinutes", Number(event.target.value))}>
            {activeWindowChoices.map(value => <option key={value} value={value}>{minutes(value)}</option>)}
          </select>
        </label>
        <label className="grouped-row">
          <span className="grouped-label">Keep unseen chats in Active until seen</span>
          <input type="checkbox" checked={settings.unseenStayActive} onChange={event => set("unseenStayActive", event.target.checked)} />
        </label>
        <label className="grouped-row">
          <span className="grouped-label">Move chats between groups every</span>
          <select aria-label="Move chats between groups every" value={settings.regroupIntervalSeconds} onChange={event => set("regroupIntervalSeconds", Number(event.target.value))}>
            {regroupIntervalChoices.map(value => <option key={value} value={value}>{seconds(value)}</option>)}
          </select>
        </label>
      </div>
      <p className="sheet-note">A chat is Active while it's working or asking you, for a while after its last activity, and, if you keep them, while it has activity you haven't seen.</p>
      <div className="grouped spaced">
        <OrderRow label="Pinned" value={settings.pinnedOrder} choices={pinnedOrders} onChange={value => set("pinnedOrder", value)} />
        <OrderRow label="Active" value={settings.activeOrder} choices={groupOrders} onChange={value => set("activeOrder", value)} />
        <OrderRow label="Earlier" value={settings.earlierOrder} choices={groupOrders} onChange={value => set("earlierOrder", value)} />
        <label className="grouped-row">
          <span className="grouped-label">Earlier shows</span>
          <select aria-label="Earlier shows" value={settings.earlierLimit ?? "all"} onChange={event => set("earlierLimit", event.target.value === "all" ? null : Number(event.target.value))}>
            {earlierLimitChoices.map(value => <option key={value ?? "all"} value={value ?? "all"}>{value === null ? "Every chat" : `${value} chats`}</option>)}
          </select>
        </label>
        <label className="grouped-row">
          <span className="grouped-label">Fold Earlier away</span>
          <input type="checkbox" checked={settings.earlierCollapsed} onChange={event => set("earlierCollapsed", event.target.checked)} />
        </label>
      </div>
      <div className="grouped spaced">
        <label className="grouped-row">
          <span className="grouped-label">New activity shows as</span>
          <select aria-label="New activity shows as" value={settings.unseenMarker} onChange={event => set("unseenMarker", event.target.value as GroupingSettings["unseenMarker"])}>
            {(Object.keys(unseenMarkerTitles) as GroupingSettings["unseenMarker"][]).map(value => <option key={value} value={value}>{unseenMarkerTitles[value]}</option>)}
          </select>
        </label>
        <label className="grouped-row">
          <span className="grouped-label">Group titles</span>
          <input type="checkbox" checked={settings.showsGroupTitles} onChange={event => set("showsGroupTitles", event.target.checked)} />
        </label>
      </div>
      <p className="sheet-note">Pins and these settings stay in this browser.</p>
    </>
  );
}

function OrderRow({ label, value, choices, onChange }: { label: string; value: RowOrder; choices: readonly RowOrder[]; onChange: (value: RowOrder) => void }) {
  return (
    <label className="grouped-row">
      <span className="grouped-label">{label} in order of</span>
      <select aria-label={`${label} in order of`} value={value} onChange={event => onChange(event.target.value as RowOrder)}>
        {choices.map(choice => <option key={choice} value={choice}>{rowOrderTitles[choice]}</option>)}
      </select>
    </label>
  );
}
