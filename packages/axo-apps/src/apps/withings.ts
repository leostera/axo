import { z } from "zod";
import { tool, type AnswerError, type AppDefinition, type AppTool, type ProviderApi } from "../app";

/**
 * Withings as an app: `codemode.apps.withings.<tool>({ account, ... })`: body measures (weight,
 * body composition, blood pressure, temperature, SpO2...), daily activity, workouts, sleep, ECGs
 * and devices. Every call is a POST with an `action` to one of Withings' services; the answer is
 * `{ status, body }`, HTTP 200 even on errors (status 401 is a token it no longer takes). The
 * account is named by its Withings user ID (oauth/withings.ts).
 */

/** Withings' measure types, by the names a script uses. */
const MEASURES = {
  weight: [1, "kg"], height: [4, "m"], fat_free_mass: [5, "kg"], fat_ratio: [6, "%"], fat_mass: [8, "kg"],
  diastolic: [9, "mmHg"], systolic: [10, "mmHg"], heart_rate: [11, "bpm"], temperature: [12, "°C"], spo2: [54, "%"],
  body_temperature: [71, "°C"], skin_temperature: [73, "°C"], muscle_mass: [76, "kg"], hydration: [77, "kg"], bone_mass: [88, "kg"],
  pulse_wave_velocity: [91, "m/s"], vo2max: [123, "ml/min/kg"], afib: [130, ""], qrs: [135, "ms"], pr: [136, "ms"], qt: [137, "ms"], qtc: [138, "ms"],
  vascular_age: [155, "years"], nerve_health: [167, ""], extracellular_water: [168, "kg"], intracellular_water: [169, "kg"], visceral_fat: [170, ""], basal_metabolic_rate: [226, "kcal"],
} as const satisfies Record<string, readonly [number, string]>;
type MeasureName = keyof typeof MEASURES;
const MEASURE_BY_CODE = new Map<number, [MeasureName, string]>(Object.entries(MEASURES).map(([name, [code, unit]]) => [code, [name as MeasureName, unit]]));

const day = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).describe("A date, YYYY-MM-DD.");
const instant = z.string().datetime({ offset: true }).or(day).describe("A date (YYYY-MM-DD, from midnight UTC) or an ISO time.");
const seconds = (value: string) => String(Math.floor(Date.parse(value.length === 10 ? `${value}T00:00:00Z` : value) / 1000));
const iso = (unix: unknown) => (typeof unix === "number" ? new Date(unix * 1000).toISOString() : null);

/** One Withings action: a form POST, whose `body` comes back once its `status` is 0 (answerError checks that). */
async function call(api: ProviderApi, path: string, action: string, params: Record<string, string | undefined> = {}): Promise<Record<string, any>> {
  const form = new URLSearchParams({ action });
  for (const [key, value] of Object.entries(params)) if (value !== undefined) form.set(key, value);
  const answer = (await api.request("POST", path, { raw: { contentType: "application/x-www-form-urlencoded", data: form.toString() } })) as { body?: Record<string, any> };
  return answer.body ?? {};
}

const tools: AppTool[] = [
  tool({
    name: "get_measures",
    description:
      `Body measures, newest first: { measures: [{ date, type, value, unit, device }], more, offset }. \`types\` picks some of ${Object.keys(MEASURES).join(", ")}; all when left out. ` +
      "Values are in the unit shown (kg, %, mmHg, bpm...). Pass `offset` from an answer with `more` for the next page.",
    input: z.object({
      types: z.array(z.enum(Object.keys(MEASURES) as [MeasureName, ...MeasureName[]])).min(1).optional(),
      start: instant.optional(),
      end: instant.optional(),
      offset: z.number().int().min(0).optional(),
    }).strict(),
    idempotent: true,
    async run(api, input) {
      const body = await call(api, "/measure", "getmeas", {
        meastypes: input.types?.map((t) => String(MEASURES[t][0])).join(","),
        category: "1",
        startdate: input.start ? seconds(input.start) : undefined,
        enddate: input.end ? seconds(input.end) : undefined,
        offset: input.offset === undefined ? undefined : String(input.offset),
      });
      const groups = (body.measuregrps ?? []) as Array<{ date: number; deviceid?: string | null; measures: Array<{ value: number; type: number; unit: number }> }>;
      const measures = groups.flatMap((group) => group.measures.map((m) => {
        const [type, unit] = MEASURE_BY_CODE.get(m.type) ?? [`type_${m.type}`, ""];
        return { date: iso(group.date), type, value: Number((m.value * 10 ** m.unit).toPrecision(12)), unit, device: group.deviceid ?? null };
      }));
      return { measures, more: Boolean(body.more), offset: typeof body.offset === "number" ? body.offset : null };
    },
  }),
  tool({
    name: "get_activity",
    description: "Daily activity from the user's trackers and phone: { days: [{ date, steps, distance (m), elevation (m), calories, totalCalories, active (s), soft, moderate, intense, hrAverage, ... }], more, offset }.",
    input: z.object({ start: day, end: day, offset: z.number().int().min(0).optional() }).strict(),
    idempotent: true,
    async run(api, input) {
      const body = await call(api, "/v2/measure", "getactivity", {
        startdateymd: input.start, enddateymd: input.end, offset: input.offset === undefined ? undefined : String(input.offset),
        data_fields: "steps,distance,elevation,soft,moderate,intense,active,calories,totalcalories,hr_average,hr_min,hr_max",
      });
      const days = (body.activities ?? []) as Array<Record<string, unknown>>;
      return {
        days: days.map((d) => ({
          date: d.date, steps: d.steps ?? null, distance: d.distance ?? null, elevation: d.elevation ?? null, calories: d.calories ?? null, totalCalories: d.totalcalories ?? null,
          active: d.active ?? null, soft: d.soft ?? null, moderate: d.moderate ?? null, intense: d.intense ?? null,
          hrAverage: d.hr_average ?? null, hrMin: d.hr_min ?? null, hrMax: d.hr_max ?? null,
        })),
        more: Boolean(body.more), offset: typeof body.offset === "number" ? body.offset : null,
      };
    },
  }),
  tool({
    name: "list_workouts",
    description: "Workouts tracked or entered, in a date range: { workouts: [{ start, end, category, data }], more, offset }, `data` as Withings gives it (calories, distance, steps, heart rate zones...).",
    input: z.object({ start: day, end: day, offset: z.number().int().min(0).optional() }).strict(),
    idempotent: true,
    async run(api, input) {
      const body = await call(api, "/v2/measure", "getworkouts", { startdateymd: input.start, enddateymd: input.end, offset: input.offset === undefined ? undefined : String(input.offset) });
      const series = (body.series ?? []) as Array<{ startdate: number; enddate: number; category: number; data?: unknown }>;
      return { workouts: series.map((w) => ({ start: iso(w.startdate), end: iso(w.enddate), category: w.category, data: w.data ?? null })), more: Boolean(body.more), offset: typeof body.offset === "number" ? body.offset : null };
    },
  }),
  tool({
    name: "get_sleep_summary",
    description: "Each night's sleep in a date range: { nights: [{ date, start, end, data: { total_sleep_time, deepsleepduration, lightsleepduration, remsleepduration, wakeupcount, hr_average, rr_average, sleep_score, ... } }], more, offset }, durations in seconds.",
    input: z.object({ start: day, end: day, offset: z.number().int().min(0).optional() }).strict(),
    idempotent: true,
    async run(api, input) {
      const body = await call(api, "/v2/sleep", "getsummary", {
        startdateymd: input.start, enddateymd: input.end, offset: input.offset === undefined ? undefined : String(input.offset),
        data_fields: "total_sleep_time,total_timeinbed,sleep_efficiency,sleep_latency,wakeup_latency,wakeupduration,wakeupcount,deepsleepduration,lightsleepduration,remsleepduration,durationtosleep,durationtowakeup,hr_average,hr_min,hr_max,rr_average,rr_min,rr_max,snoring,snoringepisodecount,sleep_score,breathing_disturbances_intensity",
      });
      const series = (body.series ?? []) as Array<{ date: string; startdate: number; enddate: number; data?: unknown }>;
      return { nights: series.map((n) => ({ date: n.date, start: iso(n.startdate), end: iso(n.enddate), data: n.data ?? null })), more: Boolean(body.more), offset: typeof body.offset === "number" ? body.offset : null };
    },
  }),
  tool({
    name: "get_sleep",
    description: "One night's sleep stages and signals, at most 24 hours from `start`: { periods: [{ start, end, state (0 awake, 1 light, 2 deep, 3 REM), hr, rr, snoring }] }.",
    input: z.object({ start: instant, end: instant }).strict(),
    idempotent: true,
    async run(api, input) {
      const body = await call(api, "/v2/sleep", "get", { startdate: seconds(input.start), enddate: seconds(input.end), data_fields: "hr,rr,snoring" });
      const series = (body.series ?? []) as Array<{ startdate: number; enddate: number; state: number; hr?: unknown; rr?: unknown; snoring?: unknown }>;
      return { periods: series.map((p) => ({ start: iso(p.startdate), end: iso(p.enddate), state: p.state, hr: p.hr ?? null, rr: p.rr ?? null, snoring: p.snoring ?? null })) };
    },
  }),
  tool({
    name: "list_ecgs",
    description: "ECG recordings (BPM Core, ScanWatch), newest first: { ecgs: [{ id, date, afib, heartRate, device }], more, offset }. `afib` 0 is a normal rhythm, 1 signs of atrial fibrillation, 2 inconclusive.",
    input: z.object({ start: instant.optional(), end: instant.optional(), offset: z.number().int().min(0).optional() }).strict(),
    idempotent: true,
    async run(api, input) {
      const body = await call(api, "/v2/heart", "list", {
        startdate: input.start ? seconds(input.start) : undefined, enddate: input.end ? seconds(input.end) : undefined,
        offset: input.offset === undefined ? undefined : String(input.offset),
      });
      const series = (body.series ?? []) as Array<{ timestamp: number; deviceid?: string; ecg?: { signalid?: number; afib?: number }; heart_rate?: number }>;
      return {
        ecgs: series.map((e) => ({ id: e.ecg?.signalid ?? null, date: iso(e.timestamp), afib: e.ecg?.afib ?? null, heartRate: e.heart_rate ?? null, device: e.deviceid ?? null })),
        more: Boolean(body.more), offset: typeof body.offset === "number" ? body.offset : null,
      };
    },
  }),
  tool({
    name: "list_devices",
    description: "The user's Withings devices: { devices: [{ id, type, model, battery, lastSync, timezone }] }.",
    input: z.object({}).strict(),
    idempotent: true,
    async run(api) {
      const body = await call(api, "/v2/user", "getdevice");
      const devices = (body.devices ?? []) as Array<{ deviceid: string; type: string; model: string; battery?: string; last_session_date?: number; timezone?: string }>;
      return { devices: devices.map((d) => ({ id: d.deviceid, type: d.type, model: d.model, battery: d.battery ?? null, lastSync: iso(d.last_session_date), timezone: d.timezone ?? null })) };
    },
  }),
];

/** Withings' status codes for a token it does not take (401 most often; 100 to 102 and 200 in its list of auth errors). */
const UNAUTHORIZED = new Set([100, 101, 102, 200, 401]);

export const withings: AppDefinition = {
  name: "withings",
  title: "Withings",
  description: "Your Withings health data: weight and body composition, blood pressure, activity, workouts, sleep and ECGs.",
  permissions: [
    "See your body measures: weight, body composition, blood pressure, heart rate, temperature and SpO2",
    "See your daily activity and workouts",
    "See your sleep, night by night",
    "See your ECG recordings and your devices",
    "See your Withings profile",
  ],
  signIn: "oauth",
  provider: "withings",
  providerTitle: "Withings",
  category: "health",
  apiOrigin: "https://wbsapi.withings.net",
  hosts: ["wbsapi.withings.net"],
  reference: "https://developer.withings.com/api-reference",
  scopes: ["user.info", "user.metrics", "user.activity"],
  requiredScopes: ["user.metrics"],
  tools,
  answerError(json): AnswerError | null {
    const answer = json as { status?: unknown; error?: unknown };
    if (typeof answer?.status !== "number" || answer.status === 0) return null;
    if (UNAUTHORIZED.has(answer.status)) return { unauthorized: true };
    return { status: 400, message: `${typeof answer.error === "string" ? answer.error.slice(0, 200) : "error"} (status ${answer.status})` };
  },
};
