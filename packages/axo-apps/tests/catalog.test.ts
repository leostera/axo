import assert from "node:assert/strict";
import { test } from "node:test";
import { APPS } from "@axo/protocol";
import { allowedUrl, APP_DEFINITIONS, authorizationUrl, GrantRefused, OAUTH_PROVIDER_CONFIGS, OAUTH_PROVIDERS, redeemCode, refreshGrant, toolsOf } from "../src/index";

/**
 * What every app in the catalog promises, whatever its service: the gateway relies on these to
 * list, call and sign in to an app without knowing which one it is.
 */

const CALLBACK = "https://axo.example/callback";

test("every app in the protocol has a definition named after it, and every tool a unique snake_case name", () => {
  assert.deepEqual(Object.keys(APP_DEFINITIONS).sort(), [...APPS].sort());
  for (const app of APPS) {
    const definition = APP_DEFINITIONS[app];
    assert.equal(definition.name, app);
    const names = toolsOf(app).map((t) => t.name);
    assert.equal(new Set(names).size, names.length, `${app}'s tools have unique names`);
    for (const name of names) assert.match(name, /^[a-z][a-z0-9_]*$/, `${app}.${name}`);
    assert.ok(definition.permissions.length > 0, `${app} says what it lets Axo do`);
    assert.ok(!toolsOf(app).some((t) => "account" in t.input.shape), `${app}: \`account\` is added by the gateway, not by a tool`);
  }
});

test("an HTTP app's credential only goes to its own hosts, over https", () => {
  for (const app of APPS) {
    const definition = APP_DEFINITIONS[app];
    if (definition.signIn === "mac" || definition.signIn === "phone") continue;
    assert.ok(allowedUrl(definition, new URL(definition.apiOrigin)), `${app}'s API origin is one of its hosts`);
    assert.equal(allowedUrl(definition, new URL("https://evil.example/")), false);
    assert.equal(allowedUrl(definition, new URL(definition.apiOrigin.replace("https:", "http:"))), false);
  }
});

test("an OAuth app signs in with a known provider, and needs only scopes it asks for", () => {
  for (const app of APPS) {
    const definition = APP_DEFINITIONS[app];
    if (definition.signIn !== "oauth") continue;
    assert.ok(OAUTH_PROVIDERS.includes(definition.provider), `${app}'s provider`);
    assert.ok(definition.scopes.length > 0);
    for (const scope of definition.requiredScopes) assert.ok(definition.scopes.includes(scope), `${app} asks for ${scope}`);
  }
  for (const name of OAUTH_PROVIDERS) {
    const provider = OAUTH_PROVIDER_CONFIGS[name];
    assert.equal(provider.name, name);
    for (const url of [provider.authorizeUrl, provider.tokenUrl, provider.consoleUrl]) assert.match(url, /^https:\/\//);
  }
});

test("the authorize URL carries the provider's own parameters, and PKCE only where the provider takes it", () => {
  const github = new URL(authorizationUrl(OAUTH_PROVIDER_CONFIGS.github, { clientId: "id", clientSecret: "s" }, ["repo", "read:org"], "challenge", "state", CALLBACK));
  assert.deepEqual(Object.fromEntries(github.searchParams), {
    response_type: "code", client_id: "id", redirect_uri: CALLBACK, scope: "repo read:org", prompt: "select_account", code_challenge: "challenge", code_challenge_method: "S256", state: "state",
  });
});

test("a token answer that is a refusal in disguise (HTTP 200 with { error }) is refused; a renewal keeps what its answer leaves out", async () => {
  let answer: unknown = { access_token: "a1", token_type: "bearer", refresh_token: "r1", expires_in: 60, scope: "repo,read:org" };
  const forms: URLSearchParams[] = [];
  const fetcher = (async (_url: string, init: RequestInit) => {
    forms.push(new URLSearchParams(init.body as URLSearchParams));
    return new Response(JSON.stringify(answer), { status: 200 });
  }) as unknown as typeof fetch;
  const client = { clientId: "id", clientSecret: "secret" };
  const grant = await redeemCode(OAUTH_PROVIDER_CONFIGS.github, client, "code", "verifier", CALLBACK, fetcher, 1000);
  assert.deepEqual(grant, { provider: "github", accessToken: "a1", refreshToken: "r1", expiresAt: 61_000, scopes: ["repo", "read:org"], email: null, userId: null });
  assert.equal(forms[0]!.get("code_verifier"), "verifier");
  answer = { access_token: "a2", token_type: "bearer", expires_in: 60, scope: "" };
  assert.deepEqual(await refreshGrant(OAUTH_PROVIDER_CONFIGS.github, client, grant, fetcher, 2000), { ...grant, accessToken: "a2", expiresAt: 62_000 });
  answer = { error: "bad_refresh_token" };
  await assert.rejects(refreshGrant(OAUTH_PROVIDER_CONFIGS.github, client, grant, fetcher, 3000), GrantRefused);
});

test("Withings: commas between scopes, no PKCE, `action=requesttoken`, and an answer wrapped in { status, body }", async () => {
  const url = new URL(authorizationUrl(OAUTH_PROVIDER_CONFIGS.withings, { clientId: "id", clientSecret: "s" }, ["user.info", "user.metrics"], "challenge", "state", CALLBACK));
  assert.equal(url.searchParams.get("scope"), "user.info,user.metrics");
  assert.equal(url.searchParams.has("code_challenge"), false);
  let answer: unknown = { status: 0, body: { userid: 1234567, access_token: "a", refresh_token: "r", expires_in: 10800, scope: "user.info,user.metrics", token_type: "Bearer" } };
  const forms: URLSearchParams[] = [];
  const fetcher = (async (_url: string, init: RequestInit) => {
    forms.push(new URLSearchParams(init.body as URLSearchParams));
    return new Response(JSON.stringify(answer), { status: 200 });
  }) as unknown as typeof fetch;
  const grant = await redeemCode(OAUTH_PROVIDER_CONFIGS.withings, { clientId: "id", clientSecret: "s" }, "code", "verifier", CALLBACK, fetcher, 0);
  assert.deepEqual([grant.userId, grant.scopes, grant.expiresAt], ["1234567", ["user.info", "user.metrics"], 10_800_000]);
  assert.deepEqual(Object.fromEntries(forms[0]!), { action: "requesttoken", grant_type: "authorization_code", code: "code", redirect_uri: CALLBACK, client_id: "id", client_secret: "s" });
  answer = { status: 503, error: "Invalid params" };
  await assert.rejects(refreshGrant(OAUTH_PROVIDER_CONFIGS.withings, { clientId: "id", clientSecret: "s" }, grant, fetcher, 0), GrantRefused);
  assert.deepEqual(APP_DEFINITIONS.withings.signIn === "oauth" && APP_DEFINITIONS.withings.answerError?.({ status: 401 }), { unauthorized: true });
  assert.equal(APP_DEFINITIONS.withings.signIn === "oauth" && APP_DEFINITIONS.withings.answerError?.({ status: 0, body: {} }), null);
});
