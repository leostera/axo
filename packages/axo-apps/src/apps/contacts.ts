import { z } from "zod";
import { tool, type AppDefinition, type AppTool, type ProviderApi } from "../app";

/**
 * Google Contacts as an app: `codemode.apps.contacts.<tool>({ account, ... })` over the People
 * API, with full access (`contacts`): search, read, create, change and delete contacts; and
 * read-only, the people you have emailed (`contacts.other.readonly`) and your company's directory
 * (`directory.readonly`).
 */

export const CONTACTS_SCOPE = "https://www.googleapis.com/auth/contacts";
/** Your contacts, the people you have emailed ("other contacts"), and your company's directory. */
export const CONTACTS_SCOPES = [CONTACTS_SCOPE, "https://www.googleapis.com/auth/contacts.other.readonly", "https://www.googleapis.com/auth/directory.readonly"];
const FIELDS = "names,emailAddresses,phoneNumbers,organizations,biographies,addresses";

const resourceName = z.string().regex(/^people\/[A-Za-z0-9_-]{1,256}$/, "expected a contact's resourceName, such as people/c123");
const fields = z.object({
  name: z.string().min(1).max(512).optional().describe("The full name."),
  emails: z.array(z.string().email()).max(20).optional(),
  phones: z.array(z.string().min(1).max(64)).max(20).optional(),
  organization: z.string().max(512).optional(),
  title: z.string().max(512).optional().describe("Job title, at the organization."),
  notes: z.string().max(8192).optional(),
});

type Person = {
  resourceName: string;
  etag?: string;
  names?: Array<{ displayName?: string }>;
  emailAddresses?: Array<{ value?: string }>;
  phoneNumbers?: Array<{ value?: string }>;
  organizations?: Array<{ name?: string; title?: string }>;
  biographies?: Array<{ value?: string }>;
  addresses?: Array<{ formattedValue?: string }>;
};

const tools: AppTool[] = [
  tool({
    name: "search_contacts",
    description: "Finds contacts by name, email, phone or organization: { contacts: [{ resourceName, name, emails, phones, organization, title }] }.",
    input: z.object({ query: z.string().min(1).max(512), maxResults: z.number().int().min(1).max(30).optional().describe("Default 10.") }).strict(),
    idempotent: true,
    async run(api, input) {
      const search = (query: string) => api.request("GET", "/v1/people:searchContacts", { query: { query, readMask: FIELDS, pageSize: String(input.maxResults ?? 10) } });
      // Google asks for an empty search first, which warms its cache for the real one.
      await search("");
      const answer = (await search(input.query)) as { results?: Array<{ person: Person }> };
      return { contacts: (answer.results ?? []).map((r) => contact(r.person)) };
    },
  }),
  tool({
    name: "search_other_contacts",
    description: "Finds people you have emailed but not saved as contacts, by name or email: { contacts: [{ resourceName, name, emails, phones }] }.",
    input: z.object({ query: z.string().min(1).max(512), maxResults: z.number().int().min(1).max(30).optional().describe("Default 10.") }).strict(),
    idempotent: true,
    async run(api, input) {
      const search = (query: string) => api.request("GET", "/v1/otherContacts:search", { query: { query, readMask: "names,emailAddresses,phoneNumbers", pageSize: String(input.maxResults ?? 10) } });
      await search("");
      const answer = (await search(input.query)) as { results?: Array<{ person: Person }> };
      return { contacts: (answer.results ?? []).map((r) => contact(r.person)) };
    },
  }),
  tool({
    name: "search_directory",
    description: "Finds people in the account's company directory (Google Workspace), by name or email: { people: [{ resourceName, name, emails, phones, organization, title }], nextPageToken }.",
    input: z.object({ query: z.string().min(1).max(512), maxResults: z.number().int().min(1).max(500).optional().describe("Default 20."), pageToken: z.string().max(1024).optional() }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("GET", "/v1/people:searchDirectoryPeople", {
        query: { query: input.query, readMask: FIELDS, sources: ["DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE", "DIRECTORY_SOURCE_TYPE_DOMAIN_CONTACT"], pageSize: String(input.maxResults ?? 20), pageToken: input.pageToken },
      })) as { people?: Person[]; nextPageToken?: string };
      return { people: (answer.people ?? []).map((p) => contact(p)), nextPageToken: answer.nextPageToken ?? null };
    },
  }),
  tool({
    name: "list_contacts",
    description: "Lists contacts by name: { contacts: [...], nextPageToken }.",
    input: z.object({ maxResults: z.number().int().min(1).max(1000).optional().describe("Default 100."), pageToken: z.string().max(1024).optional() }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("GET", "/v1/people/me/connections", {
        query: { personFields: FIELDS, pageSize: String(input.maxResults ?? 100), pageToken: input.pageToken, sortOrder: "FIRST_NAME_ASCENDING" },
      })) as { connections?: Person[]; nextPageToken?: string };
      return { contacts: (answer.connections ?? []).map((p) => contact(p)), nextPageToken: answer.nextPageToken ?? null };
    },
  }),
  tool({
    name: "get_contact",
    description: "Reads one contact, with its notes and addresses.",
    input: z.object({ resourceName }).strict(),
    idempotent: true,
    run: async (api, input) => contact(await person(api, input.resourceName), true),
  }),
  tool({
    name: "create_contact",
    description: "Creates a contact and returns it.",
    input: fields.extend({ name: z.string().min(1).max(512) }).strict(),
    idempotent: false,
    async run(api, input) {
      return contact((await api.request("POST", "/v1/people:createContact", { query: { personFields: FIELDS }, body: body(input) })) as Person, true);
    },
  }),
  tool({
    name: "update_contact",
    description: "Replaces the fields given on a contact (others are kept) and returns it. emails and phones replace the whole list.",
    input: fields.extend({ resourceName }).strict(),
    idempotent: true,
    async run(api, input) {
      const current = await person(api, input.resourceName);
      const changed = body(input);
      const mask = Object.keys(changed).join(",");
      if (!mask) return contact(current, true);
      return contact((await api.request("PATCH", `/v1/${input.resourceName}:updateContact`, {
        query: { updatePersonFields: mask, personFields: FIELDS },
        body: { ...changed, etag: current.etag },
      })) as Person, true);
    },
  }),
  tool({
    name: "delete_contact",
    description: "Deletes a contact and returns { deleted: true }.",
    input: z.object({ resourceName }).strict(),
    idempotent: true,
    async run(api, input) {
      await api.request("DELETE", `/v1/${input.resourceName}:deleteContact`);
      return { deleted: true };
    },
  }),
];

export const contacts: AppDefinition = {
  name: "contacts",
  title: "Google Contacts",
  description: "Look up and manage your contacts, and find people at your company.",
  permissions: [
    "See, create, change and delete your contacts and contact groups",
    "See people you have emailed but not saved",
    "Look people up in your company's directory",
  ],
  signIn: "oauth",
  provider: "google",
  providerTitle: "Google",
  category: "communication",
  scopes: ["openid", "email", ...CONTACTS_SCOPES],
  requiredScopes: CONTACTS_SCOPES,
  apiOrigin: "https://people.googleapis.com",
  hosts: ["people.googleapis.com"],
  reference: "https://developers.google.com/people/api/rest",
  tools,
};

async function person(api: ProviderApi, name: string): Promise<Person> {
  return (await api.request("GET", `/v1/${name}`, { query: { personFields: FIELDS } })) as Person;
}

/** The People API's fields for what `input` sets; a field left out is not touched. */
function body(input: z.infer<typeof fields>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (input.name !== undefined) out.names = [{ unstructuredName: input.name }];
  if (input.emails !== undefined) out.emailAddresses = input.emails.map((value) => ({ value }));
  if (input.phones !== undefined) out.phoneNumbers = input.phones.map((value) => ({ value }));
  if (input.organization !== undefined || input.title !== undefined) out.organizations = [{ name: input.organization, title: input.title }];
  if (input.notes !== undefined) out.biographies = [{ value: input.notes, contentType: "TEXT_PLAIN" }];
  return out;
}

function contact(p: Person, full = false) {
  return {
    resourceName: p.resourceName,
    name: p.names?.[0]?.displayName ?? null,
    emails: (p.emailAddresses ?? []).map((e) => e.value).filter(Boolean),
    phones: (p.phoneNumbers ?? []).map((e) => e.value).filter(Boolean),
    organization: p.organizations?.[0]?.name ?? null,
    title: p.organizations?.[0]?.title ?? null,
    ...(full ? { notes: p.biographies?.[0]?.value ?? null, addresses: (p.addresses ?? []).map((a) => a.formattedValue).filter(Boolean) } : {}),
  };
}
