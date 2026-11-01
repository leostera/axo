import { z } from "zod";
import { ProviderError, tool, type AppDefinition, type AppTool, type ProviderApi } from "../app";
import { header } from "../token";

/**
 * UniFi as an app: `codemode.apps.unifi.<tool>({ account, ... })`, with a Site Manager API key
 * from unifi.ui.com; the person names the account. It reads the consoles, sites and devices the
 * UniFi account holds, through Ubiquiti's cloud, and each console's own Network API (its clients
 * and their traffic) through the cloud connector: `/v1/connector/consoles/<host>/proxy/network`.
 */

type Page<T> = { data: T[]; nextToken?: string | null };

async function all<T>(api: ProviderApi, path: string, query: Record<string, string | string[] | undefined> = {}): Promise<T[]> {
  const items: T[] = [];
  let next: string | undefined;
  do {
    const page = (await api.request("GET", path, { query: { ...query, pageSize: "200", nextToken: next } })) as Page<T>;
    items.push(...(page.data ?? []));
    next = page.nextToken ?? undefined;
  } while (next && items.length < 2000);
  return items;
}

const hostInput = z.string().min(1).max(200).optional().describe("The console's host ID, from list_hosts; left out when the account has one console.");
const siteInput = z.string().regex(/^[A-Za-z0-9_-]{1,64}$/).optional().describe("The site's internal name on the console; `default` when left out.");

/** The console a call names, or the account's only one. */
async function consoleOf(api: ProviderApi, host: string | undefined): Promise<string> {
  if (host) return host;
  const hosts = await all<{ id: string; reportedState?: { name?: string; hostname?: string } }>(api, "/v1/hosts");
  if (hosts.length === 1) return hosts[0]!.id;
  const names = hosts.map((h) => `${h.id} (${h.reportedState?.name ?? h.reportedState?.hostname ?? "unnamed"})`).join(", ");
  throw new ProviderError(400, hosts.length ? `this account has ${hosts.length} consoles: pass \`host\`, one of ${names}` : "this account has no console");
}

const network = (host: string) => `/v1/connector/consoles/${encodeURIComponent(host)}/proxy/network`;

/** Every item of one of the Network API's offset-paged lists (`{ data, totalCount }`). */
async function offsetPaged<T>(api: ProviderApi, path: string): Promise<T[]> {
  const items: T[] = [];
  for (;;) {
    const page = (await api.request("GET", path, { query: { offset: String(items.length), limit: "200" } })) as { data?: T[]; totalCount?: number };
    items.push(...(page.data ?? []));
    if (!page.data?.length || items.length >= (page.totalCount ?? 0) || items.length >= 10_000) return items;
  }
}

type Client = {
  mac: string; name?: string; hostname?: string; ip?: string; last_ip?: string; is_wired?: boolean; essid?: string; network?: string;
  last_uplink_name?: string; first_seen?: number; last_seen?: number; rx_bytes?: number; tx_bytes?: number; signal?: number; oui?: string;
};
type Usage = { application: number; category: number; bytes_received?: number; bytes_transmitted?: number; total_bytes?: number; client_count?: number };
type Traffic = {
  total_usage_by_app?: Usage[];
  client_usage_by_app?: Array<{ client: { mac: string; name?: string; hostname?: string }; usage_by_app: Usage[] }>;
};

const seconds = (s: number | undefined) => (s ? new Date(s * 1000).toISOString() : null);
const deviceName = (c: { mac: string; name?: string; hostname?: string }) => c.name || c.hostname || c.mac;

const tools: AppTool[] = [
  tool({
    name: "list_hosts",
    description: "The UniFi consoles of the account (such as a UDM or UniFi Express): { hosts: [...] } as Ubiquiti gives them, with their IDs, hardware, firmware and state.",
    input: z.object({}).strict(),
    idempotent: true,
    run: async (api) => ({ hosts: await all(api, "/v1/hosts") }),
  }),
  tool({
    name: "list_sites",
    description: "The sites on the account's consoles, with their device and client counts and ISP: { sites: [...] }.",
    input: z.object({}).strict(),
    idempotent: true,
    run: async (api) => ({ sites: await all(api, "/v1/sites") }),
  }),
  tool({
    name: "list_devices",
    description: "The devices (access points, switches, gateways) adopted on the account's consoles, by host: { hosts: [{ hostId, hostName, devices: [{ name, model, ip, mac, status, version }] }] }.",
    input: z.object({ hostIds: z.array(z.string().min(1).max(200)).max(50).optional().describe("Only these consoles'.") }).strict(),
    idempotent: true,
    async run(api, input) {
      const hosts = await all<{ hostId: string; hostName?: string; devices?: unknown[] }>(api, "/v1/devices", { "hostIds[]": input.hostIds });
      return { hosts };
    },
  }),
  tool({
    name: "get_isp_metrics",
    description: "Internet speed, latency, packet loss and uptime per site over time: `5m` for the last day, `1h` for the last month. Returns Ubiquiti's { data }.",
    input: z.object({ interval: z.enum(["5m", "1h"]) }).strict(),
    idempotent: true,
    run: (api, input) => api.request("GET", `/ea/isp-metrics/${input.interval}`),
  }),
  tool({
    name: "list_clients",
    description:
      "The devices connected to a console's network now: { clients: [{ name, hostname, mac, ip, wired, network, uplink, firstSeen, lastSeen, receivedBytes, sentBytes, signal }] }, " +
      "`name` being the name set in UniFi, else the hostname, else the MAC; times are ISO 8601.",
    input: z.object({ host: hostInput, site: siteInput }).strict(),
    idempotent: true,
    async run(api, input) {
      const host = await consoleOf(api, input.host);
      const answer = (await api.request("GET", `${network(host)}/api/s/${input.site ?? "default"}/stat/sta`)) as { data?: Client[] };
      return {
        clients: (answer.data ?? []).map((c) => ({
          name: deviceName(c), hostname: c.hostname ?? null, mac: c.mac, ip: c.ip ?? c.last_ip ?? null, wired: c.is_wired ?? false,
          network: c.essid ?? c.network ?? null, uplink: c.last_uplink_name ?? null, firstSeen: seconds(c.first_seen), lastSeen: seconds(c.last_seen),
          receivedBytes: c.rx_bytes ?? null, sentBytes: c.tx_bytes ?? null, signal: c.signal ?? null,
        })),
      };
    },
  }),
  tool({
    name: "get_traffic",
    description:
      "What the network was used for over the last `hours` (24 by default), by app and by device, from the console's deep packet inspection: " +
      "{ from, to, totalBytes, apps: [{ app, bytes, receivedBytes, sentBytes, devices: [{ device, bytes }] }], devices: [{ device, mac, bytes, apps: [{ app, bytes }] }] }, biggest first. " +
      "Apps are named (\"YouTube\", \"QUIC\", \"Unknown\"); UniFi identifies apps, not the websites visited, and logs domains only for lookups it blocked.",
    input: z.object({
      host: hostInput,
      site: siteInput,
      hours: z.number().int().min(1).max(24 * 30).optional(),
      limit: z.number().int().min(1).max(200).optional().describe("How many apps and devices; 25 when left out."),
    }).strict(),
    idempotent: true,
    async run(api, input) {
      const host = await consoleOf(api, input.host);
      const base = network(host);
      const to = Date.now();
      const from = to - (input.hours ?? 24) * 3_600_000;
      const [traffic, catalogue] = await Promise.all([
        api.request("GET", `${base}/v2/api/site/${input.site ?? "default"}/traffic`, { query: { start: String(from), end: String(to), includeUnidentified: "true" } }) as Promise<Traffic>,
        offsetPaged<{ id: number; name: string }>(api, `${base}/integration/v1/dpi/applications`),
      ]);
      // The catalogue's IDs are an app's category and number together (category << 16 | app); some are the app's number alone.
      const names = new Map(catalogue.map((a) => [a.id, a.name]));
      const appName = (u: Usage) => names.get(u.category * 65_536 + u.application) ?? names.get(u.application) ?? (u.application === 65_535 ? "Unknown" : `app ${u.category}:${u.application}`);
      const limit = input.limit ?? 25;
      const key = (u: Usage) => `${u.category}:${u.application}`;
      const byApp = new Map<string, Array<{ device: string; bytes: number }>>();
      const devices = (traffic.client_usage_by_app ?? []).map(({ client, usage_by_app }) => {
        for (const u of usage_by_app) {
          const list = byApp.get(key(u)) ?? [];
          list.push({ device: deviceName(client), bytes: u.total_bytes ?? 0 });
          byApp.set(key(u), list);
        }
        const apps = [...usage_by_app].sort((a, b) => (b.total_bytes ?? 0) - (a.total_bytes ?? 0));
        return {
          device: deviceName(client), mac: client.mac, bytes: apps.reduce((sum, u) => sum + (u.total_bytes ?? 0), 0),
          apps: apps.slice(0, 10).map((u) => ({ app: appName(u), bytes: u.total_bytes ?? 0 })),
        };
      }).sort((a, b) => b.bytes - a.bytes);
      const apps = [...(traffic.total_usage_by_app ?? [])].sort((a, b) => (b.total_bytes ?? 0) - (a.total_bytes ?? 0));
      return {
        from: new Date(from).toISOString(), to: new Date(to).toISOString(),
        totalBytes: apps.reduce((sum, u) => sum + (u.total_bytes ?? 0), 0),
        apps: apps.slice(0, limit).map((u) => ({
          app: appName(u), bytes: u.total_bytes ?? 0, receivedBytes: u.bytes_received ?? 0, sentBytes: u.bytes_transmitted ?? 0,
          devices: (byApp.get(key(u)) ?? []).sort((a, b) => b.bytes - a.bytes).slice(0, 5),
        })),
        devices: devices.slice(0, limit),
      };
    },
  }),
];

export const unifi: AppDefinition = {
  name: "unifi",
  title: "UniFi",
  description: "Your UniFi consoles, sites and devices, who is on your network and what it is used for, and your internet's speed and uptime.",
  permissions: [
    "See your UniFi consoles and sites",
    "See your adopted devices and their state",
    "See your internet connection's speed, latency and uptime",
    "See the devices on your network and which apps they use",
  ],
  signIn: "token",
  provider: "unifi",
  providerTitle: "Ubiquiti",
  category: "home",
  apiOrigin: "https://api.ui.com",
  hosts: ["api.ui.com"],
  reference: "https://developer.ui.com/site-manager-api/",
  token: {
    helpUrl: "https://unifi.ui.com/api",
    named: true,
    fields: [{ name: "key", label: "API key", help: "At unifi.ui.com, open API in the menu and create an API key.", secret: true }],
    authorize: header("X-API-KEY", "key"),
    async identify(api) {
      await api.request("GET", "/v1/hosts", { query: { pageSize: "1" } });
      return null;
    },
  },
  tools,
};
