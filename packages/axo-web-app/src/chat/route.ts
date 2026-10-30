import type { Selection } from "./workbench.ts";

/**
 * Where the app is, in its URL, so a reload or a link opens the same chat: `<base>` is a new chat,
 * `<base>/<hostId>/<sessionId>` a chat on a Mac. A session id is only unique on its Mac.
 */
export type ChatRoute = { kind: "new" } | { kind: "chat"; hostId: string; sessionId: number };

const chatPath = /^\/([A-Za-z0-9-]{1,64})\/(\d{1,9})\/?$/;

/** The route `pathname` names under `base`; anything else is a new chat. */
export function parseRoute(base: string, pathname: string): ChatRoute {
  if (!pathname.startsWith(base)) return { kind: "new" };
  const match = chatPath.exec(pathname.slice(base.length));
  if (!match) return { kind: "new" };
  const sessionId = Number(match[2]);
  return sessionId > 0 ? { kind: "chat", hostId: match[1]!, sessionId } : { kind: "new" };
}

/** The path for what is on screen: the open chat, or `base` for a new one. */
export function routePath(base: string, hostId: string | null, selection: Selection | null): string {
  return hostId && selection?.kind === "chat" ? `${base}/${encodeURIComponent(hostId)}/${selection.sessionId}` : base;
}
