import { z } from "zod";
import { ProviderError, tool, type AppDefinition, type AppTool, type ProviderApi } from "../app";
import { bearer } from "../token";

/**
 * Hetzner as an app: `codemode.apps.hetzner.<tool>({ account, ... })`, with an API token from
 * Hetzner Console. A token belongs to one project, so each account is a project the person names
 * ("personal"); Hetzner has no API that names it. The Cloud API (api.hetzner.cloud) covers
 * servers, DNS zones, firewalls, volumes and networks; the Hetzner API (api.hetzner.com), with the
 * same token, covers storage boxes. `request` reaches any other endpoint of either.
 */

const id = z.number().int().positive();
const zone = z.string().min(1).max(255).describe("The zone's name, such as \"example.com\", or its ID.");
const rrName = z.string().min(1).max(255).regex(/^[a-z0-9@*_.-]+$/, "lowercase, without the zone name; \"@\" for the zone itself")
  .describe("The record's name without the zone, such as \"www\"; \"@\" for the zone itself.");
const rrType = z.enum(["A", "AAAA", "CAA", "CNAME", "DS", "HINFO", "HTTPS", "MX", "NS", "PTR", "RP", "SOA", "SRV", "SVCB", "TLSA", "TXT"]);
const labelSelector = z.string().max(1024).optional().describe("Hetzner's label selector, such as \"env=prod\".");

type Page<K extends string, T> = { [key in K]: T[] } & { meta?: { pagination?: { next_page?: number | null } } };

/** Every page of a list, up to `limit` items. */
async function all<T>(api: ProviderApi, path: string, key: string, query: Record<string, string | undefined>, limit = 500, origin = ""): Promise<T[]> {
  const items: T[] = [];
  for (let page = 1; page && items.length < limit;) {
    const answer = (await api.request("GET", `${origin}${path}`, { query: { ...query, page: String(page), per_page: "50" } })) as Page<string, T>;
    items.push(...(answer[key] ?? []));
    page = answer.meta?.pagination?.next_page ?? 0;
  }
  return items.slice(0, limit);
}

type Server = {
  id: number; name: string; status: string; created: string; labels: Record<string, string>;
  server_type?: { name?: string; cores?: number; memory?: number; disk?: number };
  datacenter?: { name?: string; location?: { name?: string; city?: string } };
  public_net?: { ipv4?: { ip?: string } | null; ipv6?: { ip?: string } | null };
  image?: { name?: string | null; description?: string } | null;
};

function server(s: Server) {
  return {
    id: s.id,
    name: s.name,
    status: s.status,
    type: s.server_type?.name ?? null,
    cores: s.server_type?.cores ?? null,
    memoryGb: s.server_type?.memory ?? null,
    diskGb: s.server_type?.disk ?? null,
    location: s.datacenter?.location?.name ?? null,
    city: s.datacenter?.location?.city ?? null,
    ipv4: s.public_net?.ipv4?.ip ?? null,
    ipv6: s.public_net?.ipv6?.ip ?? null,
    image: s.image?.name ?? s.image?.description ?? null,
    created: s.created,
    labels: s.labels,
  };
}

type Rrset = { id: string; name: string; type: string; ttl: number | null; records: Array<{ value: string; comment?: string | null }>; labels?: Record<string, string> };

function rrset(r: Rrset) {
  return { name: r.name, type: r.type, ttl: r.ttl, records: r.records.map((x) => ({ value: x.value, comment: x.comment ?? null })) };
}

const records = z.array(z.object({ value: z.string().min(1).max(4096), comment: z.string().max(255).optional() }).strict()).min(1).max(50)
  .describe("The record values, such as [{ value: \"198.51.100.1\" }]; a TXT value is quoted, such as \"\\\"v=spf1 -all\\\"\".");

const tools: AppTool[] = [
  tool({
    name: "list_servers",
    description: "Lists the project's servers: { servers: [{ id, name, status, type, cores, memoryGb, diskGb, location, city, ipv4, ipv6, image, created, labels }] }.",
    input: z.object({ name: z.string().max(255).optional(), labelSelector, status: z.enum(["running", "initializing", "starting", "stopping", "off", "deleting", "migrating", "rebuilding", "unknown"]).optional() }).strict(),
    idempotent: true,
    async run(api, input) {
      const servers = await all<Server>(api, "/v1/servers", "servers", { name: input.name, label_selector: input.labelSelector, status: input.status });
      return { servers: servers.map(server) };
    },
  }),
  tool({
    name: "get_server",
    description: "Gets one server with everything Hetzner says about it: { server } as the Cloud API returns it.",
    input: z.object({ id }).strict(),
    idempotent: true,
    async run(api, input) {
      return api.request("GET", `/v1/servers/${input.id}`);
    },
  }),
  tool({
    name: "server_action",
    description:
      "Powers a server on or off, shuts it down gracefully, reboots it gracefully, or resets it (a hard reboot). " +
      "Returns the action: { action: { id, command, status, progress } }; poll get_action until its status is success or error. Prefer shutdown and reboot to poweroff and reset.",
    input: z.object({ id, action: z.enum(["poweron", "poweroff", "shutdown", "reboot", "reset"]) }).strict(),
    idempotent: false,
    async run(api, input) {
      return api.request("POST", `/v1/servers/${input.id}/actions/${input.action}`);
    },
  }),
  tool({
    name: "server_metrics",
    description: "A server's CPU, disk or network usage over time: { metrics: { start, end, step, time_series } } as the Cloud API returns it. Times are ISO 8601.",
    input: z.object({
      id,
      type: z.enum(["cpu", "disk", "network"]),
      start: z.iso.datetime({ offset: true }),
      end: z.iso.datetime({ offset: true }),
      step: z.number().int().min(1).max(86_400).optional().describe("Seconds between points; Hetzner picks one when left out."),
    }).strict(),
    idempotent: true,
    async run(api, input) {
      return api.request("GET", `/v1/servers/${input.id}/metrics`, { query: { type: input.type, start: input.start, end: input.end, step: input.step?.toString() } });
    },
  }),
  tool({
    name: "get_action",
    description: "Gets an action, such as one server_action started: { action: { id, command, status, progress, error } }.",
    input: z.object({ id }).strict(),
    idempotent: true,
    async run(api, input) {
      return api.request("GET", `/v1/actions/${input.id}`);
    },
  }),
  tool({
    name: "list_zones",
    description: "Lists the project's DNS zones: { zones: [{ id, name, mode, status, ttl, recordCount, nameservers, created }] }.",
    input: z.object({ name: z.string().max(255).optional(), labelSelector }).strict(),
    idempotent: true,
    async run(api, input) {
      const zones = await all<{ id: number; name: string; mode: string; status: string; ttl: number; record_count?: number; authoritative_nameservers?: { assigned?: string[] }; created: string }>(
        api, "/v1/zones", "zones", { name: input.name, label_selector: input.labelSelector });
      return {
        zones: zones.map((z) => ({ id: z.id, name: z.name, mode: z.mode, status: z.status, ttl: z.ttl, recordCount: z.record_count ?? null, nameservers: z.authoritative_nameservers?.assigned ?? [], created: z.created })),
      };
    },
  }),
  tool({
    name: "list_records",
    description: "Lists a zone's DNS records, grouped by name and type: { records: [{ name, type, ttl, records: [{ value, comment }] }] }. `ttl` null means the zone's default.",
    input: z.object({ zone, name: rrName.optional(), type: rrType.optional() }).strict(),
    idempotent: true,
    async run(api, input) {
      const rrsets = await all<Rrset>(api, `/v1/zones/${encodeURIComponent(input.zone)}/rrsets`, "rrsets", { name: input.name, type: input.type }, 2000);
      return { records: rrsets.map(rrset) };
    },
  }),
  tool({
    name: "set_records",
    description:
      "Sets the DNS records of one name and type in a zone, creating them if there are none: afterwards exactly `records` are there. " +
      "Returns { records: { name, type, ttl, records } }.",
    input: z.object({ zone, name: rrName, type: rrType, records, ttl: z.number().int().min(60).max(2_147_483_647).optional().describe("Seconds; the zone's default when left out.") }).strict(),
    idempotent: true,
    async run(api, input) {
      const base = `/v1/zones/${encodeURIComponent(input.zone)}/rrsets`;
      const at = `${base}/${encodeURIComponent(input.name)}/${input.type}`;
      try {
        await api.request("POST", `${at}/actions/set_records`, { body: { records: input.records } });
        if (input.ttl !== undefined) await api.request("POST", `${at}/actions/change_ttl`, { body: { ttl: input.ttl } });
      } catch (error) {
        if (!(error instanceof ProviderError && error.status === 404)) throw error;
        await api.request("POST", base, { body: { name: input.name, type: input.type, ttl: input.ttl, records: input.records } });
      }
      const answer = (await api.request("GET", at)) as { rrset: Rrset };
      return { records: rrset(answer.rrset) };
    },
  }),
  tool({
    name: "delete_records",
    description: "Deletes every DNS record of one name and type in a zone. Returns { deleted: true }.",
    input: z.object({ zone, name: rrName, type: rrType }).strict(),
    idempotent: true,
    async run(api, input) {
      await api.request("DELETE", `/v1/zones/${encodeURIComponent(input.zone)}/rrsets/${encodeURIComponent(input.name)}/${input.type}`);
      return { deleted: true };
    },
  }),
  tool({
    name: "list_firewalls",
    description: "Lists the project's firewalls with their rules and what they apply to: { firewalls } as the Cloud API returns them.",
    input: z.object({ labelSelector }).strict(),
    idempotent: true,
    async run(api, input) {
      return { firewalls: await all(api, "/v1/firewalls", "firewalls", { label_selector: input.labelSelector }) };
    },
  }),
  tool({
    name: "list_volumes",
    description: "Lists the project's volumes: { volumes: [{ id, name, sizeGb, server, location, status, linuxDevice }] }.",
    input: z.object({ labelSelector }).strict(),
    idempotent: true,
    async run(api, input) {
      const volumes = await all<{ id: number; name: string; size: number; server: number | null; location?: { name?: string }; status: string; linux_device?: string }>(
        api, "/v1/volumes", "volumes", { label_selector: input.labelSelector });
      return { volumes: volumes.map((v) => ({ id: v.id, name: v.name, sizeGb: v.size, server: v.server, location: v.location?.name ?? null, status: v.status, linuxDevice: v.linux_device ?? null })) };
    },
  }),
  tool({
    name: "list_storage_boxes",
    description: "Lists the project's storage boxes: { storageBoxes: [{ id, name, username, server, type, status, location, usedGb, sizeGb }] }.",
    input: z.object({}).strict(),
    idempotent: true,
    async run(api) {
      const boxes = await all<{ id: number; name: string; username: string; server: string; status: string; storage_box_type?: { name?: string; size?: number }; location?: { name?: string }; stats?: { size?: number } }>(
        api, "/v1/storage_boxes", "storage_boxes", {}, 500, "https://api.hetzner.com");
      const gb = (bytes: number | undefined) => (bytes === undefined ? null : Math.round(bytes / 1e7) / 100);
      return {
        storageBoxes: boxes.map((b) => ({ id: b.id, name: b.name, username: b.username, server: b.server, type: b.storage_box_type?.name ?? null, status: b.status, location: b.location?.name ?? null, usedGb: gb(b.stats?.size), sizeGb: gb(b.storage_box_type?.size) })),
      };
    },
  }),
];

export const hetzner: AppDefinition = {
  name: "hetzner",
  title: "Hetzner",
  description: "Your Hetzner Cloud projects: servers, DNS, firewalls, volumes and storage boxes.",
  permissions: [
    "See the project's servers and their usage, and start, stop or restart them",
    "See and change the project's DNS zones and records",
    "See the project's firewalls, volumes, networks, IP addresses and storage boxes",
    "Do anything else the project's API token allows",
  ],
  signIn: "token",
  provider: "hetzner",
  providerTitle: "Hetzner",
  category: "developer",
  apiOrigin: "https://api.hetzner.cloud",
  hosts: ["api.hetzner.cloud", "api.hetzner.com"],
  reference: "https://docs.hetzner.cloud/reference/cloud (storage boxes: https://docs.hetzner.cloud/reference/hetzner at https://api.hetzner.com/v1)",
  token: {
    helpUrl: "https://console.hetzner.com/projects",
    named: true,
    fields: [{
      name: "token",
      label: "API token",
      help: "In Hetzner Console, open the project, then Security, API tokens, Generate API token. Choose Read & Write to let Axo make changes.",
      secret: true,
    }],
    authorize: bearer("token"),
    async identify(api) {
      await api.request("GET", "/v1/servers", { query: { per_page: "1" } });
      return null;
    },
  },
  tools,
};
