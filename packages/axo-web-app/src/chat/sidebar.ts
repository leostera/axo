/**
 * The chat list's groups, as the Mac's sidebar has them (SessionNavigation.swift): Pinned, then
 * Active, then Earlier. Pins, what was seen and how to group live in this browser alone: they never
 * reach the Mac, the cloud or another device. The defaults are the Mac's, so every client lists
 * chats the same way until someone changes their own.
 */
import { chatTitle, lastActivity, type ChatMenuEntry } from "./workbench.ts";

// MARK: - Pins

/**
 * Chats pinned to the top of the list, by Session id. A pin outlives its chat's absence, because
 * absence is often temporary (a Mac offline, a chat reopened); a pin whose chat is not listed does
 * nothing, and once there are `capacity` pins the oldest go, so dead ones cannot pile up.
 */
export class SessionPins {
  static readonly capacity = 256;
  /** Oldest pin first, without duplicates, at most `capacity`. */
  readonly ids: readonly string[];

  constructor(ids: readonly string[] = []) {
    const unique = [...new Set(ids)];
    this.ids = unique.slice(Math.max(0, unique.length - SessionPins.capacity));
  }

  /** Pins as stored; anything that is not a list of strings is no pins. */
  static parse(stored: unknown): SessionPins {
    return new SessionPins(Array.isArray(stored) ? stored.filter((id): id is string => typeof id === "string") : []);
  }

  has(sessionId: string): boolean {
    return this.ids.includes(sessionId);
  }

  /** Pins `sessionId`, or unpins it if it is pinned. */
  toggled(sessionId: string): SessionPins {
    return new SessionPins(this.has(sessionId) ? this.ids.filter(id => id !== sessionId) : [...this.ids, sessionId]);
  }
}

// MARK: - Seen

/**
 * When this browser last saw each chat, so the list can tell which have activity nobody looked at.
 * A chat never marked counts as seen at `baseline`, when this browser started keeping track: what
 * happened before is not news. At most `capacity` marks are kept, the oldest dropping back to the
 * baseline, so they read as seen.
 */
export class SessionSeen {
  static readonly capacity = 1024;

  /** Milliseconds since 1970, as are the marks. */
  readonly baseline: number;
  readonly seenAt: ReadonlyMap<string, number>;

  constructor(baseline: number, seenAt: ReadonlyMap<string, number> = new Map()) {
    this.baseline = baseline;
    this.seenAt = seenAt.size > SessionSeen.capacity
      ? new Map([...seenAt].sort((a, b) => b[1] - a[1]).slice(0, SessionSeen.capacity))
      : seenAt;
  }

  static parse(baseline: unknown, stored: unknown, now: number): SessionSeen {
    const start = typeof baseline === "number" && Number.isFinite(baseline) ? baseline : now;
    const marks = new Map<string, number>();
    if (stored && typeof stored === "object" && !Array.isArray(stored)) {
      for (const [id, at] of Object.entries(stored)) if (typeof at === "number" && Number.isFinite(at)) marks.set(id, at);
    }
    return new SessionSeen(start, marks);
  }

  get stored(): Record<string, number> {
    return Object.fromEntries(this.seenAt);
  }

  /** Whether the chat has had activity since it was last seen. */
  isUnseen(entry: ChatMenuEntry): boolean {
    return lastActivity(entry.session) > (this.seenAt.get(entry.session.sessionId) ?? this.baseline);
  }

  /**
   * Marks the chat seen at `now`, or at its last activity if that is later (a Mac's clock may run
   * ahead). The same marks when nothing changes, so callers can tell.
   */
  marked(entry: ChatMenuEntry, now: number): SessionSeen {
    const id = entry.session.sessionId;
    const mark = Math.max(now, lastActivity(entry.session));
    if (!this.isUnseen(entry) && this.seenAt.has(id)) return this;
    if ((this.seenAt.get(id) ?? -Infinity) >= mark) return this;
    return new SessionSeen(this.baseline, new Map(this.seenAt).set(id, mark));
  }
}

// MARK: - Settings

export type RowOrder = "pinned" | "name" | "created" | "activity";
export type UnseenMarker = "dotAndBold" | "dot" | "bold" | "none";

export const rowOrderTitles: Record<RowOrder, string> = {
  pinned: "Order pinned", name: "Name (A to Z)", created: "Newest first", activity: "Latest activity",
};
export const unseenMarkerTitles: Record<UnseenMarker, string> = {
  dotAndBold: "Dot and bold name", dot: "Dot", bold: "Bold name", none: "Nothing",
};
export const pinnedOrders: readonly RowOrder[] = ["pinned", "name", "activity"];
export const groupOrders: readonly RowOrder[] = ["name", "created", "activity"];
export const activeWindowChoices = [1, 3, 5, 10, 15, 30, 60] as const;
export const regroupIntervalChoices = [10, 30, 60, 300] as const;
/** How many Earlier chats show before "Show all"; null is every one. */
export const earlierLimitChoices = [null, 5, 10, 20, 50] as const;

/** How the list groups chats, from Settings › Chats, saved in this browser. */
export interface GroupingSettings {
  /** How long a chat stays Active after its last activity. */
  readonly activeWindowMinutes: number;
  /** How often chats move between groups, in seconds. */
  readonly regroupIntervalSeconds: number;
  /** Whether a chat with activity not yet seen stays Active until it is seen. */
  readonly unseenStayActive: boolean;
  readonly unseenMarker: UnseenMarker;
  readonly pinnedOrder: RowOrder;
  readonly activeOrder: RowOrder;
  readonly earlierOrder: RowOrder;
  readonly showsGroupTitles: boolean;
  /** Whether Earlier starts folded away under its title. */
  readonly earlierCollapsed: boolean;
  /** How many Earlier chats show before "Show all"; null shows every one. */
  readonly earlierLimit: number | null;
}

/** The Mac's defaults; Earlier starts open with every chat, as the Mac lists it. */
export const defaultGrouping: GroupingSettings = {
  activeWindowMinutes: 3,
  regroupIntervalSeconds: 30,
  unseenStayActive: true,
  unseenMarker: "dotAndBold",
  pinnedOrder: "pinned",
  activeOrder: "name",
  earlierOrder: "activity",
  showsGroupTitles: true,
  earlierCollapsed: false,
  earlierLimit: null,
};

/** Settings as stored: anything missing, unknown or out of range takes its default, so a newer or older Axo's settings always load. */
export function parseGrouping(stored: unknown): GroupingSettings {
  const value = stored && typeof stored === "object" ? stored as Record<string, unknown> : {};
  const number = (key: keyof GroupingSettings, min: number, max: number) => {
    const raw = value[key];
    return typeof raw === "number" && Number.isFinite(raw) ? Math.min(Math.max(Math.round(raw), min), max) : defaultGrouping[key] as number;
  };
  const flag = (key: keyof GroupingSettings) => typeof value[key] === "boolean" ? value[key] as boolean : defaultGrouping[key] as boolean;
  const pick = <T extends string>(key: keyof GroupingSettings, choices: readonly T[]) =>
    choices.includes(value[key] as T) ? value[key] as T : defaultGrouping[key] as T;
  const limit = value.earlierLimit;
  return {
    activeWindowMinutes: number("activeWindowMinutes", 1, 24 * 60),
    regroupIntervalSeconds: number("regroupIntervalSeconds", 5, 3_600),
    unseenStayActive: flag("unseenStayActive"),
    unseenMarker: pick("unseenMarker", Object.keys(unseenMarkerTitles) as UnseenMarker[]),
    pinnedOrder: pick("pinnedOrder", pinnedOrders),
    activeOrder: pick("activeOrder", groupOrders),
    earlierOrder: pick("earlierOrder", groupOrders),
    showsGroupTitles: flag("showsGroupTitles"),
    earlierCollapsed: flag("earlierCollapsed"),
    earlierLimit: limit === null ? null : typeof limit === "number" && Number.isInteger(limit) && limit > 0 ? Math.min(limit, 1_000) : defaultGrouping.earlierLimit,
  };
}

// MARK: - Grouping

export type ChatGroup = "pinned" | "active" | "earlier";
export const groupTitles: Record<ChatGroup, string> = { pinned: "Pinned", active: "Active", earlier: "Earlier" };
const groupOrder: readonly ChatGroup[] = ["pinned", "active", "earlier"];

export interface ChatSection {
  readonly group: ChatGroup;
  readonly entries: readonly ChatMenuEntry[];
}

export interface GroupingState {
  readonly pins: SessionPins;
  readonly seen: SessionSeen;
  /** When the groups are worked out, in milliseconds: moved on a slow tick, so chats leave Active a few at a time. */
  readonly now: number;
  readonly settings: GroupingSettings;
  /** Chats whose agent waits for the person's answer (RFD0029), which need them like `needsAttention`. */
  readonly asking?: ReadonlySet<string>;
}

/**
 * The group a chat belongs in: Pinned if pinned; Active while its agent works or waits for the
 * person, while it has activity not yet seen (if so set), or for a while after its last activity;
 * otherwise Earlier.
 */
export function groupOf(entry: ChatMenuEntry, state: GroupingState): ChatGroup {
  const { session } = entry;
  if (state.pins.has(session.sessionId)) return "pinned";
  if (session.status === "working" || session.status === "needsAttention" || state.asking?.has(session.sessionId)) return "active";
  if (state.settings.unseenStayActive && state.seen.isUnseen(entry)) return "active";
  if (state.now - lastActivity(session) < state.settings.activeWindowMinutes * 60_000) return "active";
  return "earlier";
}

/** The chats in their groups, top to bottom; a group without chats is left out. */
export function chatSections(entries: readonly ChatMenuEntry[], state: GroupingState): ChatSection[] {
  const byGroup = new Map<ChatGroup, ChatMenuEntry[]>();
  for (const entry of entries) {
    const group = groupOf(entry, state);
    byGroup.set(group, [...(byGroup.get(group) ?? []), entry]);
  }
  const orderOf: Record<ChatGroup, RowOrder> = {
    pinned: state.settings.pinnedOrder, active: state.settings.activeOrder, earlier: state.settings.earlierOrder,
  };
  return groupOrder.flatMap(group => {
    const members = byGroup.get(group);
    return members?.length ? [{ group, entries: ordered(members, orderOf[group], state.pins) }] : [];
  });
}

function ordered(entries: readonly ChatMenuEntry[], order: RowOrder, pins: SessionPins): ChatMenuEntry[] {
  const byId = (a: ChatMenuEntry, b: ChatMenuEntry) => a.session.sessionId.localeCompare(b.session.sessionId);
  switch (order) {
    case "pinned": {
      const rank = new Map(pins.ids.map((id, index) => [id, index]));
      return [...entries].sort((a, b) => (rank.get(a.session.sessionId) ?? Infinity) - (rank.get(b.session.sessionId) ?? Infinity));
    }
    case "name":
      return [...entries].sort((a, b) => chatTitle(a.session).localeCompare(chatTitle(b.session), undefined, { numeric: true, sensitivity: "base" }) || byId(a, b));
    case "created":
      return [...entries].sort((a, b) => (b.session.createdAt ?? 0) - (a.session.createdAt ?? 0) || byId(b, a));
    case "activity":
      return [...entries].sort((a, b) => lastActivity(b.session) - lastActivity(a.session) || (b.session.createdAt ?? 0) - (a.session.createdAt ?? 0) || byId(b, a));
  }
}

const sessionKey = (entry: ChatMenuEntry) => entry.session.sessionId;

/**
 * `live` shown as `held` remembers it, so rows do not move under the pointer: each held chat keeps
 * its group and place, chats new since go first in their live group, and gone ones drop out. Pins
 * apply at once, so a chat pinned under the pointer moves up.
 */
export function holdingSections(held: readonly ChatSection[] | null, live: readonly ChatSection[]): ChatSection[] {
  if (!held) return [...live];
  const liveById = new Map<string, { entry: ChatMenuEntry; group: ChatGroup }>();
  for (const section of live) for (const entry of section.entries) liveById.set(sessionKey(entry), { entry, group: section.group });
  const heldGroup = new Map<string, ChatGroup>();
  for (const section of held) for (const entry of section.entries) heldGroup.set(sessionKey(entry), section.group);
  const placement = (id: string): ChatGroup | null => {
    const now = liveById.get(id);
    if (!now) return null;
    if (now.group === "pinned") return "pinned";
    const before = heldGroup.get(id);
    return before === undefined || before === "pinned" ? now.group : before;
  };
  return groupOrder.flatMap(group => {
    let members: ChatMenuEntry[];
    if (group === "pinned") {
      members = [...(live.find(section => section.group === "pinned")?.entries ?? [])];
    } else {
      const fresh = (live.find(section => section.group === group)?.entries ?? [])
        .filter(entry => { const before = heldGroup.get(sessionKey(entry)); return before === undefined || before === "pinned"; });
      const kept = (held.find(section => section.group === group)?.entries ?? [])
        .flatMap(entry => placement(sessionKey(entry)) === group ? [liveById.get(sessionKey(entry))!.entry] : []);
      members = [...fresh, ...kept];
    }
    return members.length ? [{ group, entries: members }] : [];
  });
}

// MARK: - Storage

export const storageKeys = {
  pins: "sidebar.pinnedSessions.v1",
  seen: "sidebar.seenSessions.v1",
  seenBaseline: "sidebar.seenSessionsBaseline.v1",
  grouping: "sidebar.grouping.v1",
} as const;

function read(key: string): unknown {
  try {
    const raw = window.localStorage.getItem(key);
    return raw === null ? undefined : JSON.parse(raw);
  } catch {
    return undefined;
  }
}

function write(key: string, value: unknown): void {
  try {
    window.localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // Storage full or refused (a private window): the list still works for this visit.
  }
}

export const storedPins = () => SessionPins.parse(read(storageKeys.pins));
export const savePins = (pins: SessionPins) => write(storageKeys.pins, pins.ids);

export function storedSeen(now: number): SessionSeen {
  const baseline = read(storageKeys.seenBaseline);
  const seen = SessionSeen.parse(baseline, read(storageKeys.seen), now);
  if (typeof baseline !== "number") write(storageKeys.seenBaseline, seen.baseline);
  return seen;
}
export const saveSeen = (seen: SessionSeen) => write(storageKeys.seen, seen.stored);

export const storedGrouping = () => parseGrouping(read(storageKeys.grouping));
export const saveGrouping = (settings: GroupingSettings) => write(storageKeys.grouping, settings);
