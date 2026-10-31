import { z } from "zod";
import { tool, type AppDefinition, type AppTool, type ProviderRequest } from "./app";

/**
 * Google Cloud as an app: `codemode.apps.cloud.<tool>({ account, ... })`, with `cloud-platform`:
 * everything the Google account can do in Google Cloud, as `gcloud` signed in as it would. The
 * named tools cover projects, logs, BigQuery, Cloud Storage, Cloud Run and Compute Engine;
 * `request` reaches any other Cloud API on `*.googleapis.com`.
 *
 * A call about a project sends `x-goog-user-project`, so its quota and billing are that
 * project's, and its API must be enabled there, rather than in Axo's own project.
 */

export const CLOUD_SCOPE = "https://www.googleapis.com/auth/cloud-platform";
const MAX_OBJECT_BYTES = 600_000;

const project = z.string().regex(/^[a-z][a-z0-9-]{4,61}[a-z0-9]$|^\d{1,20}$/, "expected a project ID").describe("The project ID, such as my-project.");
const bucket = z.string().regex(/^[a-z0-9][a-z0-9._-]{1,221}[a-z0-9]$/, "expected a bucket name");
const pageToken = z.string().max(2048).optional();

/** As `project`'s: its quota, billing and enabled APIs. */
function as(project: string, options: ProviderRequest = {}): ProviderRequest {
  return { ...options, headers: { ...options.headers, "x-goog-user-project": project } };
}

const tools: AppTool[] = [
  tool({
    name: "list_projects",
    description: "Lists the projects the account can see: { projects: [{ projectId, displayName, number, state, parent }], nextPageToken }. `query` takes Resource Manager's search syntax, e.g. \"displayName:axo*\".",
    input: z.object({ query: z.string().max(1024).optional(), pageToken }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("GET", "https://cloudresourcemanager.googleapis.com/v3/projects:search", {
        query: { query: input.query, pageToken: input.pageToken, pageSize: "200" },
      })) as { projects?: Array<{ projectId: string; displayName?: string; name?: string; state?: string; parent?: string }>; nextPageToken?: string };
      return {
        projects: (answer.projects ?? []).map((p) => ({ projectId: p.projectId, displayName: p.displayName ?? null, number: p.name?.replace("projects/", "") ?? null, state: p.state ?? null, parent: p.parent ?? null })),
        nextPageToken: answer.nextPageToken ?? null,
      };
    },
  }),
  tool({
    name: "list_services",
    description: "Lists the APIs enabled in a project: { services: [\"run.googleapis.com\", ...] }.",
    input: z.object({ project }).strict(),
    idempotent: true,
    async run(api, input) {
      const services: string[] = [];
      let next: string | undefined;
      do {
        const page = (await api.request("GET", `https://serviceusage.googleapis.com/v1/projects/${input.project}/services`, as(input.project, {
          query: { filter: "state:ENABLED", pageSize: "200", pageToken: next },
        }))) as { services?: Array<{ config?: { name?: string } }>; nextPageToken?: string };
        for (const s of page.services ?? []) if (s.config?.name) services.push(s.config.name);
        next = page.nextPageToken;
      } while (next && services.length < 2000);
      return { services };
    },
  }),
  tool({
    name: "enable_service",
    description: "Enables an API in a project, such as \"run.googleapis.com\". Returns the operation: { name, done }.",
    input: z.object({ project, service: z.string().regex(/^[a-z0-9.-]{3,128}$/) }).strict(),
    idempotent: true,
    async run(api, input) {
      const op = (await api.request("POST", `https://serviceusage.googleapis.com/v1/projects/${input.project}/services/${input.service}:enable`, as(input.project, { body: {} }))) as { name?: string; done?: boolean };
      return { name: op.name ?? null, done: op.done ?? false };
    },
  }),
  tool({
    name: "read_logs",
    description:
      "Reads a project's Cloud Logging entries, newest first: { entries: [{ timestamp, severity, logName, resource, text, json, labels }], nextPageToken }. " +
      "`filter` takes the Logging query language, e.g. 'resource.type=\"cloud_run_revision\" severity>=ERROR timestamp>=\"2025-01-01T00:00:00Z\"'.",
    input: z.object({ project, filter: z.string().max(20_000).optional(), maxResults: z.number().int().min(1).max(1000).optional().describe("Default 50."), pageToken }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("POST", "https://logging.googleapis.com/v2/entries:list", as(input.project, {
        body: { resourceNames: [`projects/${input.project}`], filter: input.filter, orderBy: "timestamp desc", pageSize: input.maxResults ?? 50, pageToken: input.pageToken },
      }))) as {
        entries?: Array<{ timestamp?: string; severity?: string; logName?: string; resource?: unknown; textPayload?: string; jsonPayload?: unknown; protoPayload?: unknown; labels?: unknown }>;
        nextPageToken?: string;
      };
      return {
        entries: (answer.entries ?? []).map((e) => ({
          timestamp: e.timestamp ?? null, severity: e.severity ?? null, logName: e.logName ?? null, resource: e.resource ?? null,
          text: e.textPayload ?? null, json: e.jsonPayload ?? e.protoPayload ?? null, labels: e.labels ?? null,
        })),
        nextPageToken: answer.nextPageToken ?? null,
      };
    },
  }),
  tool({
    name: "query_bigquery",
    description:
      "Runs a GoogleSQL query in BigQuery, billed to `project`, waiting up to 25 seconds: { rows: [{ column: value }], totalRows, jobComplete, jobId }. " +
      "A query still running returns jobComplete false and its jobId; poll it with request. A query that changes data runs as written.",
    input: z.object({ project, sql: z.string().min(1).max(1_000_000), maxResults: z.number().int().min(1).max(10_000).optional().describe("Default 1000."), location: z.string().max(64).optional() }).strict(),
    idempotent: false,
    async run(api, input) {
      const answer = (await api.request("POST", `https://bigquery.googleapis.com/bigquery/v2/projects/${input.project}/queries`, as(input.project, {
        body: { query: input.sql, useLegacySql: false, maxResults: input.maxResults ?? 1000, timeoutMs: 25_000, location: input.location },
      }))) as BigQueryAnswer;
      return {
        rows: rowsOf(answer),
        totalRows: answer.totalRows ? Number(answer.totalRows) : null,
        jobComplete: answer.jobComplete ?? false,
        jobId: answer.jobReference?.jobId ?? null,
      };
    },
  }),
  tool({
    name: "list_buckets",
    description: "Lists a project's Cloud Storage buckets: { buckets: [{ name, location, storageClass, created }] }.",
    input: z.object({ project, pageToken }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("GET", "https://storage.googleapis.com/storage/v1/b", as(input.project, { query: { project: input.project, pageToken: input.pageToken } }))) as {
        items?: Array<{ name: string; location?: string; storageClass?: string; timeCreated?: string }>;
        nextPageToken?: string;
      };
      return { buckets: (answer.items ?? []).map((b) => ({ name: b.name, location: b.location ?? null, storageClass: b.storageClass ?? null, created: b.timeCreated ?? null })), nextPageToken: answer.nextPageToken ?? null };
    },
  }),
  tool({
    name: "list_objects",
    description: "Lists objects in a bucket under `prefix`, one level deep if `delimiter` is \"/\": { objects: [{ name, size, contentType, updated }], prefixes, nextPageToken }.",
    input: z.object({ bucket, prefix: z.string().max(1024).optional(), delimiter: z.string().max(8).optional(), maxResults: z.number().int().min(1).max(1000).optional(), pageToken }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("GET", `https://storage.googleapis.com/storage/v1/b/${input.bucket}/o`, {
        query: { prefix: input.prefix, delimiter: input.delimiter, maxResults: String(input.maxResults ?? 200), pageToken: input.pageToken },
      })) as { items?: Array<{ name: string; size?: string; contentType?: string; updated?: string }>; prefixes?: string[]; nextPageToken?: string };
      return {
        objects: (answer.items ?? []).map((o) => ({ name: o.name, size: o.size ? Number(o.size) : null, contentType: o.contentType ?? null, updated: o.updated ?? null })),
        prefixes: answer.prefixes ?? [],
        nextPageToken: answer.nextPageToken ?? null,
      };
    },
  }),
  tool({
    name: "read_object",
    description: `Reads an object: { name, contentType, text } for text, { base64 } otherwise; at most ${MAX_OBJECT_BYTES} bytes, with truncated when cut.`,
    input: z.object({ bucket, object: z.string().min(1).max(1024) }).strict(),
    idempotent: true,
    async run(api, input) {
      const path = `https://storage.googleapis.com/storage/v1/b/${input.bucket}/o/${encodeURIComponent(input.object)}`;
      const answer = await api.requestRaw("GET", path, { query: { alt: "media" }, accept: "*/*", headers: { Range: `bytes=0-${MAX_OBJECT_BYTES}` } });
      const bytes = new Uint8Array(answer.body);
      const truncated = bytes.length > MAX_OBJECT_BYTES;
      const kept = bytes.subarray(0, MAX_OBJECT_BYTES);
      const text = /^text\/|json|xml|csv|javascript|yaml/i.test(answer.contentType);
      return {
        name: input.object,
        contentType: answer.contentType || null,
        ...(text ? { text: new TextDecoder().decode(kept) } : { base64: base64(kept) }),
        truncated,
      };
    },
  }),
  tool({
    name: "list_run_services",
    description: "Lists a project's Cloud Run services, in `region` or every region: { services: [{ name, region, url, updated, latestRevision }] }.",
    input: z.object({ project, region: z.string().regex(/^[a-z0-9-]{1,64}$/).optional().describe("Default every region.") }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("GET", `https://run.googleapis.com/v2/projects/${input.project}/locations/${input.region ?? "-"}/services`, as(input.project))) as {
        services?: Array<{ name: string; uri?: string; updateTime?: string; latestReadyRevision?: string }>;
      };
      return {
        services: (answer.services ?? []).map((s) => ({
          name: s.name.split("/").pop() ?? s.name, region: s.name.split("/")[3] ?? null, url: s.uri ?? null, updated: s.updateTime ?? null,
          latestRevision: s.latestReadyRevision?.split("/").pop() ?? null,
        })),
      };
    },
  }),
  tool({
    name: "list_instances",
    description: "Lists a project's Compute Engine VMs in every zone: { instances: [{ name, zone, status, machineType, internalIp, externalIp }] }.",
    input: z.object({ project }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("GET", `https://compute.googleapis.com/compute/v1/projects/${input.project}/aggregated/instances`, as(input.project, { query: { maxResults: "500" } }))) as {
        items?: Record<string, { instances?: Array<{ name: string; status?: string; machineType?: string; networkInterfaces?: Array<{ networkIP?: string; accessConfigs?: Array<{ natIP?: string }> }> }> }>;
      };
      return {
        instances: Object.entries(answer.items ?? {}).flatMap(([zone, scoped]) => (scoped.instances ?? []).map((vm) => ({
          name: vm.name,
          zone: zone.replace("zones/", ""),
          status: vm.status ?? null,
          machineType: vm.machineType?.split("/").pop() ?? null,
          internalIp: vm.networkInterfaces?.[0]?.networkIP ?? null,
          externalIp: vm.networkInterfaces?.[0]?.accessConfigs?.[0]?.natIP ?? null,
        }))),
      };
    },
  }),
];

export const cloud: AppDefinition = {
  name: "cloud",
  title: "Google Cloud",
  description: "Work with your Google Cloud projects, as you can with gcloud.",
  permissions: [
    "Everything your Google account can do in Google Cloud",
    "See and manage projects, and enable APIs in them",
    "Read logs, run BigQuery queries, and read and write Cloud Storage",
    "See and change Cloud Run, Compute Engine and every other Cloud service",
  ],
  signIn: "oauth",
  provider: "google",
  providerTitle: "Google",
  category: "developer",
  scopes: ["openid", "email", CLOUD_SCOPE],
  requiredScopes: [CLOUD_SCOPE],
  apiOrigin: "https://cloudresourcemanager.googleapis.com",
  hosts: ["*.googleapis.com"],
  reference: "https://cloud.google.com/apis/docs/overview; pass headers { \"x-goog-user-project\": project } to bill a project",
  tools,
};

type BigQueryAnswer = {
  schema?: { fields?: Field[] };
  rows?: Array<{ f?: Array<{ v?: unknown }> }>;
  totalRows?: string;
  jobComplete?: boolean;
  jobReference?: { jobId?: string };
};
type Field = { name: string; type?: string; mode?: string; fields?: Field[] };

/** BigQuery's rows, `{ f: [{ v }] }`, as objects keyed by column, nested records too. */
export function rowsOf(answer: BigQueryAnswer): Array<Record<string, unknown>> {
  const fields = answer.schema?.fields ?? [];
  return (answer.rows ?? []).map((row) => record(fields, row));
}

function record(fields: Field[], row: { f?: Array<{ v?: unknown }> }): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  fields.forEach((field, i) => {
    out[field.name] = value(field, row.f?.[i]?.v);
  });
  return out;
}

function value(field: Field, v: unknown): unknown {
  if (v === null || v === undefined) return null;
  if (field.mode === "REPEATED" && Array.isArray(v)) return v.map((item) => value({ ...field, mode: "NULLABLE" }, (item as { v?: unknown }).v));
  if ((field.type === "RECORD" || field.type === "STRUCT") && typeof v === "object") return record(field.fields ?? [], v as { f?: Array<{ v?: unknown }> });
  if (["INTEGER", "INT64", "FLOAT", "FLOAT64"].includes(field.type ?? "") && typeof v === "string") return Number(v);
  if (["BOOLEAN", "BOOL"].includes(field.type ?? "") && typeof v === "string") return v === "true";
  return v;
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}
