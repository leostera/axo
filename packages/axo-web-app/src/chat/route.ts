import type { Selection } from "./workbench.ts";

/**
 * Where the app is, in its URL, so a reload or a link opens the same chat: `<base>` is a new chat,
 * `<base>/<hostId>/<sessionId>` a chat on a Mac. The host says which Mac to route to.
 */
export type ChatRoute = { kind: "new" } | { kind: "chat"; hostId: string; sessionId: string };

const chatPath = /^\/([A-Za-z0-9-]{1,64})\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/?$/;

/** The route `pathname` names under `base`; anything else is a new chat. */
export function parseRoute(base: string, pathname: string): ChatRoute {
  if (!pathname.startsWith(base)) return { kind: "new" };
  const match = chatPath.exec(pathname.slice(base.length));
  if (!match) return { kind: "new" };
  return { kind: "chat", hostId: match[1]!, sessionId: match[2]! };
}

/** The path for what is on screen: the open chat, or `base` for a new one. */
export function routePath(base: string, hostId: string | null, selection: Selection | null): string {
  return hostId && selection?.kind === "chat" ? `${base}/${encodeURIComponent(hostId)}/${selection.sessionId}` : base;
}

/**
 * Settings pages, over the chats: `<base>/settings/apps` lists the apps, `<base>/settings/apps/<app>`
 * is one app (`gmail` for `apps.gmail`), `<base>/settings/apps/mcp` the MCP servers and
 * `<base>/settings/apps/activity` everything Sessions used. `<base>/connections`, where sign-ins
 * used to come back, is Apps.
 */
export type SettingsRoute = { kind: "apps" } | { kind: "app"; app: string } | { kind: "servers" } | { kind: "activity" };

export function parseSettingsRoute(base: string, pathname: string): SettingsRoute | null {
  if (!pathname.startsWith(`${base}/`)) return null;
  const rest = pathname.slice(base.length).replace(/\/+$/, "");
  if (rest === "/settings" || rest === "/settings/apps" || rest === "/connections") return { kind: "apps" };
  const page = /^\/settings\/apps\/([a-z][a-z0-9_]{0,31})$/.exec(rest)?.[1];
  if (!page) return null;
  if (page === "mcp") return { kind: "servers" };
  if (page === "activity") return { kind: "activity" };
  return { kind: "app", app: page };
}

export function settingsPath(base: string, route: SettingsRoute): string {
  const apps = `${base}/settings/apps`;
  switch (route.kind) {
    case "apps": return apps;
    case "app": return `${apps}/${encodeURIComponent(route.app)}`;
    case "servers": return `${apps}/mcp`;
    case "activity": return `${apps}/activity`;
  }
}
