import assert from "node:assert/strict";
import { test } from "node:test";
import { appDeviceSignInSchema, connectionSchema } from "@axo/protocol";
import { AppConnections } from "../src/connections/apps";
import { FakeOpenAI } from "./fake-openai";
import { sqlStorage } from "./sql-storage";

/**
 * RFD0016, device sign-in: ChatGPT signs in as the Codex CLI does. Add account shows a code the
 * person enters at OpenAI; the page polls Axo, which asks OpenAI at most once per interval and
 * stores the grant under the account's email once they have. Calls go to the Codex backend with
 * the ChatGPT account's ID; rotating refresh tokens are spent once.
 */

function fixture() {
  const openai = new FakeOpenAI();
  let clock = Date.parse("2026-10-31T12:00:00Z");
  const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(input, init);
    const answer = await openai.handle(request);
    if (!answer) throw new Error(`unexpected request to ${request.url}`);
    return answer;
  }) as typeof fetch;
  const background: Promise<unknown>[] = [];
  const apps = new AppConnections({
    sql: sqlStorage(), secret: "test-secret-of-at-least-thirty-two-bytes", accountId: crypto.randomUUID(), google: null, fetcher, waitUntil: (p) => background.push(p), now: () => clock,
  });
  const settled = () => Promise.all(background);
  const tick = (ms: number) => { clock += ms; };
  /** The person adds an account: Axo shows a code, they enter it at OpenAI, the page polls until it lands. */
  const signIn = async (email = "ada@example.com", accountId = "acct-ada") => {
    const started = await apps.startDevice("chatgpt");
    openai.approve(started.userCode, email, accountId);
    tick(5_000);
    return apps.pollDevice("chatgpt", started.flow);
  };
  return { openai, apps, tick, signIn, settled };
}

async function refused(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (error) {
    return (error as Error).message;
  }
  assert.fail("expected a refusal");
}

test("ChatGPT is listed signing in with a code, needs no client of Axo's, and its tools all need an account", () => {
  const { apps } = fixture();
  const chatgpt = connectionSchema.parse(apps.list().find((c) => c.name === "apps.chatgpt"));
  assert.ok(chatgpt.kind === "app");
  assert.deepEqual([chatgpt.provider, chatgpt.signIn, chatgpt.state, chatgpt.tools], ["OpenAI", { kind: "device" }, "needsSignIn", ["respond", "list_models", "usage", "request"]]);
});

test("a device sign-in shows the code, asks OpenAI at most once per interval, and lands under the account's email", async () => {
  const { apps, openai, tick } = fixture();
  const started = await apps.startDevice("chatgpt");
  assert.equal(started.verificationUrl, "https://auth.openai.com/codex/device");
  assert.match(started.userCode, /^[0-9A-F]{4}-[0-9A-F]{4}$/);
  const { flow, ...shown } = started;
  assert.deepEqual(appDeviceSignInSchema.parse(shown), shown, "what the web app shows parses");
  assert.ok(flow);

  tick(5_000);
  assert.equal((await apps.pollDevice("chatgpt", started.flow)).state, "pending", "not entered yet");
  openai.approve(started.userCode, "Ada@Example.com");
  assert.equal((await apps.pollDevice("chatgpt", started.flow)).state, "pending", "polled again too soon: OpenAI is not asked");
  tick(5_000);
  assert.deepEqual(await apps.pollDevice("chatgpt", started.flow), { state: "done", account: "ada@example.com" });
  assert.deepEqual(await apps.pollDevice("chatgpt", started.flow), { state: "failed", error: "This sign-in has ended. Start again." }, "a flow lands once");
  assert.deepEqual(apps.accounts("chatgpt"), [{ account: "ada@example.com", state: "ready", lastError: null }]);

  const declined = await apps.startDevice("chatgpt");
  openai.decline(declined.userCode);
  tick(5_000);
  assert.deepEqual(await apps.pollDevice("chatgpt", declined.flow), { state: "failed", error: "OpenAI did not accept the sign-in. Start again." });
  const stale = await apps.startDevice("chatgpt");
  tick(16 * 60_000);
  assert.equal((await apps.pollDevice("chatgpt", stale.flow)).state, "failed", "a code lasts fifteen minutes");
  assert.equal((await apps.pollDevice("chatgpt", crypto.randomUUID())).state, "failed");
});

test("respond is one streamed, unstored Codex turn as the ChatGPT account, and the grant never leaves", async () => {
  const { apps, openai, signIn } = fixture();
  assert.match(await refused(apps.call("chatgpt", "list_models", { account: "ada@example.com" })), /no ChatGPT account yet; the person adds one at https:\/\/axo\.leostera\.dev\/app\/settings\/apps\/chatgpt/);
  await signIn();
  const answer = (await apps.call("chatgpt", "respond", { account: "ada@example.com", model: "gpt-5.5", input: "hello", reasoningEffort: "low" })) as Record<string, unknown>;
  assert.deepEqual(answer, { id: "resp_1", model: "gpt-5.5", status: "completed", text: "You said: hello", reasoning: "Thinking about it", usage: { input_tokens: 5, output_tokens: 4 }, truncated: false });
  const [sent] = openai.responses;
  assert.equal(sent!.headers.get("chatgpt-account-id"), "acct-ada");
  assert.equal(sent!.headers.get("accept"), "text/event-stream");
  assert.deepEqual([sent!.body.store, sent!.body.stream, sent!.body.reasoning], [false, true, { effort: "low", summary: "auto" }]);

  const turns = (await apps.call("chatgpt", "respond", { account: "ada@example.com", model: "gpt-5.5", input: [{ role: "user", content: "a" }, { role: "assistant", content: "b" }, { role: "user", content: "c" }] })) as { text: string };
  assert.equal(turns.text, "You said: c");
  assert.deepEqual((openai.responses[1]!.body.input as Array<{ content: Array<{ type: string }> }>).map((m) => m.content[0]!.type), ["input_text", "output_text", "input_text"]);
  assert.match(await refused(apps.call("chatgpt", "respond", { account: "ada@example.com", model: "nope", input: "x" })), /ChatGPT: model not supported/);

  assert.deepEqual(await apps.call("chatgpt", "list_models", { account: "ada@example.com" }), { models: [{ slug: "gpt-5.5", name: "GPT-5.5", description: "Frontier", reasoningEfforts: ["low", "high"] }] });
  assert.deepEqual(await apps.call("chatgpt", "usage", { account: "ada@example.com" }), { plan_type: "pro", rate_limit: { primary_window: { used_percent: 12 } } });
  // `request` cannot swap the ChatGPT account it acts in.
  const raw = (await apps.call("chatgpt", "request", { account: "ada@example.com", method: "GET", path: "/backend-api/wham/usage", headers: { "ChatGPT-Account-Id": "acct-eve" } })) as { json: unknown };
  assert.ok(raw.json);
  assert.equal(openai.leaks(JSON.stringify([apps.list(), apps.tools(), answer])), false);
});

test("a refresh token is spent once: an expired grant renews before the call, and a refused renewal asks for sign-in again", async () => {
  const { apps, openai, signIn, tick } = fixture();
  openai.tokenLifetime = 30; // inside the renewal margin
  await signIn();
  await apps.call("chatgpt", "usage", { account: "ada@example.com" });
  await apps.call("chatgpt", "usage", { account: "ada@example.com" });
  assert.deepEqual(apps.accounts("chatgpt"), [{ account: "ada@example.com", state: "ready", lastError: null }], "each renewal used the newest refresh token");

  openai.tokenLifetime = 3600;
  openai.expireAccessTokens();
  // The access token is refused, the grant renews once, and the call is sent again.
  assert.ok(await apps.call("chatgpt", "usage", { account: "ada@example.com" }));
  tick(1);

  const two = fixture();
  await two.signIn("grace@example.com", "acct-grace");
  await two.signIn("ada@example.com");
  assert.deepEqual(two.apps.accounts("chatgpt").map((a) => a.account), ["grace@example.com", "ada@example.com"]);
  // Spend Grace's refresh token behind Axo's back: the renewal is refused, and she signs in again.
  two.openai.expireAccessTokens();
  (two.openai as unknown as { refresh: Map<string, { spent: boolean }> }).refresh.forEach((g) => { g.spent = true; });
  assert.match(await refused(two.apps.call("chatgpt", "usage", { account: "grace@example.com" })), /grace@example\.com needs sign-in/);
  assert.deepEqual(two.apps.accounts("chatgpt")[0], { account: "grace@example.com", state: "needsSignIn", lastError: "OpenAI refused to renew the sign-in" });

  assert.equal(await two.apps.disconnect("chatgpt", "ada@example.com"), true);
  await two.settled();
  assert.equal(two.openai.revoked.length, 1, "signing out revokes the grant at OpenAI");
});
