import { z } from "zod";
import { ProviderError, tool, type AppDefinition, type AppTool } from "../app";
import { bearer } from "../token";

/**
 * Wise as an app: `codemode.apps.wise.<tool>({ account, ... })`, with a personal API token from
 * Wise's settings, named by the email it belongs to. A token reaches every profile of its user
 * (personal and business), so most tools take the profile. In the UK and EEA, Wise does not let
 * a personal token fund transfers or read statements (strong customer authentication): those
 * calls fail with Wise's own message.
 */

const profile = z.number().int().positive().describe("A profile ID, from list_profiles.");
const currency = z.string().regex(/^[A-Z]{3}$/, "a currency code, such as EUR");

const tools: AppTool[] = [
  tool({
    name: "list_profiles",
    description: "The user's profiles, personal and business: { profiles: [{ id, type, name }] }.",
    input: z.object({}).strict(),
    idempotent: true,
    async run(api) {
      const profiles = (await api.request("GET", "/v2/profiles")) as Array<{ id: number; type: string; fullName?: string; details?: { firstName?: string; lastName?: string; name?: string } }>;
      return {
        profiles: profiles.map((p) => ({
          id: p.id,
          type: p.type.toLowerCase(),
          name: p.fullName ?? p.details?.name ?? [p.details?.firstName, p.details?.lastName].filter(Boolean).join(" ") ?? null,
        })),
      };
    },
  }),
  tool({
    name: "list_balances",
    description: "A profile's balances: { balances: [{ id, currency, amount, reserved, name }] }, amounts in the currency's units.",
    input: z.object({ profile }).strict(),
    idempotent: true,
    async run(api, input) {
      const balances = (await api.request("GET", `/v4/profiles/${input.profile}/balances`, { query: { types: "STANDARD,SAVINGS" } })) as Array<{
        id: number; currency: string; name?: string | null; type?: string; amount?: { value: number }; reservedAmount?: { value: number };
      }>;
      return { balances: balances.map((b) => ({ id: b.id, currency: b.currency, amount: b.amount?.value ?? null, reserved: b.reservedAmount?.value ?? null, name: b.name ?? null, type: b.type?.toLowerCase() ?? null })) };
    },
  }),
  tool({
    name: "get_rate",
    description: "Wise's current mid-market rate between two currencies: { source, target, rate, time }.",
    input: z.object({ source: currency, target: currency }).strict(),
    idempotent: true,
    async run(api, input) {
      const [rate] = (await api.request("GET", "/v1/rates", { query: { source: input.source, target: input.target } })) as Array<{ source: string; target: string; rate: number; time: string }>;
      return rate ?? null;
    },
  }),
  tool({
    name: "list_transfers",
    description: "A profile's transfers, newest first: { transfers: [{ id, status, sourceCurrency, sourceValue, targetCurrency, targetValue, reference, created, recipient }] }.",
    input: z.object({
      profile,
      status: z.string().max(64).optional().describe("Only those in this status, such as \"outgoing_payment_sent\"."),
      from: z.iso.datetime({ offset: true }).optional(),
      to: z.iso.datetime({ offset: true }).optional(),
      limit: z.number().int().min(1).max(200).optional().describe("Default 50."),
      offset: z.number().int().min(0).optional(),
    }).strict(),
    idempotent: true,
    async run(api, input) {
      const transfers = (await api.request("GET", "/v1/transfers", {
        query: { profile: String(input.profile), status: input.status, createdDateStart: input.from, createdDateEnd: input.to, limit: String(input.limit ?? 50), offset: String(input.offset ?? 0) },
      })) as Array<{ id: number; status: string; sourceCurrency: string; sourceValue: number; targetCurrency: string; targetValue: number; reference?: string; created: string; targetAccount?: number }>;
      return {
        transfers: transfers.map((t) => ({ id: t.id, status: t.status, sourceCurrency: t.sourceCurrency, sourceValue: t.sourceValue, targetCurrency: t.targetCurrency, targetValue: t.targetValue, reference: t.reference ?? null, created: t.created, recipient: t.targetAccount ?? null })),
      };
    },
  }),
  tool({
    name: "get_transfer",
    description: "One transfer, with everything Wise says about it.",
    input: z.object({ id: z.number().int().positive() }).strict(),
    idempotent: true,
    async run(api, input) {
      return api.request("GET", `/v1/transfers/${input.id}`);
    },
  }),
  tool({
    name: "list_recipients",
    description: "A profile's saved recipients: { recipients: [{ id, name, currency, type, details }] }.",
    input: z.object({ profile, currency: currency.optional() }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("GET", "/v2/accounts", { query: { profileId: String(input.profile), currency: input.currency, size: "200" } })) as {
        content?: Array<{ id: number; name?: { fullName?: string }; currency: string; type: string; accountSummary?: string; longAccountSummary?: string }>;
      };
      return { recipients: (answer.content ?? []).map((r) => ({ id: r.id, name: r.name?.fullName ?? null, currency: r.currency, type: r.type, details: r.longAccountSummary ?? r.accountSummary ?? null })) };
    },
  }),
  tool({
    name: "create_quote",
    description:
      "Prices a transfer without making it: how much arrives for an amount sent, or what it costs to send an amount that arrives. " +
      "Give `sourceAmount` or `targetAmount`. Returns Wise's quote, with its rate, fees and payment options; it holds for a while.",
    input: z.object({
      profile,
      sourceCurrency: currency,
      targetCurrency: currency,
      sourceAmount: z.number().positive().optional(),
      targetAmount: z.number().positive().optional(),
    }).strict(),
    idempotent: true,
    async run(api, input) {
      if ((input.sourceAmount === undefined) === (input.targetAmount === undefined)) throw new ProviderError(400, "give sourceAmount or targetAmount");
      const { profile: id, ...quote } = input;
      return api.request("POST", `/v3/profiles/${id}/quotes`, { body: quote });
    },
  }),
];

export const wise: AppDefinition = {
  name: "wise",
  title: "Wise",
  description: "Your Wise balances, transfers, recipients and exchange rates.",
  permissions: [
    "See your profiles, balances and transfers",
    "See your recipients, and price transfers at Wise's rates",
    "Anything else your Wise API token allows",
  ],
  signIn: "token",
  provider: "wise",
  providerTitle: "Wise",
  category: "finance",
  apiOrigin: "https://api.wise.com",
  hosts: ["api.wise.com"],
  reference: "https://docs.wise.com/api-reference",
  token: {
    helpUrl: "https://wise.com/settings/api-tokens",
    named: false,
    fields: [{ name: "token", label: "API token", help: "In Wise, open Settings, then Developer tools, API tokens, and add a token. Full access lets Axo price transfers.", secret: true }],
    authorize: bearer("token"),
    async identify(api) {
      const me = (await api.request("GET", "/v1/me")) as { email?: string };
      return me.email?.toLowerCase() ?? null;
    },
  },
  tools,
};
