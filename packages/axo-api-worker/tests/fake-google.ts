import { createHash, randomBytes } from "node:crypto";
import { Response as MiniflareResponse } from "miniflare";

/**
 * Google as the Gmail app sees it: the OAuth consent page and token endpoint (PKCE, a client
 * secret, refresh tokens that do not rotate, an ID token with the account's email), revocation,
 * and enough of the Gmail REST API to read, search, label and send mail.
 */
export class FakeGoogle {
  readonly clientId = "google-client.apps.googleusercontent.com";
  readonly clientSecret = "GOCSPX-test-secret";
  /** Who signs in on the consent page next. */
  email = "ada@example.com";
  /** What the person allows on the consent page; by default everything asked for. */
  grantScopes: string[] | null = null;
  /** Seconds an access token lives. */
  tokenLifetime = 3600;
  /** The next send answers with this status instead of sending. */
  failNextSend: number | null = null;
  refuseRefresh = false;
  readonly tokenRequests: URLSearchParams[] = [];
  readonly revoked: string[] = [];
  readonly sent: Array<{ raw: string; threadId: string | null }> = [];
  readonly apiCalls: string[] = [];
  readonly messages = new Map<string, { threadId: string; labelIds: string[]; headers: Record<string, string>; text: string; snippet: string }>([
    ["m1", { threadId: "t1", labelIds: ["INBOX", "UNREAD"], headers: { From: "Grace <grace@example.com>", To: "ada@example.com", Subject: "Compilers", Date: "Fri, 30 Oct 2026 10:00:00 +0000", "Message-ID": "<m1@example.com>" }, text: "Shall we meet?", snippet: "Shall we meet? It&#39;s &lt;soon&gt; &#x2014; G" }],
    ["m2", { threadId: "t2", labelIds: ["INBOX"], headers: { From: "news@example.com", To: "ada@example.com", Subject: "Weekly", Date: "Thu, 29 Oct 2026 10:00:00 +0000", "Message-ID": "<m2@example.com>" }, text: "", snippet: "Hello" }],
  ]);
  private readonly codes = new Map<string, { challenge: string; scopes: string[]; email: string; used: boolean }>();
  /** Access token → the account it acts as. */
  private readonly access = new Map<string, string>();
  private readonly refresh = new Map<string, { scopes: string[]; email: string }>();

  /** The person approves on Google's consent page: where Google sends the browser back. */
  approve(authorizeUrl: string): URL {
    const url = new URL(authorizeUrl);
    assert(url.origin === "https://accounts.google.com" && url.pathname === "/o/oauth2/v2/auth", `unexpected authorize URL ${authorizeUrl}`);
    assert(url.searchParams.get("client_id") === this.clientId, "Axo's Google client");
    assert(url.searchParams.get("code_challenge_method") === "S256", "PKCE is required");
    assert(url.searchParams.get("access_type") === "offline", "a refresh token is asked for");
    const asked = (url.searchParams.get("scope") ?? "").split(" ");
    const code = randomBytes(12).toString("hex");
    assert(url.searchParams.get("prompt")?.includes("select_account"), "the person may pick another account");
    this.codes.set(code, { challenge: url.searchParams.get("code_challenge")!, scopes: this.grantScopes ?? asked, email: this.email, used: false });
    const back = new URL(url.searchParams.get("redirect_uri")!);
    back.searchParams.set("code", code);
    back.searchParams.set("state", url.searchParams.get("state")!);
    return back;
  }

  /** Every access token stops working, as when Google revokes them; refresh tokens still work. */
  expireAccessTokens(): void {
    this.access.clear();
  }

  /** Whether `text` contains any token or the client secret. */
  leaks(text: string): boolean {
    return [...this.access.keys(), ...this.refresh.keys(), this.clientSecret].some((secret) => text.includes(secret));
  }

  async handle(request: Request): Promise<Response | undefined> {
    const url = new URL(request.url);
    if (url.origin === "https://oauth2.googleapis.com" && url.pathname === "/token") return this.token(request);
    if (url.origin === "https://oauth2.googleapis.com" && url.pathname === "/revoke") {
      this.revoked.push(new URLSearchParams(await request.text()).get("token") ?? "");
      return json({});
    }
    if (url.origin === "https://gmail.googleapis.com") return this.gmail(request, url);
    if (isWorkspace(url)) return this.workspace(request, url);
    return undefined;
  }

  /** Requests to Calendar, Drive, Docs, Sheets and People, as `METHOD path?query` with their bodies. */
  /** The bytes of every message's one attachment, notes.pdf (attachment ID att1): larger than a script result may be. */
  attachment = new Uint8Array(1_500_000).map((_, i) => (i * 31 + 7) & 0xff);
  readonly workspaceCalls: Array<{ as: string; call: string; query: URLSearchParams; body: string; headers: Headers }> = [];
  readonly files = new Map<string, { name: string; mimeType: string; content: string; parents: string[]; trashed: boolean }>([
    ["doc1", { name: "Plan", mimeType: "application/vnd.google-apps.document", content: "The plan.", parents: ["root"], trashed: false }],
    ["pdf1", { name: "scan.pdf", mimeType: "application/pdf", content: "%PDF-1.4", parents: ["root"], trashed: false }],
  ]);

  private async workspace(request: Request, url: URL): Promise<Response> {
    const as = this.access.get(request.headers.get("authorization")?.replace("Bearer ", "") ?? "");
    if (!as) return json({ error: { code: 401, message: "Request had invalid authentication credentials." } }, 401);
    const body = await request.text();
    const call = `${request.method} ${url.host.split(".")[0]}${url.pathname}`;
    this.workspaceCalls.push({ as, call, query: url.searchParams, body, headers: request.headers });
    const read = () => JSON.parse(body || "{}");
    const at = (pattern: RegExp) => pattern.exec(`${request.method} ${url.pathname}`);
    let m: RegExpExecArray | null;
    // Calendar
    if (at(/^GET \/calendar\/v3\/users\/me\/calendarList$/)) return json({ items: [{ id: as, summary: as, primary: true, accessRole: "owner", timeZone: "Europe/London" }, { id: "team@group.calendar.google.com", summary: "Team", summaryOverride: "Team (mine)", accessRole: "reader" }] });
    if (at(/^GET \/calendar\/v3\/calendars\/[^/]+\/events$/)) return json({ items: [{ id: "e1", summary: "Standup", start: { dateTime: "2026-11-02T09:00:00Z" }, end: { dateTime: "2026-11-02T09:15:00Z" }, attendees: [{ email: "grace@example.com", responseStatus: "accepted" }], status: "confirmed", hangoutLink: "https://meet.google.com/x" }] });
    if ((m = at(/^POST \/calendar\/v3\/calendars\/([^/]+)\/events$/))) return json({ id: "e2", ...read(), htmlLink: "https://calendar.google.com/e2", organizer: { email: as } });
    if ((m = at(/^PATCH \/calendar\/v3\/calendars\/[^/]+\/events\/([^/]+)$/))) return json({ id: decodeURIComponent(m[1]!), summary: "Standup", ...read() });
    if (at(/^DELETE \/calendar\/v3\/calendars\/[^/]+\/events\/[^/]+$/)) return new MiniflareResponse(null, { status: 204 }) as unknown as Response;
    if (at(/^POST \/calendar\/v3\/freeBusy$/)) return json({ calendars: Object.fromEntries((read().items as Array<{ id: string }>).map(({ id }) => [id, { busy: [{ start: "2026-11-02T09:00:00Z", end: "2026-11-02T10:00:00Z" }] }])) });
    // Drive
    const fileJson = (id: string) => {
      const f = this.files.get(id)!;
      return { id, name: f.name, mimeType: f.mimeType, parents: f.parents, trashed: f.trashed, size: String(f.content.length), modifiedTime: "2026-10-30T10:00:00Z", webViewLink: `https://drive.google.com/${id}`, owners: [{ emailAddress: as }] };
    };
    if (at(/^GET \/drive\/v3\/files$/)) return json({ files: [...this.files.keys()].filter((id) => !this.files.get(id)!.trashed).map(fileJson) });
    if ((m = at(/^GET \/drive\/v3\/files\/([^/]+)\/export$/))) return new MiniflareResponse(this.files.get(m[1]!)!.content, { status: 200 }) as unknown as Response;
    if ((m = at(/^GET \/drive\/v3\/files\/([^/]+)$/))) {
      const f = this.files.get(m[1]!);
      if (!f) return json({ error: { code: 404, message: "File not found." } }, 404);
      return url.searchParams.get("alt") === "media" ? new MiniflareResponse(f.content, { status: 200 }) as unknown as Response : json(fileJson(m[1]!));
    }
    if (request.method === "POST" && url.pathname === "/upload/drive/v3/files") {
      const boundary = /boundary=(.+)$/.exec(request.headers.get("content-type") ?? "")![1]!;
      const [, metaPart, contentPart] = body.split(`--${boundary}`);
      const meta = JSON.parse(metaPart!.split("\r\n\r\n")[1]!.trim());
      const id = `up${this.files.size}`;
      this.files.set(id, { name: meta.name, mimeType: meta.mimeType ?? "text/plain", content: contentPart!.split("\r\n\r\n").slice(1).join("\r\n\r\n").replace(/\r\n$/, ""), parents: meta.parents ?? ["root"], trashed: false });
      return json(fileJson(id));
    }
    if ((m = at(/^PATCH \/drive\/v3\/files\/([^/]+)$/))) {
      const f = this.files.get(m[1]!)!;
      Object.assign(f, read());
      const add = url.searchParams.get("addParents");
      if (add) f.parents = [...f.parents.filter((p) => !(url.searchParams.get("removeParents") ?? "").split(",").includes(p)), add];
      return json(fileJson(m[1]!));
    }
    if ((m = at(/^DELETE \/drive\/v3\/files\/([^/]+)$/))) {
      this.files.delete(m[1]!);
      return new MiniflareResponse(null, { status: 204 }) as unknown as Response;
    }
    if (at(/^POST \/drive\/v3\/files\/[^/]+\/permissions$/)) return json({ id: "perm1", role: read().role });
    // Docs
    if (at(/^GET \/v1\/documents\/doc1$/)) return json({ documentId: "doc1", title: "Plan", body: { content: [
      { paragraph: { elements: [{ textRun: { content: "Goals\n" } }] } },
      { table: { tableRows: [{ tableCells: [{ content: [{ paragraph: { elements: [{ textRun: { content: "a\n" } }] } }] }, { content: [{ paragraph: { elements: [{ textRun: { content: "b\n" } }] } }] }] }] } },
    ] } });
    if (url.host === "docs.googleapis.com" && at(/^POST \/v1\/documents$/)) return json({ documentId: "doc2", title: read().title });
    if (at(/^POST \/v1\/documents\/[^/]+:batchUpdate$/)) return json({ replies: read().requests.map((r: Record<string, unknown>) => (r.replaceAllText ? { replaceAllText: { occurrencesChanged: 3 } } : {})) });
    // Sheets
    if (at(/^GET \/v4\/spreadsheets\/s1\/values\/.+$/)) return json({ range: "Sheet1!A1:B2", values: [["name", "n"], ["ada", "1"]] });
    if (at(/^PUT \/v4\/spreadsheets\/s1\/values\/.+$/)) return json({ updatedRange: read().range, updatedCells: read().values.flat().length });
    if (at(/^POST \/v4\/spreadsheets\/s1\/values\/.+:append$/)) return json({ updates: { updatedRange: "Sheet1!A3:B3", updatedRows: read().values.length } });
    if (url.host === "sheets.googleapis.com" && at(/^POST \/v4\/spreadsheets$/)) return json({ spreadsheetId: "s2", spreadsheetUrl: "https://docs.google.com/spreadsheets/d/s2", properties: read().properties, sheets: read().sheets ?? [{ properties: { title: "Sheet1" } }] });
    // People
    if (at(/^GET \/v1\/people:searchContacts$/)) return json(url.searchParams.get("query") ? { results: [{ person: { resourceName: "people/c1", names: [{ displayName: "Grace Hopper" }], emailAddresses: [{ value: "grace@example.com" }], organizations: [{ name: "Navy", title: "Rear Admiral" }] } }] } : {});
    if (at(/^GET \/v1\/people\/c1$/)) return json({ resourceName: "people/c1", etag: "etag-1", names: [{ displayName: "Grace Hopper" }], emailAddresses: [{ value: "grace@example.com" }] });
    if (at(/^PATCH \/v1\/people\/c1:updateContact$/)) return json({ resourceName: "people/c1", names: [{ displayName: "Grace Hopper" }], ...read() });
    if (at(/^POST \/v1\/people:createContact$/)) return json({ resourceName: "people/c2", names: [{ displayName: read().names[0].unstructuredName }], emailAddresses: read().emailAddresses });
    // Slides
    if (at(/^GET \/v1\/presentations\/p1$/)) return json({ presentationId: "p1", title: "Deck", slides: [
      { objectId: "s1", pageElements: [{ objectId: "t", shape: { placeholder: { type: "TITLE" }, text: { textElements: [{ textRun: { content: "Hello" } }] } } }],
        slideProperties: { notesPage: { objectId: "n1", pageElements: [{ objectId: "nb", shape: { placeholder: { type: "BODY" }, text: { textElements: [{ textRun: { content: "Say hi" } }] } } }] } } },
    ] });
    if (url.host === "slides.googleapis.com" && at(/^POST \/v1\/presentations$/)) return json({ presentationId: "p2", title: read().title });
    if (at(/^POST \/v1\/presentations\/[^/]+:batchUpdate$/)) return json({ replies: read().requests.map((r: Record<string, unknown>) => (r.replaceAllText ? { replaceAllText: { occurrencesChanged: 2 } } : {})) });
    // Tasks
    if (at(/^GET \/tasks\/v1\/users\/@me\/lists$/)) return json({ items: [{ id: "MDEy", title: "My Tasks", updated: "2026-10-30T10:00:00Z" }] });
    if (at(/^GET \/tasks\/v1\/lists\/[^/]+\/tasks$/)) return json({ items: [{ id: "k1", title: "Write RFD", status: "needsAction", due: "2026-11-03T00:00:00.000Z" }] });
    if (at(/^POST \/tasks\/v1\/lists\/[^/]+\/tasks$/)) return json({ id: "k2", status: "needsAction", ...read() });
    if ((m = at(/^PATCH \/tasks\/v1\/lists\/[^/]+\/tasks\/([^/]+)$/))) return json({ id: m[1], title: "Write RFD", ...read() });
    // Meet
    if (at(/^POST \/v2\/spaces$/)) return json({ name: "spaces/abc", meetingUri: "https://meet.google.com/abc-mnop-xyz", meetingCode: "abc-mnop-xyz", config: read().config ?? { accessType: "TRUSTED" } });
    if (at(/^GET \/v2\/conferenceRecords$/)) return json({ conferenceRecords: [{ name: "conferenceRecords/r1", startTime: "2026-11-02T09:00:00Z", endTime: "2026-11-02T09:30:00Z", space: "spaces/abc" }] });
    if (at(/^GET \/v2\/conferenceRecords\/r1\/participants$/)) return json({ participants: [{ name: "conferenceRecords/r1/participants/p1", signedinUser: { user: "users/1", displayName: "Grace" } }] });
    if (at(/^GET \/v2\/conferenceRecords\/r1\/transcripts$/)) return json({ transcripts: [{ name: "conferenceRecords/r1/transcripts/x1", state: "FILE_GENERATED", docsDestination: { document: "doc9" } }] });
    if (at(/^GET \/v2\/conferenceRecords\/r1\/transcripts\/x1\/entries$/)) return json({ transcriptEntries: [{ participant: "conferenceRecords/r1/participants/p1", text: "Shall we ship?" }] });
    // Google Cloud
    if (url.host === "cloudresourcemanager.googleapis.com" && at(/^GET \/v3\/projects:search$/)) return json({ projects: [{ projectId: "axo-dev", displayName: "Axo", name: "projects/42", state: "ACTIVE" }] });
    if (url.host === "bigquery.googleapis.com" && at(/^POST \/bigquery\/v2\/projects\/[^/]+\/queries$/)) return json({
      jobComplete: true, totalRows: "1", jobReference: { jobId: "j1" },
      schema: { fields: [{ name: "n", type: "INTEGER" }, { name: "who", type: "RECORD", fields: [{ name: "name", type: "STRING" }] }, { name: "tags", type: "STRING", mode: "REPEATED" }] },
      rows: [{ f: [{ v: "7" }, { v: { f: [{ v: "ada" }] } }, { v: [{ v: "a" }, { v: "b" }] }] }],
    });
    return json({ error: { code: 404, message: `no fake for ${call}` } }, 404);
  }

  private async token(request: Request): Promise<Response> {
    const form = new URLSearchParams(await request.text());
    this.tokenRequests.push(form);
    if (form.get("client_id") !== this.clientId || form.get("client_secret") !== this.clientSecret) return json({ error: "invalid_client" }, 401);
    let scopes: string[];
    let email: string;
    let refreshToken: string | undefined;
    if (form.get("grant_type") === "authorization_code") {
      const code = this.codes.get(form.get("code") ?? "");
      if (!code || code.used || form.get("redirect_uri") !== "https://axo.leostera.dev/api/v1/connections/oauth/callback"
        || createHash("sha256").update(form.get("code_verifier") ?? "").digest("base64url") !== code.challenge) return json({ error: "invalid_grant" }, 400);
      code.used = true;
      scopes = code.scopes;
      email = code.email;
      refreshToken = randomBytes(16).toString("hex");
      this.refresh.set(refreshToken, { scopes, email });
    } else if (form.get("grant_type") === "refresh_token") {
      const known = this.refresh.get(form.get("refresh_token") ?? "");
      if (!known || this.refuseRefresh) return json({ error: "invalid_grant" }, 400);
      ({ scopes, email } = known);
    } else return json({ error: "unsupported_grant_type" }, 400);
    const accessToken = `ya29.${randomBytes(16).toString("hex")}`;
    this.access.set(accessToken, email);
    // As Google's: issued now, for an hour.
    const iat = Math.floor(Date.now() / 1000);
    const claims = { iss: "https://accounts.google.com", aud: this.clientId, sub: email, email, email_verified: true, iat, exp: iat + 3600 };
    const header = Buffer.from(JSON.stringify({ alg: "RS256", kid: "fake", typ: "JWT" })).toString("base64url");
    const idToken = `${header}.${Buffer.from(JSON.stringify(claims)).toString("base64url")}.sig`;
    return json({
      access_token: accessToken,
      expires_in: this.tokenLifetime,
      scope: scopes.map((s) => (s === "email" ? "https://www.googleapis.com/auth/userinfo.email" : s)).join(" "),
      token_type: "Bearer",
      ...(refreshToken ? { refresh_token: refreshToken } : {}),
      ...(scopes.includes("openid") ? { id_token: idToken } : {}),
    });
  }

  private async gmail(request: Request, url: URL): Promise<Response> {
    const as = this.access.get(request.headers.get("authorization")?.replace("Bearer ", "") ?? "");
    if (!as) return json({ error: { code: 401, message: "Request had invalid authentication credentials." } }, 401);
    const path = url.pathname.replace("/gmail/v1/users/me", "");
    this.apiCalls.push(`${as} ${request.method} ${path}`);
    if (request.method === "GET" && path === "/profile") return json({ emailAddress: as, messagesTotal: this.messages.size, threadsTotal: 2, historyId: "1" });
    if (request.method === "GET" && path === "/labels") return json({ labels: [{ id: "INBOX", name: "INBOX", type: "system" }, { id: "Label_1", name: "Work", type: "user" }] });
    if (request.method === "GET" && path === "/messages") {
      const q = url.searchParams.get("q") ?? "";
      const ids = [...this.messages.entries()].filter(([, m]) => !q.includes("is:unread") || m.labelIds.includes("UNREAD")).map(([id, m]) => ({ id, threadId: m.threadId }));
      return json({ messages: ids.slice(0, Number(url.searchParams.get("maxResults") ?? 100)), resultSizeEstimate: ids.length });
    }
    if (request.method === "POST" && path === "/messages/send") {
      if (this.failNextSend) {
        const status = this.failNextSend;
        this.failNextSend = null;
        return json({ error: { code: status, message: "Backend Error" } }, status);
      }
      const body = (await request.json()) as { raw: string; threadId?: string };
      this.sent.push({ raw: Buffer.from(body.raw, "base64url").toString("utf8"), threadId: body.threadId ?? null });
      return json({ id: `sent${this.sent.length}`, threadId: body.threadId ?? `t-new${this.sent.length}`, labelIds: ["SENT"] });
    }
    const attachment = /^\/messages\/([^/]+)\/attachments\/([^/]+)$/.exec(path);
    if (attachment && request.method === "GET") {
      if (!this.messages.has(attachment[1]!) || attachment[2] !== "att1") return json({ error: { code: 404, message: "Requested entity was not found." } }, 404);
      return json({ size: this.attachment.byteLength, data: Buffer.from(this.attachment).toString("base64url") });
    }
    const message = /^\/messages\/([^/]+)(\/modify|\/trash)?$/.exec(path);
    if (message) {
      const found = this.messages.get(message[1]!);
      if (!found) return json({ error: { code: 404, message: "Requested entity was not found." } }, 404);
      if (request.method === "DELETE") {
        this.messages.delete(message[1]!);
        return new MiniflareResponse(null, { status: 204 }) as unknown as Response;
      }
      if (request.method === "POST" && message[2] === "/modify") {
        const body = (await request.json()) as { addLabelIds: string[]; removeLabelIds: string[] };
        found.labelIds = [...new Set([...found.labelIds.filter((l) => !body.removeLabelIds.includes(l)), ...body.addLabelIds])];
      }
      const wanted = url.searchParams.getAll("metadataHeaders");
      const headers = Object.entries(found.headers).filter(([name]) => url.searchParams.get("format") !== "metadata" || wanted.includes(name)).map(([name, value]) => ({ name, value }));
      const payload = url.searchParams.get("format") === "full"
        ? { mimeType: "multipart/alternative", headers, parts: [
          { partId: "0", mimeType: "text/plain", headers: [{ name: "Content-Type", value: "text/plain; charset=UTF-8" }], body: { size: found.text.length, data: Buffer.from(found.text).toString("base64url") } },
          { partId: "1", mimeType: "text/html", headers: [], body: { size: 10, data: Buffer.from(`<p>${found.text || "Hello &amp; welcome"}</p>`).toString("base64url") } },
          { partId: "2", mimeType: "application/pdf", filename: "notes.pdf", headers: [], body: { size: this.attachment.byteLength, attachmentId: "att1" } },
        ] }
        : { mimeType: "multipart/alternative", headers };
      if (url.searchParams.get("format") === "raw") {
        const raw = `${Object.entries(found.headers).map(([name, value]) => `${name}: ${value}`).join("\r\n")}\r\n\r\n${found.text}`;
        return json({ id: message[1], threadId: found.threadId, labelIds: found.labelIds, raw: Buffer.from(raw).toString("base64url") });
      }
      return json({ id: message[1], threadId: found.threadId, labelIds: found.labelIds, snippet: found.snippet, payload });
    }
    if (request.method === "POST" && path === "/drafts") {
      const body = (await request.json()) as { message: { raw: string; threadId?: string } };
      return json({ id: "d1", message: { id: "m-draft", threadId: body.message.threadId ?? "t-draft", labelIds: ["DRAFT"] } });
    }
    return json({ error: { code: 404, message: `no route ${request.method} ${path}` } }, 404);
  }
}

const WORKSPACE = new Set(["https://www.googleapis.com", "https://docs.googleapis.com", "https://sheets.googleapis.com", "https://people.googleapis.com"]);
/** Any other Google API host, for Google Cloud: `*.googleapis.com`, except sign-in and Gmail. */
const isWorkspace = (url: URL) => WORKSPACE.has(url.origin) || (url.protocol === "https:" && url.hostname.endsWith(".googleapis.com") && !["oauth2.googleapis.com", "gmail.googleapis.com"].includes(url.hostname));

function json(value: unknown, status = 200): Response {
  return new MiniflareResponse(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } }) as unknown as Response;
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
