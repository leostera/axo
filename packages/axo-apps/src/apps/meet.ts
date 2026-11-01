import { z } from "zod";
import { tool, type AppDefinition, type AppTool, type ProviderApi } from "../app";

/**
 * Google Meet as an app: `codemode.apps.meet.<tool>({ account, ... })` over the Meet REST API:
 * creates and manages meeting spaces (`meetings.space.created`), and reads every meeting the
 * account was in, with who came, recordings and transcripts (`meetings.space.readonly`).
 */

export const MEET_SCOPES = ["https://www.googleapis.com/auth/meetings.space.created", "https://www.googleapis.com/auth/meetings.space.readonly"];
const BASE = "/v2";
const MAX_TRANSCRIPT_CHARS = 400_000;

const space = z.string().regex(/^(spaces\/)?[A-Za-z0-9_-]{1,128}$/, "expected a space name (spaces/...) or meeting code (abc-mnop-xyz)")
  .describe("The space's name, spaces/..., or its meeting code, such as abc-mnop-xyz.");
const record = z.string().regex(/^(conferenceRecords\/)?[A-Za-z0-9_-]{1,128}$/, "expected a conference record name").describe("A conferenceRecords/... name from list_meetings.");
const pageToken = z.string().max(1024).optional();

type Space = { name: string; meetingUri?: string; meetingCode?: string; config?: unknown; activeConference?: { conferenceRecord?: string } };
type ConferenceRecord = { name: string; startTime?: string; endTime?: string; space?: string };
type Participant = { name: string; earliestStartTime?: string; latestEndTime?: string; signedinUser?: { user?: string; displayName?: string }; anonymousUser?: { displayName?: string }; phoneUser?: { displayName?: string } };

const tools: AppTool[] = [
  tool({
    name: "create_meeting",
    description: "Creates a Meet meeting and returns { name, meetingUri, meetingCode }. accessType: OPEN (anyone with the link), TRUSTED (your organization and invitees) or RESTRICTED (invitees only).",
    input: z.object({ accessType: z.enum(["OPEN", "TRUSTED", "RESTRICTED"]).optional() }).strict(),
    idempotent: false,
    async run(api, input) {
      const created = (await api.request("POST", `${BASE}/spaces`, { body: input.accessType ? { config: { accessType: input.accessType } } : {} })) as Space;
      return spaceOf(created);
    },
  }),
  tool({
    name: "get_meeting",
    description: "Reads a meeting space: { name, meetingUri, meetingCode, config, activeConference }.",
    input: z.object({ space }).strict(),
    idempotent: true,
    async run(api, input) {
      return spaceOf((await api.request("GET", `${BASE}/${spaceName(input.space)}`)) as Space);
    },
  }),
  tool({
    name: "end_meeting",
    description: "Ends the call running in a space you created, removing everyone. Returns { ended: true }.",
    input: z.object({ space }).strict(),
    idempotent: true,
    async run(api, input) {
      await api.request("POST", `${BASE}/${spaceName(input.space)}:endActiveConference`, { body: {} });
      return { ended: true };
    },
  }),
  tool({
    name: "list_meetings",
    description:
      "Lists past and current meetings the account was in, newest first: { meetings: [{ name, startTime, endTime, space }], nextPageToken }. " +
      "`meetingCode` keeps one space's; `filter` takes Meet's filter syntax, e.g. 'start_time>=\"2025-01-01T00:00:00Z\"'.",
    input: z.object({ meetingCode: z.string().regex(/^[a-z0-9-]{1,64}$/).optional(), filter: z.string().max(1024).optional(), maxResults: z.number().int().min(1).max(100).optional(), pageToken }).strict(),
    idempotent: true,
    async run(api, input) {
      const filters = [input.meetingCode ? `space.meeting_code="${input.meetingCode}"` : null, input.filter ?? null].filter(Boolean);
      const answer = (await api.request("GET", `${BASE}/conferenceRecords`, {
        query: { filter: filters.length ? filters.join(" AND ") : undefined, pageSize: String(input.maxResults ?? 25), pageToken: input.pageToken },
      })) as { conferenceRecords?: ConferenceRecord[]; nextPageToken?: string };
      return {
        meetings: (answer.conferenceRecords ?? []).map((r) => ({ name: r.name, startTime: r.startTime ?? null, endTime: r.endTime ?? null, space: r.space ?? null })),
        nextPageToken: answer.nextPageToken ?? null,
      };
    },
  }),
  tool({
    name: "list_participants",
    description: "Who was in a meeting: { participants: [{ name, displayName, user, joined, left }] }.",
    input: z.object({ meeting: record }).strict(),
    idempotent: true,
    async run(api, input) {
      return { participants: (await participants(api, recordName(input.meeting))).map(participantOf) };
    },
  }),
  tool({
    name: "list_recordings",
    description: "A meeting's recordings: { recordings: [{ name, state, startTime, endTime, driveFileId, url }] }. Download one with apps.drive.",
    input: z.object({ meeting: record }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("GET", `${BASE}/${recordName(input.meeting)}/recordings`)) as {
        recordings?: Array<{ name: string; state?: string; startTime?: string; endTime?: string; driveDestination?: { file?: string; exportUri?: string } }>;
      };
      return {
        recordings: (answer.recordings ?? []).map((r) => ({
          name: r.name, state: r.state ?? null, startTime: r.startTime ?? null, endTime: r.endTime ?? null,
          driveFileId: r.driveDestination?.file ?? null, url: r.driveDestination?.exportUri ?? null,
        })),
      };
    },
  }),
  tool({
    name: "get_transcript",
    description:
      "A meeting's transcript as text, one \"Name: words\" line per turn: { transcripts: [{ name, state, driveDocId, text, truncated }] }. " +
      "Transcripts exist only for meetings where someone turned them on.",
    input: z.object({ meeting: record }).strict(),
    idempotent: true,
    async run(api, input) {
      const meeting = recordName(input.meeting);
      const list = (await api.request("GET", `${BASE}/${meeting}/transcripts`)) as {
        transcripts?: Array<{ name: string; state?: string; docsDestination?: { document?: string } }>;
      };
      const names = new Map((await participants(api, meeting)).map((p) => [p.name, participantOf(p).displayName ?? "Someone"]));
      const transcripts = [];
      for (const transcript of list.transcripts ?? []) {
        let text = "";
        let next: string | undefined;
        do {
          const page = (await api.request("GET", `${BASE}/${transcript.name}/entries`, { query: { pageSize: "100", pageToken: next } })) as {
            transcriptEntries?: Array<{ participant?: string; text?: string }>;
            nextPageToken?: string;
          };
          for (const entry of page.transcriptEntries ?? []) text += `${names.get(entry.participant ?? "") ?? "Someone"}: ${entry.text ?? ""}\n`;
          next = page.nextPageToken;
        } while (next && text.length < MAX_TRANSCRIPT_CHARS);
        transcripts.push({
          name: transcript.name,
          state: transcript.state ?? null,
          driveDocId: transcript.docsDestination?.document ?? null,
          text: text.slice(0, MAX_TRANSCRIPT_CHARS),
          truncated: Boolean(next) || text.length > MAX_TRANSCRIPT_CHARS,
        });
      }
      return { transcripts };
    },
  }),
];

export const meet: AppDefinition = {
  name: "meet",
  title: "Google Meet",
  description: "Start meetings, and look back at the ones you were in.",
  permissions: [
    "Create meetings and end calls in them",
    "See every meeting you were in, and who came",
    "Read their recordings and transcripts",
  ],
  signIn: "oauth",
  provider: "google",
  providerTitle: "Google",
  category: "communication",
  scopes: ["openid", "email", ...MEET_SCOPES],
  requiredScopes: MEET_SCOPES,
  apiOrigin: "https://meet.googleapis.com",
  hosts: ["meet.googleapis.com"],
  reference: "https://developers.google.com/workspace/meet/api/reference/rest/v2",
  tools,
};

function spaceName(space: string): string {
  return space.startsWith("spaces/") ? space : `spaces/${space}`;
}

function recordName(record: string): string {
  return record.startsWith("conferenceRecords/") ? record : `conferenceRecords/${record}`;
}

function spaceOf(s: Space) {
  return { name: s.name, meetingUri: s.meetingUri ?? null, meetingCode: s.meetingCode ?? null, config: s.config ?? null, activeConference: s.activeConference?.conferenceRecord ?? null };
}

async function participants(api: ProviderApi, meeting: string): Promise<Participant[]> {
  const all: Participant[] = [];
  let next: string | undefined;
  do {
    const page = (await api.request("GET", `${BASE}/${meeting}/participants`, { query: { pageSize: "250", pageToken: next } })) as { participants?: Participant[]; nextPageToken?: string };
    all.push(...(page.participants ?? []));
    next = page.nextPageToken;
  } while (next && all.length < 2000);
  return all;
}

function participantOf(p: Participant) {
  return {
    name: p.name,
    displayName: p.signedinUser?.displayName ?? p.anonymousUser?.displayName ?? p.phoneUser?.displayName ?? null,
    user: p.signedinUser?.user ?? null,
    joined: p.earliestStartTime ?? null,
    left: p.latestEndTime ?? null,
  };
}
