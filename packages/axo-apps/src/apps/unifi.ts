import { z } from "zod";
import { tool, type AppDefinition, type AppTool, type ProviderApi } from "../app";
import { header } from "../token";

/**
 * UniFi as an app: `codemode.apps.unifi.<tool>({ account, ... })`, with a Site Manager API key
 * from unifi.ui.com; the person names the account. It reads the consoles, sites and devices the
 * UniFi account holds, through Ubiquiti's cloud. A console's own network API (clients, settings)
 * is reached on the local network, from a Mac.
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
];

export const unifi: AppDefinition = {
  name: "unifi",
  title: "UniFi",
  description: "Your UniFi consoles, sites and devices, and your internet's speed and uptime, through Ubiquiti's cloud.",
  permissions: [
    "See your UniFi consoles and sites",
    "See your adopted devices and their state",
    "See your internet connection's speed, latency and uptime",
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
