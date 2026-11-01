import { z } from "zod";
import { krakenMacSignIn } from "../oauth/kraken";
import { ProviderError, tool, type AppDefinition, type AppTool, type Authorized, type OutgoingRequest, type ProviderApi } from "../app";

/**
 * Kraken as an app: `codemode.apps.kraken.<tool>({ account, ... })`, with an API key and its
 * private key from Kraken's settings; the person names the account. Private calls are form
 * posts with an always-increasing nonce, signed: API-Sign is base64(HMAC-SHA512(path +
 * SHA256(nonce + body), base64-decoded secret)). What a key may do (query, trade, withdraw)
 * is set on the key at Kraken.
 */

type Answer<T> = { error: string[]; result: T };

/** Kraken answers 200 with its errors in `error`. */
function resultOf<T>(answer: Answer<T>): T {
  if (answer.error?.length) {
    const message = answer.error.join("; ");
    if (/EAPI:Invalid key|EAPI:Invalid signature|EGeneral:Permission denied/.test(message)) throw new ProviderError(403, `Kraken: ${message}`);
    throw new ProviderError(400, `Kraken: ${message}`);
  }
  return answer.result;
}

async function publicCall<T>(api: ProviderApi, method: string, query: Record<string, string | undefined> = {}): Promise<T> {
  return resultOf((await api.request("GET", `/0/public/${method}`, { query })) as Answer<T>);
}

async function privateCall<T>(api: ProviderApi, method: string, params: Record<string, string | number | boolean | undefined> = {}): Promise<T> {
  const form = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) if (value !== undefined) form.set(key, String(value));
  const answer = (await api.request("POST", `/0/private/${method}`, { raw: { contentType: "application/x-www-form-urlencoded", data: form.toString() } })) as Answer<T>;
  return resultOf(answer);
}

let lastNonce = 0;
/** Microseconds, never repeated by this isolate. */
function nonce(): string {
  lastNonce = Math.max(Date.now() * 1000, lastNonce + 1);
  return String(lastNonce);
}

function base64(bytes: ArrayBuffer | Uint8Array): string {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)));
}

/** Signs a private call: the nonce goes first in the form, and the signature in API-Sign. Public calls go as they are. */
export async function signKraken(fields: Readonly<Record<string, string>>, request: OutgoingRequest): Promise<Authorized> {
  if (!request.url.pathname.startsWith("/0/private/")) return { headers: {} };
  const form = new URLSearchParams(typeof request.body === "string" ? request.body : new TextDecoder().decode(request.body ?? new Uint8Array()));
  form.delete("nonce");
  const n = nonce();
  const body = new URLSearchParams([["nonce", n], ...form]).toString();
  let secret: Uint8Array<ArrayBuffer>;
  try {
    secret = Uint8Array.from(atob(fields.secret ?? ""), (c) => c.charCodeAt(0));
  } catch {
    throw new ProviderError(400, "Kraken's private key is base64");
  }
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(n + body)));
  const path = new TextEncoder().encode(request.url.pathname);
  const message = new Uint8Array(path.length + digest.length);
  message.set(path);
  message.set(digest, path.length);
  const key = await crypto.subtle.importKey("raw", secret, { name: "HMAC", hash: "SHA-512" }, false, ["sign"]);
  const sign = base64(await crypto.subtle.sign("HMAC", key, message));
  return { headers: { "API-Key": fields.key!, "API-Sign": sign }, body };
}

const pair = z.string().regex(/^[A-Z0-9./]{3,20}$/i).describe("A pair such as XBTEUR or ETH/EUR.");

const tools: AppTool[] = [
  tool({
    name: "get_balance",
    description: "What the account holds, by asset: { ZEUR: \"120.50\", XXBT: \"0.01\", ... }. Kraken prefixes some assets (X for crypto, Z for money).",
    input: z.object({}).strict(),
    idempotent: true,
    run: (api) => privateCall(api, "BalanceEx"),
  }),
  tool({
    name: "get_trade_balance",
    description: "The account's value in one asset (EUR by default), with margin: { eb, tb, m, n, c, v, e, mf, ml }.",
    input: z.object({ asset: z.string().regex(/^[A-Z]{2,8}$/).optional() }).strict(),
    idempotent: true,
    run: (api, input) => privateCall(api, "TradeBalance", { asset: input.asset ?? "ZEUR" }),
  }),
  tool({
    name: "list_open_orders",
    description: "Orders not yet filled: { open: { <id>: { descr, vol, vol_exec, status, opentm, ... } } }.",
    input: z.object({}).strict(),
    idempotent: true,
    run: (api) => privateCall(api, "OpenOrders"),
  }),
  tool({
    name: "list_closed_orders",
    description: "Filled and cancelled orders, newest first, 50 at a time: { closed: { <id>: {...} }, count }. Times are Unix seconds.",
    input: z.object({ start: z.number().optional(), end: z.number().optional(), offset: z.number().int().min(0).optional() }).strict(),
    idempotent: true,
    run: (api, input) => privateCall(api, "ClosedOrders", { start: input.start, end: input.end, ofs: input.offset }),
  }),
  tool({
    name: "list_trades",
    description: "The account's trades, newest first, 50 at a time: { trades: { <id>: { pair, type, price, vol, cost, fee, time } }, count }.",
    input: z.object({ start: z.number().optional(), end: z.number().optional(), offset: z.number().int().min(0).optional() }).strict(),
    idempotent: true,
    run: (api, input) => privateCall(api, "TradesHistory", { start: input.start, end: input.end, ofs: input.offset }),
  }),
  tool({
    name: "list_ledger",
    description: "Every movement on the account (trades, deposits, withdrawals, fees, staking), newest first, 50 at a time: { ledger: { <id>: { asset, amount, fee, balance, type, time } }, count }.",
    input: z.object({
      asset: z.string().max(64).optional().describe("Comma-separated assets; all when left out."),
      type: z.enum(["all", "trade", "deposit", "withdrawal", "transfer", "margin", "rollover", "spend", "receive", "settled", "adjustment", "staking", "sale", "credit"]).optional(),
      start: z.number().optional(), end: z.number().optional(), offset: z.number().int().min(0).optional(),
    }).strict(),
    idempotent: true,
    run: (api, input) => privateCall(api, "Ledgers", { asset: input.asset, type: input.type, start: input.start, end: input.end, ofs: input.offset }),
  }),
  tool({
    name: "get_ticker",
    description: "Current prices for pairs: { <pair>: { a: [ask], b: [bid], c: [last, volume], v, p, t, l, h, o } }.",
    input: z.object({ pairs: z.array(pair).min(1).max(20) }).strict(),
    idempotent: true,
    run: (api, input) => publicCall(api, "Ticker", { pair: input.pairs.join(",") }),
  }),
  tool({
    name: "add_order",
    description:
      "Places an order, if the key may trade. `validate: true` only checks it with Kraken and places nothing; do that first. " +
      "Returns { descr: { order }, txid: [ids] }.",
    input: z.object({
      pair,
      side: z.enum(["buy", "sell"]),
      type: z.enum(["market", "limit"]),
      volume: z.string().regex(/^\d+(\.\d+)?$/).describe("In the pair's base asset, as a decimal string."),
      price: z.string().regex(/^\d+(\.\d+)?$/).optional().describe("A limit order's price."),
      validate: z.boolean().optional(),
    }).strict(),
    idempotent: false,
    async run(api, input) {
      if (input.type === "limit" && !input.price) throw new ProviderError(400, "a limit order needs a price");
      return privateCall(api, "AddOrder", { pair: input.pair, type: input.side, ordertype: input.type, volume: input.volume, price: input.price, validate: input.validate || undefined });
    },
  }),
  tool({
    name: "cancel_order",
    description: "Cancels an open order by its ID: { count }.",
    input: z.object({ id: z.string().regex(/^[A-Z0-9-]{6,40}$/) }).strict(),
    idempotent: true,
    run: (api, input) => privateCall(api, "CancelOrder", { txid: input.id }),
  }),
  tool({
    name: "call",
    description: "Any other Kraken REST method: `private: true` for the account's own (signed), otherwise a public one. Returns its `result`. See docs.kraken.com/api.",
    input: z.object({ method: z.string().regex(/^[A-Za-z]{3,64}$/), params: z.record(z.string(), z.union([z.string(), z.number(), z.boolean()])).optional(), private: z.boolean() }).strict(),
    idempotent: false,
    run: (api, input) => input.private
      ? privateCall(api, input.method, input.params)
      : publicCall(api, input.method, Object.fromEntries(Object.entries(input.params ?? {}).map(([k, v]) => [k, String(v)]))),
  }),
];

export const kraken: AppDefinition = {
  name: "kraken",
  title: "Kraken",
  description: "Your Kraken account: balances, orders, trades and ledger, and placing orders if your key may trade.",
  permissions: [
    "See your balances, orders, trades and ledger",
    "Place and cancel orders, if your API key allows it",
    "See current prices",
  ],
  signIn: "token",
  provider: "kraken",
  providerTitle: "Kraken",
  category: "finance",
  apiOrigin: "https://api.kraken.com",
  hosts: ["api.kraken.com"],
  reference: "https://docs.kraken.com/api/",
  token: {
    helpUrl: "https://pro.kraken.com/app/settings/api",
    named: true,
    fields: [
      { name: "key", label: "API key", help: "In Kraken, open Settings, API, and create a key. Query permissions are enough to read; add Create & modify orders to trade.", secret: true },
      { name: "secret", label: "Private key", help: "Shown once, when the key is created.", secret: true },
    ],
    authorize: signKraken,
    mac: krakenMacSignIn,
    async identify(api) {
      await privateCall(api, "BalanceEx");
      return null;
    },
  },
  tools,
};
