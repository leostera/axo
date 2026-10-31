import { z } from "zod";
import { tool, type AppDefinition, type AppTool } from "./app";

/**
 * Google Calendar as an app: `codemode.apps.calendar.<tool>({ account, ... })` over the Calendar
 * API, with full access (`calendar`): read, create, change and delete events on every calendar
 * the account can reach.
 */

export const CALENDAR_SCOPE = "https://www.googleapis.com/auth/calendar";
const BASE = "/calendar/v3";

const calendarId = z.string().min(1).max(512).default("primary").describe("A calendar ID from list_calendars; \"primary\" is the account's own.");
const eventId = z.string().min(1).max(1024);
const when = z.string().min(10).max(64)
  .describe("An RFC 3339 time such as \"2026-11-02T15:00:00+00:00\", or a date such as \"2026-11-02\" for an all-day event.");
const sendUpdates = z.enum(["all", "externalOnly", "none"]).optional().describe("Whether guests are emailed about the change; default none.");

type Event = {
  id: string;
  status?: string;
  summary?: string;
  description?: string;
  location?: string;
  htmlLink?: string;
  start?: { date?: string; dateTime?: string; timeZone?: string };
  end?: { date?: string; dateTime?: string; timeZone?: string };
  attendees?: Array<{ email?: string; responseStatus?: string; self?: boolean; organizer?: boolean }>;
  organizer?: { email?: string };
  hangoutLink?: string;
  recurringEventId?: string;
};

const eventFields = z.object({
  summary: z.string().max(1024).optional(),
  description: z.string().max(8192).optional(),
  location: z.string().max(1024).optional(),
  start: when.optional(),
  end: when.optional(),
  timeZone: z.string().max(64).optional().describe("An IANA time zone such as \"Europe/London\", for start and end."),
  attendees: z.array(z.string().email()).max(100).optional().describe("Guests' emails."),
});

const tools: AppTool[] = [
  tool({
    name: "list_calendars",
    description: "Lists the calendars the account can see: { calendars: [{ id, summary, primary, accessRole, timeZone }] }.",
    input: z.object({}).strict(),
    idempotent: true,
    async run(api) {
      const answer = (await api.request("GET", `${BASE}/users/me/calendarList`, { query: { maxResults: "250" } })) as { items?: Array<Record<string, unknown>> };
      return {
        calendars: (answer.items ?? []).map((c) => ({ id: c.id, summary: c.summaryOverride ?? c.summary, primary: c.primary === true, accessRole: c.accessRole, timeZone: c.timeZone ?? null })),
      };
    },
  }),
  tool({
    name: "list_events",
    description:
      "Lists events on a calendar between timeMin and timeMax, recurring events expanded and ordered by start: " +
      "{ events: [{ id, summary, start, end, location, attendees, organizer, status, htmlLink, meetLink }], nextPageToken }. " +
      "`query` searches event text.",
    input: z.object({
      calendarId,
      timeMin: z.string().max(64).optional().describe("RFC 3339; default now."),
      timeMax: z.string().max(64).optional().describe("RFC 3339."),
      query: z.string().max(1024).optional(),
      maxResults: z.number().int().min(1).max(250).optional().describe("Default 25."),
      pageToken: z.string().max(1024).optional(),
    }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("GET", `${BASE}/calendars/${encodeURIComponent(input.calendarId)}/events`, {
        query: {
          singleEvents: "true",
          orderBy: "startTime",
          timeMin: input.timeMin ?? new Date().toISOString(),
          timeMax: input.timeMax,
          q: input.query,
          maxResults: String(input.maxResults ?? 25),
          pageToken: input.pageToken,
        },
      })) as { items?: Event[]; nextPageToken?: string };
      return { events: (answer.items ?? []).map((e) => event(e, false)), nextPageToken: answer.nextPageToken ?? null };
    },
  }),
  tool({
    name: "get_event",
    description: "Reads one event, with its description.",
    input: z.object({ calendarId, eventId }).strict(),
    idempotent: true,
    async run(api, input) {
      return event((await api.request("GET", eventPath(input.calendarId, input.eventId))) as Event, true);
    },
  }),
  tool({
    name: "create_event",
    description: "Creates an event and returns it. Give addMeet to attach a Google Meet link. Guests are not emailed unless sendUpdates says so.",
    input: eventFields.extend({
      calendarId,
      summary: z.string().min(1).max(1024),
      start: when,
      end: when,
      addMeet: z.boolean().optional(),
      sendUpdates,
    }).strict(),
    idempotent: false,
    async run(api, input) {
      const body = {
        ...eventBody(input),
        ...(input.addMeet ? { conferenceData: { createRequest: { requestId: crypto.randomUUID(), conferenceSolutionKey: { type: "hangoutsMeet" } } } } : {}),
      };
      return event((await api.request("POST", `${BASE}/calendars/${encodeURIComponent(input.calendarId)}/events`, {
        query: { sendUpdates: input.sendUpdates ?? "none", conferenceDataVersion: input.addMeet ? "1" : undefined },
        body,
      })) as Event, true);
    },
  }),
  tool({
    name: "update_event",
    description: "Changes the fields given on an event (others are kept) and returns it. `attendees` replaces the guest list.",
    input: eventFields.extend({ calendarId, eventId, sendUpdates }).strict(),
    idempotent: true,
    async run(api, input) {
      return event((await api.request("PATCH", eventPath(input.calendarId, input.eventId), {
        query: { sendUpdates: input.sendUpdates ?? "none" },
        body: eventBody(input),
      })) as Event, true);
    },
  }),
  tool({
    name: "delete_event",
    description: "Deletes an event and returns { deleted: true }.",
    input: z.object({ calendarId, eventId, sendUpdates }).strict(),
    idempotent: true,
    async run(api, input) {
      await api.request("DELETE", eventPath(input.calendarId, input.eventId), { query: { sendUpdates: input.sendUpdates ?? "none" } });
      return { deleted: true };
    },
  }),
  tool({
    name: "free_busy",
    description: "When calendars are busy between timeMin and timeMax: { calendars: { <id>: [{ start, end }] } }.",
    input: z.object({
      timeMin: z.string().max(64),
      timeMax: z.string().max(64),
      calendars: z.array(z.string().min(1).max(512)).min(1).max(50).optional().describe("Calendar IDs or people's emails; default [\"primary\"]."),
    }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("POST", `${BASE}/freeBusy`, {
        body: { timeMin: input.timeMin, timeMax: input.timeMax, items: (input.calendars ?? ["primary"]).map((id) => ({ id })) },
      })) as { calendars?: Record<string, { busy?: Array<{ start: string; end: string }> }> };
      return { calendars: Object.fromEntries(Object.entries(answer.calendars ?? {}).map(([id, c]) => [id, c.busy ?? []])) };
    },
  }),
];

export const calendar: AppDefinition = {
  name: "calendar",
  title: "Google Calendar",
  description: "See and manage your calendars and events.",
  permissions: [
    "See every calendar you can reach, and its events",
    "Create, change and delete events, with guests and Meet links",
    "Check when people are free",
    "Share calendars and change their settings",
  ],
  provider: "google",
  scopes: ["openid", "email", CALENDAR_SCOPE],
  requiredScopes: [CALENDAR_SCOPE],
  apiOrigin: "https://www.googleapis.com",
  hosts: ["www.googleapis.com"],
  reference: "https://developers.google.com/workspace/calendar/api/v3/reference",
  tools,
};

function eventPath(calendar: string, id: string): string {
  return `${BASE}/calendars/${encodeURIComponent(calendar)}/events/${encodeURIComponent(id)}`;
}

function time(value: string, timeZone: string | undefined) {
  return /^\d{4}-\d{2}-\d{2}$/.test(value) ? { date: value } : { dateTime: value, ...(timeZone ? { timeZone } : {}) };
}

function eventBody(input: z.infer<typeof eventFields>) {
  return {
    ...(input.summary !== undefined ? { summary: input.summary } : {}),
    ...(input.description !== undefined ? { description: input.description } : {}),
    ...(input.location !== undefined ? { location: input.location } : {}),
    ...(input.start ? { start: time(input.start, input.timeZone) } : {}),
    ...(input.end ? { end: time(input.end, input.timeZone) } : {}),
    ...(input.attendees ? { attendees: input.attendees.map((email) => ({ email })) } : {}),
  };
}

function event(e: Event, withDescription: boolean) {
  return {
    id: e.id,
    summary: e.summary ?? null,
    start: e.start?.dateTime ?? e.start?.date ?? null,
    end: e.end?.dateTime ?? e.end?.date ?? null,
    allDay: Boolean(e.start?.date),
    location: e.location ?? null,
    attendees: (e.attendees ?? []).map((a) => ({ email: a.email ?? null, responseStatus: a.responseStatus ?? null })),
    organizer: e.organizer?.email ?? null,
    status: e.status ?? null,
    htmlLink: e.htmlLink ?? null,
    meetLink: e.hangoutLink ?? null,
    recurringEventId: e.recurringEventId ?? null,
    ...(withDescription ? { description: e.description ?? null } : {}),
  };
}
