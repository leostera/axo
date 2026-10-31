import { z } from "zod";
import { ProviderError, tool, type AppDefinition, type AppTool, type ProviderApi } from "./app";
import { basic } from "./token";

/**
 * Octopus Energy as an app: `codemode.apps.octopus.<tool>({ account, ... })`, with the API key
 * from the person's Octopus dashboard and their account number (A-1234ABCD), which names the
 * account. The REST API takes the key as the user name of HTTP basic auth, with no password.
 */

const accountNumber = z.string().regex(/^A-[0-9A-F]{8}$/i, "an account number looks like A-1234ABCD");
const isoTime = z.iso.datetime({ offset: true });

type Account = {
  number: string;
  properties: Array<{
    id: number;
    address_line_1?: string; town?: string; postcode?: string; moved_in_at?: string | null; moved_out_at?: string | null;
    electricity_meter_points?: Array<{ mpan: string; is_export?: boolean; meters?: Array<{ serial_number: string }>; agreements?: Array<{ tariff_code: string; valid_from: string; valid_to: string | null }> }>;
    gas_meter_points?: Array<{ mprn: string; meters?: Array<{ serial_number: string }>; agreements?: Array<{ tariff_code: string; valid_from: string; valid_to: string | null }> }>;
  }>;
};

async function account(api: ProviderApi, number: string): Promise<Account> {
  return (await api.request("GET", `/v1/accounts/${encodeURIComponent(number.toUpperCase())}/`)) as Account;
}

const current = <T extends { valid_to: string | null }>(agreements: T[] | undefined): T | null =>
  (agreements ?? []).find((a) => !a.valid_to || Date.parse(a.valid_to) > Date.now()) ?? null;

type Page<T> = { count?: number; next?: string | null; results?: T[] };

const tools: AppTool[] = [
  tool({
    name: "get_account",
    description:
      "The account's properties and meters: { number, properties: [{ address, movedIn, electricity: [{ mpan, export, meters, tariff }], gas: [{ mprn, meters, tariff }] }] }. " +
      "`tariff` is the current tariff code, such as E-1R-AGILE-24-10-01-C; pass meters and tariffs to the other tools.",
    input: z.object({}).strict(),
    idempotent: true,
    async run(api) {
      const found = await account(api, api.account);
      return {
        number: found.number,
        properties: found.properties.filter((p) => !p.moved_out_at).map((p) => ({
          address: [p.address_line_1, p.town, p.postcode].filter(Boolean).join(", "),
          movedIn: p.moved_in_at ?? null,
          electricity: (p.electricity_meter_points ?? []).map((m) => ({ mpan: m.mpan, export: m.is_export ?? false, meters: (m.meters ?? []).map((x) => x.serial_number), tariff: current(m.agreements)?.tariff_code ?? null })),
          gas: (p.gas_meter_points ?? []).map((m) => ({ mprn: m.mprn, meters: (m.meters ?? []).map((x) => x.serial_number), tariff: current(m.agreements)?.tariff_code ?? null })),
        })),
      };
    },
  }),
  tool({
    name: "get_consumption",
    description:
      "A meter's readings over time, oldest first: { results: [{ consumption, interval_start, interval_end }] }, in kWh for electricity and for SMETS2 gas (m³ for SMETS1 gas). " +
      "`groupBy` sums them by hour, day, week, month or quarter; half-hourly when left out.",
    input: z.object({
      fuel: z.enum(["electricity", "gas"]),
      meterPoint: z.string().regex(/^\d{6,13}$/).describe("The MPAN (electricity) or MPRN (gas), from get_account."),
      serial: z.string().min(1).max(64).describe("The meter's serial number, from get_account."),
      from: isoTime,
      to: isoTime.optional(),
      groupBy: z.enum(["hour", "day", "week", "month", "quarter"]).optional(),
    }).strict(),
    idempotent: true,
    async run(api, input) {
      const points = input.fuel === "electricity" ? "electricity-meter-points" : "gas-meter-points";
      const results: unknown[] = [];
      let next: string | null = `/v1/${points}/${input.meterPoint}/meters/${encodeURIComponent(input.serial)}/consumption/`;
      let query: Record<string, string | undefined> | undefined = { period_from: input.from, period_to: input.to, group_by: input.groupBy, order_by: "period", page_size: "25000" };
      while (next && results.length < 50_000) {
        const page = (await api.request("GET", next, { query })) as Page<unknown>;
        results.push(...(page.results ?? []));
        next = page.next ?? null;
        query = undefined; // `next` carries its own query
      }
      return { results };
    },
  }),
  tool({
    name: "get_unit_rates",
    description:
      "A tariff's prices per kWh over time, newest first: { results: [{ value_inc_vat, value_exc_vat, valid_from, valid_to }] } in pence. " +
      "For Agile tariffs these are the half-hourly prices, published the afternoon before. Also `standing-charges`.",
    input: z.object({
      fuel: z.enum(["electricity", "gas"]),
      tariff: z.string().regex(/^[EG]-\w{2,3}-[A-Z0-9-]+-[A-Z]$/, "a tariff code looks like E-1R-AGILE-24-10-01-C").describe("A tariff code, from get_account."),
      kind: z.enum(["standard-unit-rates", "day-unit-rates", "night-unit-rates", "standing-charges"]).optional().describe("Standard unit rates when left out."),
      from: isoTime.optional(),
      to: isoTime.optional(),
    }).strict(),
    idempotent: true,
    async run(api, input) {
      // A tariff code is its product's code with the fuel, register and region around it.
      const product = input.tariff.split("-").slice(2, -1).join("-");
      const tariffs = input.fuel === "electricity" ? "electricity-tariffs" : "gas-tariffs";
      return api.request("GET", `/v1/products/${product}/${tariffs}/${input.tariff}/${input.kind ?? "standard-unit-rates"}/`, {
        query: { period_from: input.from, period_to: input.to, page_size: "1500" },
      });
    },
  }),
  tool({
    name: "list_products",
    description: "Octopus's current tariffs on sale: { results: [{ code, display_name, full_name, description, is_variable, is_green, available_from, available_to }] }.",
    input: z.object({ isVariable: z.boolean().optional(), isGreen: z.boolean().optional() }).strict(),
    idempotent: true,
    async run(api, input) {
      const results: unknown[] = [];
      let next: string | null = "/v1/products/";
      let query: Record<string, string | undefined> | undefined = { is_variable: input.isVariable?.toString(), is_green: input.isGreen?.toString(), page_size: "100" };
      while (next && results.length < 1000) {
        const page = (await api.request("GET", next, { query })) as Page<unknown>;
        results.push(...(page.results ?? []));
        next = page.next ?? null;
        query = undefined;
      }
      return { results };
    },
  }),
];

export const octopus: AppDefinition = {
  name: "octopus",
  title: "Octopus Energy",
  description: "Your Octopus Energy account: meters, half-hourly usage and tariff prices.",
  permissions: [
    "See your account, properties, meters and tariffs",
    "Read your electricity and gas usage, half-hourly or summed",
    "See tariff prices, including Agile's half-hourly ones",
  ],
  signIn: "token",
  provider: "octopus",
  providerTitle: "Octopus Energy",
  category: "home",
  apiOrigin: "https://api.octopus.energy",
  hosts: ["api.octopus.energy"],
  reference: "https://developer.octopus.energy/rest/reference",
  token: {
    helpUrl: "https://octopus.energy/dashboard/new/accounts/personal-details/api-access",
    named: false,
    fields: [
      { name: "number", label: "Account number", help: "Your account number, such as A-1234ABCD, is at the top of your Octopus dashboard and on your bills.", secret: false },
      { name: "key", label: "API key", help: "Your API key is in your Octopus dashboard, under Personal details, API access.", secret: true },
    ],
    authorize: basic("key", null),
    async identify(api, fields) {
      const number = accountNumber.safeParse(fields.number);
      if (!number.success) throw new ProviderError(400, "an account number looks like A-1234ABCD");
      return (await account(api, number.data)).number.toLowerCase();
    },
  },
  tools,
};
