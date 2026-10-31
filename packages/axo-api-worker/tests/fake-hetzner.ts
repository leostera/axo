/**
 * Hetzner as the Hetzner app sees it: the Cloud API (api.hetzner.cloud) and the Hetzner API
 * (api.hetzner.com) with project API tokens. A token is a project's; an unknown or revoked one
 * gets 401, as Hetzner answers. Enough of servers, actions, DNS zones and RRSets, volumes and
 * storage boxes for the app's tools, with paging.
 */

type Rrset = { name: string; type: string; ttl: number | null; records: Array<{ value: string; comment: string | null }> };

export class FakeHetzner {
  /** Token → project. */
  readonly tokens = new Map<string, string>([["hz-personal-token", "personal"], ["hz-work-token", "work"]]);
  readonly calls: Array<{ project: string | null; call: string; headers: Headers; body: string }> = [];
  readonly servers = new Map<string, Array<{ id: number; name: string; status: string }>>([
    ["personal", Array.from({ length: 60 }, (_, i) => ({ id: i + 1, name: `web-${i + 1}`, status: i === 0 ? "running" : "off" }))],
    ["work", [{ id: 900, name: "ci", status: "running" }]],
  ]);
  readonly rrsets = new Map<string, Rrset[]>([["example.com", [{ name: "www", type: "A", ttl: null, records: [{ value: "198.51.100.1", comment: null }] }]]]);

  revoke(token: string): void {
    this.tokens.delete(token);
  }

  /** Whether `text` contains any token. */
  leaks(text: string): boolean {
    return ["hz-personal-token", "hz-work-token"].some((token) => text.includes(token));
  }

  async handle(request: Request): Promise<Response | undefined> {
    const url = new URL(request.url);
    if (url.origin !== "https://api.hetzner.cloud" && url.origin !== "https://api.hetzner.com") return undefined;
    const body = request.body ? await request.text() : "";
    const token = /^Bearer (.+)$/.exec(request.headers.get("Authorization") ?? "")?.[1];
    const project = token ? this.tokens.get(token) ?? null : null;
    this.calls.push({ project, call: `${request.method} ${url.origin === "https://api.hetzner.com" ? "hetzner.com" : ""}${url.pathname}`, headers: request.headers, body });
    if (!project) return json({ error: { code: "unauthorized", message: "unable to authenticate" } }, 401);
    const path = url.pathname;
    if (url.origin === "https://api.hetzner.com") {
      if (path === "/v1/storage_boxes") return json({ storage_boxes: [{ id: 7, name: "backup", username: "u1", server: "u1.your-storagebox.de", status: "active", storage_box_type: { name: "bx11", size: 1e12 }, location: { name: "fsn1" }, stats: { size: 25e9 } }], meta: { pagination: { next_page: null } } });
      return json({ error: { code: "not_found", message: "not found" } }, 404);
    }
    if (request.method === "GET" && path === "/v1/servers") {
      const all = this.servers.get(project) ?? [];
      const page = Number(url.searchParams.get("page") ?? "1");
      const perPage = Number(url.searchParams.get("per_page") ?? "25");
      const slice = all.slice((page - 1) * perPage, page * perPage).map((s) => ({
        ...s, created: "2026-01-01T00:00:00Z", labels: {}, server_type: { name: "cx22", cores: 2, memory: 4, disk: 40 },
        datacenter: { name: "fsn1-dc14", location: { name: "fsn1", city: "Falkenstein" } }, public_net: { ipv4: { ip: `203.0.113.${s.id % 250}` }, ipv6: null }, image: { name: "debian-12" },
      }));
      return json({ servers: slice, meta: { pagination: { next_page: page * perPage < all.length ? page + 1 : null } } });
    }
    const action = /^\/v1\/servers\/(\d+)\/actions\/(\w+)$/.exec(path);
    if (request.method === "POST" && action) {
      const server = this.servers.get(project)?.find((s) => s.id === Number(action[1]));
      if (!server) return json({ error: { code: "not_found", message: "server not found" } }, 404);
      if (action[2] === "reboot" || action[2] === "poweron") server.status = "running";
      return json({ action: { id: 42, command: `${action[2]}_server`, status: "running", progress: 0 } }, 201);
    }
    if (request.method === "GET" && path === "/v1/zones")
      return json({ zones: [...this.rrsets.keys()].map((name, i) => ({ id: i + 1, name, mode: "primary", status: "ok", ttl: 3600, record_count: this.rrsets.get(name)!.length, authoritative_nameservers: { assigned: ["hydrogen.ns.hetzner.com."] }, created: "2026-01-01T00:00:00Z" })), meta: { pagination: { next_page: null } } });
    const rrsets = /^\/v1\/zones\/([^/]+)\/rrsets(?:\/([^/]+)\/([A-Z]+)(?:\/actions\/(\w+))?)?$/.exec(path);
    if (rrsets) {
      const zone = this.rrsets.get(decodeURIComponent(rrsets[1]!));
      if (!zone) return json({ error: { code: "not_found", message: "zone not found" } }, 404);
      const [, , name, type, verb] = rrsets;
      if (!name && request.method === "GET") return json({ rrsets: zone.map((r) => ({ id: `${r.name}/${r.type}`, ...r })), meta: { pagination: { next_page: null } } });
      if (!name && request.method === "POST") {
        const created = JSON.parse(body) as Rrset;
        zone.push({ name: created.name, type: created.type, ttl: created.ttl ?? null, records: created.records.map((r) => ({ value: r.value, comment: r.comment ?? null })) });
        return json({ rrset: created, action: { id: 43 } }, 201);
      }
      const found = zone.find((r) => r.name === decodeURIComponent(name!) && r.type === type);
      if (!found) return json({ error: { code: "not_found", message: "rrset not found" } }, 404);
      if (request.method === "GET" && !verb) return json({ rrset: { id: `${found.name}/${found.type}`, ...found } });
      if (request.method === "DELETE") {
        zone.splice(zone.indexOf(found), 1);
        return json({ action: { id: 44 } }, 201);
      }
      if (verb === "set_records") {
        found.records = (JSON.parse(body) as Rrset).records.map((r) => ({ value: r.value, comment: r.comment ?? null }));
        return json({ action: { id: 45 } }, 201);
      }
      if (verb === "change_ttl") {
        found.ttl = (JSON.parse(body) as { ttl: number }).ttl;
        return json({ action: { id: 46 } }, 201);
      }
    }
    return json({ error: { code: "not_found", message: `no ${request.method} ${path}` } }, 404);
  }
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
}
