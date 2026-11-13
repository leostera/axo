import assert from "node:assert/strict";
import { test } from "node:test";
import { accountAppSchema, type AppName } from "@axo/protocol";
import { BuiltinApps } from "../src/apps/builtin";
import type { FakeOAuth } from "./fake-oauth";
import { FakeGitHub } from "./fake-github";
import { FakeSpotify } from "./fake-spotify";
import { FakeWithings } from "./fake-withings";
import { sqlStorage } from "./sql-storage";

/**
 * RFD0016, OAuth apps of providers other than Google: each signs in with a client the person
 * registered with its provider and entered on the app's page, kept sealed in the account's
 * gateway, through the same flow as Google's. Each provider's quirks are in
 * its config: how it authenticates the token request, reads its answer, rotates refresh tokens and
 * names the account. The HTTP side of the flow (start page, cookie, callback) is Google's, tested
 * in apps.test.ts; here the flow is driven on BuiltinApps itself.
 */

type Fake = { oauth: FakeOAuth; handle(request: Request): Promise<Response | undefined> };

async function fixture<F extends Fake>(fake: F, app: AppName) {
  let clock = Date.parse("2026-10-31T12:00:00Z");
  const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(input, init);
    const answer = await fake.handle(request);
    if (!answer) throw new Error(`unexpected request to ${request.url}`);
    return answer;
  }) as typeof fetch;
  const background: Promise<unknown>[] = [];
  const apps = new BuiltinApps({
    sql: sqlStorage(), secret: "test-secret-of-at-least-thirty-two-bytes", accountId: crypto.randomUUID(),
    fetcher, waitUntil: (p) => background.push(p), now: () => clock,
  });
  const ready = apps.setClient(app, fake.oauth.clientId, fake.oauth.clientSecret);
  /** The person adds an account: Axo's link, the provider's consent page, and back to the callback. */
  const signIn = async (app: AppName, person = "ada") => {
    await ready;
    const link = new URL(await apps.signInLink(app));
    const nonce = link.searchParams.get("flow")!;
    const opened = await apps.openFlow(nonce);
    assert.ok(opened);
    fake.oauth.person = person;
    const back = fake.oauth.approve(opened.authorizeUrl);
    return apps.completeFlow(nonce, back.searchParams.get("code")!);
  };
  await ready;
  return { fake, apps, signIn, tick: (ms: number) => { clock += ms; }, settled: () => Promise.all(background) };
}

async function refused(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (error) {
    return (error as Error).message;
  }
  assert.fail("expected a refusal");
}

test("an OAuth app is listed before its provider's client is set up, with where to register one, and its tools appear once it is", async () => {
  const apps = new BuiltinApps({ sql: sqlStorage(), secret: "test-secret-of-at-least-thirty-two-bytes", accountId: crypto.randomUUID(), fetcher: fetch, waitUntil: () => undefined });
  const listed = () => accountAppSchema.parse(apps.list().find((c) => c.name === "apps.github"));
  const before = listed();
  assert.deepEqual(before.kind === "app" && before.signIn, { kind: "oauth", client: {
    provider: "github", ready: false, consoleUrl: "https://github.com/settings/developers", redirectUri: "https://axo.leostera.dev/api/v1/connections/oauth/callback",
  } });
  assert.ok(!apps.tools().some((t) => t.service === "apps.github"), "no tools until it can be used");
  assert.match(await refused(apps.call("github", "get_me", { account: "ada" })), /^GitHub is not set up yet: the person enters GitHub's OAuth client at https:\/\/axo\.leostera\.dev\/app\/settings\/apps\/github$/);
  assert.match(await refused(apps.signInLink("github")), /not set up yet/);
  assert.match(await refused(apps.setClient("github", "Iv1 abc", "secret")), /without spaces/);
  assert.match(await refused(apps.setClient("hetzner", "id", "secret")), /does not sign in with an OAuth client/);

  assert.deepEqual(await apps.setClient("github", " Ov23liAbc ", "s3cret"), { provider: "github" });
  const ready = listed();
  assert.ok(ready.kind === "app" && ready.signIn.kind === "oauth" && ready.signIn.client?.ready);
  assert.ok(apps.tools().some((t) => t.service === "apps.github"));
  assert.ok(!JSON.stringify([apps.list(), apps.tools()]).includes("s3cret"), "the secret is never shown");
  const gmail = accountAppSchema.parse(apps.list().find((c) => c.name === "apps.gmail"));
  assert.ok(gmail.kind === "app" && gmail.signIn.kind === "oauth" && gmail.signIn.client?.ready === false, "a client serves its own provider's apps only");
  assert.equal(apps.removeClient("github"), true);
  assert.ok(!apps.tools().some((t) => t.service === "apps.github"));
});

test("a replaced client is used for the next sign-in and renewal; a renewal the provider refuses then asks for sign-in", async () => {
  const { apps, fake, signIn, tick } = await fixture(new FakeGitHub(), "github");
  await signIn("github");
  await apps.setClient("github", fake.oauth.clientId, "rotated-secret");
  tick(8 * 3600_000);
  assert.match(await refused(apps.call("github", "get_me", { account: "ada" })), /needs sign-in/);
  assert.equal(fake.oauth.tokenRequests.at(-1)!.form.get("client_secret"), "rotated-secret");
  assert.deepEqual(apps.accounts("github"), [{ account: "ada", state: "needsSignIn", lastError: "GitHub refused to renew the grant" }]);
  await apps.setClient("github", fake.oauth.clientId, fake.oauth.clientSecret);
  assert.deepEqual(await signIn("github"), { name: "apps.github" });
  assert.equal(apps.accounts("github")[0]!.state, "ready");
});

test("GitHub signs in with the person's OAuth app, is named by the login, and its tools all need an account", async () => {
  const { apps, fake, signIn } = await fixture(new FakeGitHub(), "github");
  const github = accountAppSchema.parse(apps.list().find((c) => c.name === "apps.github"));
  assert.ok(github.kind === "app");
  assert.deepEqual([github.provider, github.signIn.kind, github.state], ["GitHub", "oauth", "needsSignIn"]);
  assert.deepEqual(github.tools, ["get_me", "list_repos", "search", "list_issues", "get_issue", "create_issue", "comment", "get_pull", "get_file", "list_notifications", "request"]);
  assert.ok(apps.tools().filter((t) => t.service === "apps.github").every((t) => (t.inputSchema.required as string[])[0] === "account"));
  assert.match(await refused(apps.call("github", "get_me", { account: "ada" })), /^needs sign-in: https:\/\/axo\.leostera\.dev\/api\/v1\/connections\/oauth\/start\?flow=/);

  assert.deepEqual(await signIn("github"), { name: "apps.github" });
  const asked = fake.oauth.authorizeUrls[0]!;
  assert.equal(asked.searchParams.get("scope"), "repo read:org notifications", "only what its tools use");
  assert.equal(asked.searchParams.get("prompt"), "select_account", "a second account can be picked");
  const redeemed = fake.oauth.tokenRequests[0]!;
  assert.equal(redeemed.headers.get("accept"), "application/json");
  assert.equal(redeemed.form.get("client_secret"), fake.oauth.clientSecret, "GitHub takes the client in the form");
  assert.deepEqual(apps.accounts("github"), [{ account: "ada", state: "ready", lastError: null }]);

  assert.deepEqual(await apps.call("github", "get_issue", { account: "ada", owner: "ada", repo: "engine", number: 3 }), {
    number: 3, title: "Bug", state: "open", author: "bob", pullRequest: false, labels: ["bug"], comments: [{ author: "ada", body: "On it", created: "d" }],
    created: "c", updated: "u", url: "https://github.com/ada/engine/issues/3", body: "It breaks",
  });
  assert.deepEqual(await apps.call("github", "get_file", { account: "ada", owner: "ada", repo: "engine", path: "src/main.rs" }), { path: "src/main.rs", sha: "s", size: 12, text: "fn main() {}" });
  assert.match(fake.apiCalls.at(-1)!.headers.get("user-agent") ?? "", /^Axo octokit-core/, "Octokit's own, naming Axo");
  assert.match(await refused(apps.call("github", "get_issue", { account: "ada", owner: "ada", repo: "secret", number: 1 })), /GitHub: Not Found/);
  // `request` reaches any endpoint as the named tools do, with the User-Agent GitHub requires.
  assert.deepEqual(await apps.call("github", "request", { account: "ada", method: "GET", path: "/repos/ada/engine" }), { status: 200, contentType: "application/json", json: { full_name: "ada/engine", stargazers_count: 7 }, truncated: false });
  assert.match(fake.apiCalls.at(-1)!.headers.get("user-agent") ?? "", /^Axo/);
  assert.match(await refused(apps.call("github", "request", { account: "ada", method: "GET", path: "/repos/ada/archived" })), /^GitHub: Repository access blocked$/, "an error that is not JSON still says what went wrong");
  const accountInput = (apps.tools().find((t) => t.call === "codemode.apps.github.get_me")!.inputSchema as { properties: { account: { description: string } } }).properties.account;
  assert.equal(accountInput.description, 'The account to act as: one of "ada".');
  assert.equal(fake.oauth.leaks(JSON.stringify([apps.list(), apps.tools()])), false);

  assert.deepEqual(await signIn("github", "grace"), { name: "apps.github" });
  assert.deepEqual(apps.accounts("github").map((a) => a.account), ["ada", "grace"]);
  assert.deepEqual((await apps.call("github", "list_notifications", { account: "grace" }) as { notifications: unknown[] }).notifications.length, 1);
  assert.equal(fake.apiCalls.at(-1)!.as, "grace", "each call acts as the account it names");
});

test("GitHub's eight-hour token renews before a call, spending the refresh token; a refused renewal asks for sign-in", async () => {
  const { apps, fake, signIn, tick } = await fixture(new FakeGitHub(), "github");
  await signIn("github");
  const first = fake.oauth.tokenRequests[0]!;
  assert.equal(first.form.get("grant_type"), "authorization_code");
  tick(8 * 3600_000);
  await apps.call("github", "get_me", { account: "ada" });
  const renewal = fake.oauth.tokenRequests.at(-1)!;
  assert.equal(renewal.form.get("grant_type"), "refresh_token");
  assert.equal(fake.oauth.refreshable(renewal.form.get("refresh_token")!), false, "the old refresh token is spent");
  // An access token GitHub stopped taking is renewed once, and the call sent again.
  fake.oauth.expireAccessTokens();
  assert.equal(((await apps.call("github", "get_me", { account: "ada" })) as { login: string }).login, "Ada");
  // GitHub refuses with HTTP 200 and { error }.
  fake.oauth.refuseRefresh = true;
  fake.oauth.expireAccessTokens();
  assert.match(await refused(apps.call("github", "get_me", { account: "ada" })), /needs sign-in/);
  assert.deepEqual(apps.accounts("github"), [{ account: "ada", state: "needsSignIn", lastError: "GitHub refused to renew the grant" }]);
});

test("a GitHub renewal that got no answer may have spent the refresh token: the account needs sign-in", async () => {
  const { apps, fake, signIn, tick } = await fixture(new FakeGitHub(), "github");
  await signIn("github");
  tick(8 * 3600_000);
  fake.oauth.dropNextToken = true;
  assert.match(await refused(apps.call("github", "get_me", { account: "ada" })), /needs sign-in/);
  assert.deepEqual(apps.accounts("github"), [{ account: "ada", state: "needsSignIn", lastError: "renewing the sign-in got no answer" }]);
});

test("a sign-in link opened again after it was used or expired starts a fresh sign-in to the same app", async () => {
  const { apps, fake, tick } = await fixture(new FakeGitHub(), "github");
  const nonce = new URL(await apps.signInLink("github")).searchParams.get("flow")!;
  const first = (await apps.openFlow(nonce))!;
  assert.equal(first.nonce, nonce);

  // Used: the same link leads to a new flow, and that one signs in.
  const reopened = (await apps.openFlow(nonce))!;
  assert.notEqual(reopened.nonce, nonce);
  assert.equal(reopened.name, "apps.github");
  const back = fake.oauth.approve(reopened.authorizeUrl);
  assert.deepEqual(await apps.completeFlow(reopened.nonce, back.searchParams.get("code")!), { name: "apps.github" });

  // Expired, days later: a new flow again.
  const stale = new URL(await apps.signInLink("github")).searchParams.get("flow")!;
  tick(3 * 24 * 60 * 60 * 1000);
  const late = (await apps.openFlow(stale))!;
  assert.notEqual(late.nonce, stale);
  assert.deepEqual(await apps.completeFlow(stale, "any"), { error: "this sign-in link was already used or has expired" });

  // A link the account never made is not opened.
  assert.equal(await apps.openFlow(crypto.randomUUID()), null);
});

test("a GitHub code is redeemed once, and signing out deletes Axo's authorization at GitHub", async () => {
  const { apps, fake, settled } = await fixture(new FakeGitHub(), "github");
  const link = new URL(await apps.signInLink("github"));
  const nonce = link.searchParams.get("flow")!;
  const back = fake.oauth.approve((await apps.openFlow(nonce))!.authorizeUrl);
  const code = back.searchParams.get("code")!;
  assert.deepEqual(await apps.completeFlow(nonce, code), { name: "apps.github" });
  assert.deepEqual(await apps.completeFlow(nonce, code), { error: "this sign-in link was already used or has expired" });
  // GitHub refuses a spent code with HTTP 200: the sign-in does not land.
  const again = new URL(await apps.signInLink("github")).searchParams.get("flow")!;
  await apps.openFlow(again);
  assert.deepEqual(await apps.completeFlow(again, code), { error: "GitHub did not accept the sign-in" });

  assert.equal(await apps.disconnect("github", "ada"), true);
  await settled();
  assert.equal(fake.revoked.length, 1);
  assert.equal(fake.revoked[0]!.authorization, `Basic ${btoa(`${fake.oauth.clientId}:${fake.oauth.clientSecret}`)}`);
  assert.match(fake.revoked[0]!.accessToken, /^at-/);
  assert.deepEqual(apps.accounts("github"), []);
});

test("Spotify signs in with PKCE and the client in HTTP basic, is named by its Spotify ID, and plays, searches and edits playlists", async () => {
  const { apps, fake, signIn, tick } = await fixture(new FakeSpotify(), "spotify");
  const spotify = accountAppSchema.parse(apps.list().find((c) => c.name === "apps.spotify"));
  assert.ok(spotify.kind === "app" && spotify.signIn.kind === "oauth");
  assert.deepEqual([spotify.provider, spotify.category, spotify.signIn.client?.consoleUrl], ["Spotify", "media", "https://developer.spotify.com/dashboard"]);
  assert.ok(apps.tools().filter((t) => t.service === "apps.spotify").every((t) => (t.inputSchema.required as string[])[0] === "account"));

  assert.deepEqual(await signIn("spotify", "ada.l"), { name: "apps.spotify" });
  const asked = fake.oauth.authorizeUrls[0]!;
  assert.equal(asked.searchParams.get("show_dialog"), "true", "another account can be signed in to");
  assert.ok(!asked.searchParams.get("scope")!.includes("user-read-email"), "Spotify no longer gives the email");
  assert.ok(asked.searchParams.get("scope")!.split(" ").includes("user-modify-playback-state"));
  const redeemed = fake.oauth.tokenRequests[0]!;
  assert.equal(redeemed.form.has("client_secret"), false, "the client goes in HTTP basic");
  assert.ok(redeemed.headers.get("authorization")?.startsWith("Basic "));
  assert.deepEqual(apps.accounts("spotify").map((a) => a.account), ["ada.l"]);

  const call = (tool: string, input: Record<string, unknown> = {}) => apps.call("spotify", tool, { account: "ada.l", ...input });
  assert.deepEqual(await call("get_playback"), {
    playing: true, track: { uri: "spotify:track:t1", name: "Song 1", type: "track", artists: ["Ada"], album: "Engines", durationMs: 180_000 }, progressMs: 1000,
    device: { id: "d1", name: "Kitchen", type: "Speaker", volume: 40 }, shuffle: false, repeat: "off", context: "spotify:playlist:p1",
  });
  fake.playing = false;
  assert.deepEqual(await call("get_playback"), { playing: false, track: null, device: null }, "nothing playing is an answer, not an error");
  assert.deepEqual(await call("play", { context: "spotify:playlist:p1", offset: 1, device: "d1" }), { ok: true });
  assert.deepEqual([fake.calls.at(-1)!.query.get("device_id"), JSON.parse(fake.calls.at(-1)!.body)], ["d1", { context_uri: "spotify:playlist:p1", offset: { position: 1 } }]);
  assert.deepEqual(await call("set_volume", { percent: 30 }), { ok: true });
  assert.equal(fake.calls.at(-1)!.query.get("volume_percent"), "30");
  assert.deepEqual(await call("transfer_playback", { device: "d1", play: true }), { ok: true });
  assert.deepEqual(JSON.parse(fake.calls.at(-1)!.body), { device_ids: ["d1"], play: true });

  assert.deepEqual(await call("search", { query: "artist:Ada", types: ["track"] }), { tracks: { items: [{ uri: "spotify:track:t2", name: "Song 2", type: "track", artists: ["Ada"], album: "Engines", durationMs: 180_000 }], total: 1, more: false } });
  assert.match(await refused(call("search", { query: "x", limit: 20 })), /invalid input/, "Spotify allows at most 10");
  const mine = await call("get_playlist", { id: "p1" }) as { name: string; trackCount: number; tracks: { items: Array<{ uri: string; addedAt: string }> } };
  assert.deepEqual([mine.name, mine.trackCount, mine.tracks.items.map((t) => t.uri)], ["Mine", 2, ["spotify:track:t1", "spotify:track:t3"]], "the playlist's items, as Spotify now names them");
  assert.deepEqual(await call("add_to_playlist", { id: "p1", uris: ["spotify:track:t9"] }), { snapshotId: "snap2" });
  assert.equal(fake.calls.at(-1)!.call, "POST /v1/playlists/p1/items");
  assert.deepEqual(await call("create_playlist", { name: "Focus" }), { id: "p2", uri: "spotify:playlist:p2", name: "Focus", url: "https://open.spotify.com/playlist/p2" });
  assert.deepEqual(JSON.parse(fake.calls.at(-1)!.body), { name: "Focus", public: false, collaborative: false }, "private unless asked");
  assert.deepEqual(await call("save_to_library", { uris: ["spotify:track:t1", "spotify:album:a1"] }), { ok: true });
  assert.deepEqual([fake.calls.at(-1)!.call, fake.calls.at(-1)!.query.get("uris")], ["PUT /v1/me/library", "spotify:track:t1,spotify:album:a1"]);
  assert.deepEqual(await call("top_items", { type: "artists", timeRange: "short_term" }), { items: [{ uri: "spotify:artist:a1", name: "Ada", genres: ["synth"] }], total: 1, more: true });
  assert.equal(fake.calls.at(-1)!.query.get("time_range"), "short_term");
  assert.match(await refused(call("request", { method: "GET", path: "https://accounts.spotify.com/api/token" })), /only reach api\.spotify\.com/);

  // A renewal spends the refresh token, and keeps the new one.
  tick(3600_000);
  await call("list_devices");
  const renewal = fake.oauth.tokenRequests.at(-1)!;
  assert.equal(renewal.form.get("grant_type"), "refresh_token");
  assert.equal(fake.oauth.refreshable(renewal.form.get("refresh_token")!), false);
  tick(3600_000);
  assert.deepEqual((await call("list_devices") as { devices: unknown[] }).devices.length, 1, "the rotated refresh token renews again");
});

test("Withings signs in without PKCE through its requesttoken action, is named by its user ID, and reads measures, activity, sleep and ECGs", async () => {
  const { apps, fake, signIn, tick } = await fixture(new FakeWithings(), "withings");
  const withings = accountAppSchema.parse(apps.list().find((c) => c.name === "apps.withings"));
  assert.ok(withings.kind === "app");
  assert.deepEqual([withings.provider, withings.category], ["Withings", "health"]);
  assert.deepEqual(await signIn("withings"), { name: "apps.withings" });
  assert.equal(fake.oauth.authorizeUrls[0]!.searchParams.get("scope"), "user.info,user.metrics,user.activity");
  assert.equal(fake.oauth.tokenRequests[0]!.form.get("action"), "requesttoken");
  assert.deepEqual(apps.accounts("withings").map((a) => a.account), ["31337001"]);

  const call = (tool: string, input: Record<string, unknown> = {}) => apps.call("withings", tool, { account: "31337001", ...input });
  assert.deepEqual(await call("get_measures", { types: ["weight", "fat_ratio", "systolic"], start: "2026-10-01" }), {
    measures: [
      { date: "2026-10-26T07:33:20.000Z", type: "weight", value: 72.35, unit: "kg", device: "scale1" },
      { date: "2026-10-26T07:33:20.000Z", type: "fat_ratio", value: 21.5, unit: "%", device: "scale1" },
      { date: "2026-10-25T03:46:40.000Z", type: "systolic", value: 121, unit: "mmHg", device: "bpm1" },
      { date: "2026-10-25T03:46:40.000Z", type: "diastolic", value: 79, unit: "mmHg", device: "bpm1" },
      { date: "2026-10-25T03:46:40.000Z", type: "heart_rate", value: 64, unit: "bpm", device: "bpm1" },
    ],
    more: false, offset: 0,
  });
  const measured = fake.calls.at(-1)!;
  assert.deepEqual([measured.path, measured.form.get("meastypes"), measured.form.get("startdate")], ["/measure", "1,6,10", String(Date.parse("2026-10-01T00:00:00Z") / 1000)]);
  assert.equal(((await call("get_activity", { start: "2026-10-30", end: "2026-10-30" })) as { days: Array<{ steps: number }> }).days[0]!.steps, 9120);
  assert.equal(((await call("get_sleep_summary", { start: "2026-10-30", end: "2026-10-31" })) as { nights: Array<{ data: { sleep_score: number } }> }).nights[0]!.data.sleep_score, 81);
  assert.deepEqual(await call("list_ecgs"), { ecgs: [{ id: 77, date: "2026-10-26T07:33:20.000Z", afib: 0, heartRate: 62, device: "watch1" }], more: false, offset: 0 });
  assert.deepEqual(((await call("list_devices")) as { devices: Array<{ model: string }> }).devices.map((d) => d.model), ["Body+"]);

  // Withings answers errors with HTTP 200: a status other than 0 fails the call, request included.
  assert.match(await refused(call("request", { method: "POST", path: "/v2/measure", text: { contentType: "application/x-www-form-urlencoded", data: "action=nope" } })), /^Withings: An unknown error occurred \(status 2555\)$/);
  // Its 401 is a token it no longer takes: renewed once (the refresh token rotates) and sent again.
  fake.oauth.expireAccessTokens();
  assert.equal(((await call("list_devices")) as { devices: unknown[] }).devices.length, 1);
  assert.equal(fake.oauth.tokenRequests.at(-1)!.form.get("grant_type"), "refresh_token");
  assert.equal(fake.oauth.tokenRequests.at(-1)!.form.get("action"), "requesttoken");
  fake.oauth.refuseRefresh = true;
  tick(3 * 3600_000);
  assert.match(await refused(call("list_devices")), /needs sign-in/);
  assert.deepEqual(apps.accounts("withings")[0]!.lastError, "Withings refused to renew the grant");
});
