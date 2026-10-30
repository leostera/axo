import { call, defineSpec, message } from "@leostera/feynman";

const MIN = 60 * 1_000;

// RFD0016: how an account gets and keeps a grant for a third-party connection. An agent adds the
// connection; the account's Durable Object registers itself with the service's authorization server,
// or waits for a client typed on the Connections page; the person signs in through Axo's one
// callback; the Durable Object keeps the grant and refreshes it.
//
// Not built yet, so no step has sources. Left out: the relay between the agent and the cloud
// (connections.ts models it; here the Session talks to the account directly), expiry of links,
// flows and cookies (an expired one is refused like a mismatched one), discovery (one known
// authorization server), and scopes. Replies name the request they answer: in the code that is the
// awaiting call's own context.

type Conn = {
  status: "needs client" | "needs sign-in" | "ready";
  client: string | null;
  secret: string | null;
  grant: null | { refresh: string; upstream: string; generation: number };
  generation: number;
};
type Ref = { account: string; name: string };

const who = (account: string) => account.replace(/^acct-/, "");
const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
/** Each person has one Axo account and one account at the service, both named after them. */
const accountOf = (person: string) => `acct-${person.toLowerCase()}`;
/** The sealed `state` carries its flow and the hash of the nonce in the browser's flow cookie. */
const sealState = (flow: string, nonceHash: string) => `sealed-state/${flow}/${nonceHash}`;
const unsealState = (state: string) => {
  const [tag, flow, nonceHash] = state.split("/");
  return tag === "sealed-state" && flow && nonceHash ? { flow, nonceHash: nonceHash } : null;
};

export default defineSpec(
  "Connection sign-in",
  {
    description:
      "How an Axo account gets and keeps a grant for a third-party MCP server: an agent adds the connection, Axo registers as an OAuth client or takes one typed on the Connections page, the person signs in through Axo's one callback, and the account's Durable Object refreshes the grant.",
    messages: {
      // Session agent -> AxoAccountManager (over the relay, see connections.ts)
      Add: message<Ref>({ name: "connections_add", over: "relay" }),
      Link: message<{ name: string; link: string }>({ name: "sign-in link", over: "relay", tone: "reply" }),
      NeedsClient: message<{ name: string }>({ name: "enter a client on the Connections page", over: "relay", tone: "reply" }),
      NameTaken: message<{ name: string }>({ name: "a connection with this name exists", over: "relay", tone: "refused" }),
      // Person's browser <-> Worker
      EnterClient: message<Ref & { client: string; secret: string }>({ name: "POST …/connections/:name/client", over: "https" }),
      ClientSaved: message<{ name: string; link: string }>({ name: "client saved, sign-in link", over: "https", tone: "reply" }),
      Start: message<{ account: string; link: string }>({ name: "GET …/connections/oauth/start", over: "https" }),
      ToAuthorize: message<{ state: string; nonce: string; client: string }>({ name: "302 to the consent page, flow cookie set", over: "https", tone: "reply" }),
      Callback: message<{ state: string; code: string; cookie: string | null }>({ name: "GET /api/v1/connections/oauth/callback", over: "https" }),
      Connected: message<{ name: string }>({ name: "signing in", over: "https", tone: "reply" }),
      Refused: message<{ reason: string }>({ name: "400 sign-in refused", over: "https", tone: "refused" }),
      // Person's browser <-> the service
      Consent: message<{ state: string; client: string; upstream: string }>({ name: "approve Axo at the service", over: "https" }),
      ToCallback: message<{ state: string; code: string }>({ name: "302 to Axo's callback", over: "https", tone: "reply" }),
      // Worker <-> AxoAccountManager
      SaveClient: call<Ref & { client: string; secret: string; browser: string }>({ name: "saveClient", over: "rpc" }),
      Saved: message<{ name: string; link: string; browser: string }>({ name: "saved", over: "rpc", tone: "reply" }),
      Begin: call<{ account: string; link: string; browser: string }>({ name: "beginSignIn", over: "rpc" }),
      Begun: message<{ state: string; nonce: string; client: string; browser: string }>({ name: "flow begun", over: "rpc", tone: "reply" }),
      NoSuchLink: message<{ browser: string }>({ name: "link unknown, used, or another account's", over: "rpc", tone: "refused" }),
      Complete: call<{ flow: string; code: string; browser: string }>({ name: "completeSignIn", over: "rpc" }),
      Completed: message<{ name: string; browser: string }>({ name: "redeeming the code", over: "rpc", tone: "reply" }),
      NotCompleted: message<{ browser: string }>({ name: "sign-in unknown or used", over: "rpc", tone: "refused" }),
      // AxoAccountManager <-> the service's authorization server
      Register: call<Ref>({ name: "POST /register", over: "https" }),
      Registered: message<Ref & { client: string }>({ name: "201 client registered", over: "https", tone: "reply" }),
      NoRegistration: message<Ref>({ name: "registration not supported", over: "https", tone: "refused" }),
      Token: call<Ref & { code: string; client: string; verifier: string }>({ name: "POST /token (code)", over: "https" }),
      Tokens: message<Ref & { refresh: string; upstream: string }>({ name: "tokens", over: "https", tone: "reply" }),
      CodeRejected: message<Ref>({ name: "invalid_grant (code)", over: "https", tone: "refused" }),
      Refresh: call<Ref & { refresh: string; client: string; generation: number }>({ name: "POST /token (refresh)", over: "https" }),
      Refreshed: message<Ref & { refresh: string; generation: number }>({ name: "refreshed tokens", over: "https", tone: "reply" }),
      RefreshRejected: message<Ref & { generation: number }>({ name: "invalid_grant (refresh)", over: "https", tone: "refused" }),
    },
  },
  (spec) => {
    const {
      Add, Link, NeedsClient, NameTaken, EnterClient, ClientSaved, Start, ToAuthorize, Callback, Connected, Refused, Consent, ToCallback,
      SaveClient, Saved, Begin, Begun, NoSuchLink, Complete, Completed, NotCompleted, Register, Registered, NoRegistration, Token, Tokens,
      CodeRejected, Refresh, Refreshed, RefreshRejected,
    } = spec.messages;

    const people = spec.defineZone({ name: "People", description: "an agent in a Session, and a browser" });
    const cloudflare = spec.defineZone({ name: "Cloudflare", description: "the Axo Worker and the account's Durable Object", place: { column: 1, region: true } });
    const service = spec.defineZone({ name: "Third-party service", description: "its OAuth authorization server", place: { column: 2 } });

    spec.defineLimit({ name: "A sign-in link stays usable for", value: 30 * MIN });
    spec.defineLimit({ name: "The Durable Object refreshes a grant this long before it expires", value: 5 * MIN });

    const Manager = spec.defineActor({
      name: "AxoAccountManager",
      description: "The account's Durable Object: it holds connections, OAuth clients and grants, and runs each sign-in.",
      zone: cloudflare,
      singleton: true,
      initialState: () => ({
        conns: {} as Record<string, Record<string, Conn>>,
        /** Agents waiting to hear how registration went, by connection. */
        adding: {} as Record<string, string>,
        /** Sign-in links not yet opened, by hash. */
        links: {} as Record<string, Ref>,
        /** Sign-ins waiting for their callback, by flow. */
        flows: {} as Record<string, Ref & { verifier: string }>,
      }),
      durable: ["conns", "links", "flows"],
      display: {
        icon: "cloud",
        status: (s) => `${Object.values(s.conns).flatMap((c) => Object.values(c)).filter((c) => c.status === "ready").length} connection(s) ready`,
        rows: (s) =>
          Object.entries(s.conns).flatMap(([account, cs]) =>
            Object.entries(cs).map(([name, c]) => ({
              group: `${cap(who(account))}'s connections`,
              owner: cap(who(account)),
              label: name,
              detail: c.grant ? `${c.status}, grant for ${c.grant.upstream} at the service` : c.status,
              mood: c.status === "ready" ? ("ok" as const) : ("warn" as const),
            })),
          ),
      },
      transitions: {
        [Add]: {
          description: "Records the connection and asks the service to register Axo as an OAuth client.",
          sends: [Register, NameTaken],
          say: (_s, m) => `${cap(who(m.account))} adds ${m.name}; registering Axo with the service`,
          run(state, m, ctx) {
            const mine = (state.conns[m.account] ??= {});
            if (mine[m.name]) return ctx.reply(NameTaken, { name: m.name });
            mine[m.name] = { status: "needs client", client: null, secret: null, grant: null, generation: 0 };
            state.adding[`${m.account}/${m.name}`] = ctx.from.id;
            ctx.send(ctx.the(AuthServer), Register, { account: m.account, name: m.name });
          },
        },
        [Registered]: {
          description: "Keeps the registered client and gives the agent a sign-in link to hand to the person.",
          sends: [Link],
          run(state, m, ctx) {
            const conn = state.conns[m.account]?.[m.name];
            const agent = ctx.all(Session).find((x) => x.id === state.adding[`${m.account}/${m.name}`]);
            delete state.adding[`${m.account}/${m.name}`];
            if (!conn) return;
            conn.client = m.client;
            conn.status = "needs sign-in";
            const link = ctx.fresh("link");
            state.links[ctx.hash(link)] = { account: m.account, name: m.name };
            if (agent) ctx.send(agent, Link, { name: m.name, link });
          },
        },
        [NoRegistration]: {
          description: "The service does not register clients; the connection waits for one typed on the Connections page.",
          sends: [NeedsClient],
          run(state, m, ctx) {
            const agent = ctx.all(Session).find((x) => x.id === state.adding[`${m.account}/${m.name}`]);
            delete state.adding[`${m.account}/${m.name}`];
            if (agent) ctx.send(agent, NeedsClient, { name: m.name });
          },
        },
        [spec.failed(Register)]: {
          description: "Registration did not answer; the connection waits for a client typed on the Connections page.",
          sends: [NeedsClient],
          run(state, f, ctx) {
            const key = `${f.payload.account}/${f.payload.name}`;
            const agent = ctx.all(Session).find((x) => x.id === state.adding[key]);
            delete state.adding[key];
            if (agent) ctx.send(agent, NeedsClient, { name: f.payload.name });
          },
        },
        [SaveClient]: {
          description: "Seals and keeps the typed client, and returns a sign-in link; the secret is never sent back.",
          sends: [Saved],
          run(state, m, ctx) {
            const conn = state.conns[m.account]?.[m.name];
            if (!conn) return;
            conn.client = m.client;
            conn.secret = `sealed:${ctx.hash(m.secret)}`;
            if (!conn.grant) conn.status = "needs sign-in";
            const link = ctx.fresh("link");
            state.links[ctx.hash(link)] = { account: m.account, name: m.name };
            ctx.reply(Saved, { name: m.name, link, browser: m.browser });
          },
        },
        [Begin]: {
          description: "Uses up the link and starts a flow: a PKCE verifier kept here, and a nonce for the browser's flow cookie.",
          sends: [Begun, NoSuchLink],
          run(state, m, ctx) {
            const entry = state.links[ctx.hash(m.link)];
            const conn = entry ? state.conns[entry.account]?.[entry.name] : undefined;
            if (!entry || entry.account !== m.account || !conn?.client) return ctx.reply(NoSuchLink, { browser: m.browser });
            delete state.links[ctx.hash(m.link)];
            const flow = ctx.fresh("flow");
            const nonce = ctx.fresh("nonce");
            state.flows[flow] = { ...entry, verifier: ctx.fresh("verifier") };
            ctx.reply(Begun, { state: sealState(flow, ctx.hash(nonce)), nonce, client: conn.client, browser: m.browser });
          },
        },
        [Complete]: {
          description: "Ends the flow and redeems the code with its PKCE verifier.",
          sends: [Token, Completed, NotCompleted],
          run(state, m, ctx) {
            const flow = state.flows[m.flow];
            const conn = flow ? state.conns[flow.account]?.[flow.name] : undefined;
            if (!flow || !conn?.client) return ctx.reply(NotCompleted, { browser: m.browser });
            delete state.flows[m.flow];
            ctx.send(ctx.the(AuthServer), Token, { account: flow.account, name: flow.name, code: m.code, client: conn.client, verifier: flow.verifier });
            ctx.reply(Completed, { name: flow.name, browser: m.browser });
          },
        },
        [Tokens]: {
          description: "Stores the grant on the connection that started this flow, and schedules its refresh.",
          starts: ["refreshDue"],
          say: (_s, m) => `${m.name} is ready for ${cap(who(m.account))}, with ${m.upstream}'s grant`,
          run(state, m, ctx) {
            const conn = state.conns[m.account]?.[m.name];
            if (!conn) return;
            conn.generation += 1;
            conn.grant = { refresh: m.refresh, upstream: m.upstream, generation: conn.generation };
            conn.status = "ready";
            ctx.start("refreshDue");
          },
        },
        [CodeRejected]: {
          description: "The service refused the code; the person signs in again.",
          run: () => {},
        },
        [spec.failed(Token)]: {
          description: "Redeeming the code failed or its answer was lost; the code is spent, so the person signs in again.",
          run: () => {},
        },
        refreshDue: {
          description: "A grant nears expiry; the Durable Object refreshes it.",
          after: "5 minutes before the access token expires",
          sends: [Refresh],
          run(state, ctx) {
            for (const [account, cs] of Object.entries(state.conns))
              for (const [name, c] of Object.entries(cs))
                if (c.status === "ready" && c.grant && c.client) {
                  c.status = "needs sign-in"; // no call uses a grant while it is being refreshed
                  ctx.send(ctx.the(AuthServer), Refresh, { account, name, refresh: c.grant.refresh, client: c.client, generation: c.grant.generation });
                }
          },
        },
        [Refreshed]: {
          description: "Keeps the rotated refresh token, if it is for the grant the connection still holds; the connection is ready again.",
          starts: ["refreshDue"],
          run(state, m, ctx) {
            const conn = state.conns[m.account]?.[m.name];
            if (!conn?.grant || conn.grant.generation !== m.generation) return;
            conn.grant.refresh = m.refresh;
            conn.status = "ready";
            ctx.start("refreshDue");
          },
        },
        [RefreshRejected]: {
          description: "The service refused the refresh; if the connection still holds that grant, it is dropped and the connection needs sign-in.",
          run(state, m) {
            const conn = state.conns[m.account]?.[m.name];
            if (!conn?.grant || conn.grant.generation !== m.generation) return;
            conn.grant = null;
            conn.status = "needs sign-in";
          },
        },
        [spec.failed(Refresh)]: {
          description: "The refresh did not answer; the old refresh token may be spent, so if the connection still holds that grant it is dropped and the connection needs sign-in.",
          run(state, f) {
            const conn = state.conns[f.payload.account]?.[f.payload.name];
            if (!conn?.grant || conn.grant.generation !== f.payload.generation) return;
            conn.grant = null;
            conn.status = "needs sign-in";
          },
        },
      },
    });

    const Worker = spec.defineActor({
      name: "Worker",
      description: "The Axo API Worker: it serves the Connections page and the one OAuth callback, and checks the flow cookie.",
      zone: cloudflare,
      singleton: true,
      initialState: () => ({}),
      display: { icon: "server", status: () => "stateless" },
      transitions: {
        [EnterClient]: {
          description: "Passes the typed client to the account.",
          sends: [SaveClient],
          run: (_s, m, ctx) => ctx.send(ctx.the(Manager), SaveClient, { ...m, browser: ctx.from.id }),
        },
        [Saved]: {
          description: "Shows the sign-in link on the Connections page.",
          sends: [ClientSaved],
          run(_s, m, ctx) {
            const browser = ctx.all(Browser).find((b) => b.id === m.browser);
            if (browser) ctx.send(browser, ClientSaved, { name: m.name, link: m.link });
          },
        },
        [spec.failed(SaveClient)]: { description: "Saving failed; the page asks the person to try again.", run: () => {} },
        [Start]: {
          description: "Opens a sign-in for the signed-in account.",
          sends: [Begin],
          run: (_s, m, ctx) => ctx.send(ctx.the(Manager), Begin, { account: m.account, link: m.link, browser: ctx.from.id }),
        },
        [Begun]: {
          description: "Sets the flow cookie and sends the browser to the service's consent page.",
          sends: [ToAuthorize],
          run(_s, m, ctx) {
            const browser = ctx.all(Browser).find((b) => b.id === m.browser);
            if (browser) ctx.send(browser, ToAuthorize, { state: m.state, nonce: m.nonce, client: m.client });
          },
        },
        [NoSuchLink]: {
          description: "The link is unknown, used, or another account's.",
          sends: [Refused],
          run(_s, m, ctx) {
            const browser = ctx.all(Browser).find((b) => b.id === m.browser);
            if (browser) ctx.send(browser, Refused, { reason: "this sign-in link is not yours or was used" });
          },
        },
        [spec.failed(Begin)]: { description: "The account did not answer; the page asks the person to open the link again.", run: () => {} },
        [Callback]: {
          description: "Unseals the state and checks that this browser's flow cookie started it, before the account redeems the code.",
          sends: [Complete, Refused],
          run(_s, m, ctx) {
            const sealed = unsealState(m.state);
            if (!sealed) return ctx.reply(Refused, { reason: "unreadable state" });
            if (!m.cookie || ctx.hash(m.cookie) !== sealed.nonceHash) return ctx.reply(Refused, { reason: "this browser did not start this sign-in" });
            ctx.send(ctx.the(Manager), Complete, { flow: sealed.flow, code: m.code, browser: ctx.from.id });
          },
        },
        [Completed]: {
          description: "Tells the person the connection is being signed in.",
          sends: [Connected],
          run(_s, m, ctx) {
            const browser = ctx.all(Browser).find((b) => b.id === m.browser);
            if (browser) ctx.send(browser, Connected, { name: m.name });
          },
        },
        [NotCompleted]: {
          description: "The sign-in was unknown or used.",
          sends: [Refused],
          run(_s, m, ctx) {
            const browser = ctx.all(Browser).find((b) => b.id === m.browser);
            if (browser) ctx.send(browser, Refused, { reason: "this sign-in is unknown or was used" });
          },
        },
        [spec.failed(Complete)]: { description: "The account did not answer; the page asks the person to sign in again.", run: () => {} },
      },
    });

    const AuthServer = spec.defineActor({
      name: "Service sign-in",
      description: "The third-party service's OAuth authorization server. Each person has their own account there.",
      zone: service,
      singleton: true,
      initialState: () => ({
        dcr: true,
        codes: {} as Record<string, { client: string; upstream: string; used: boolean }>,
        refreshes: {} as Record<string, { upstream: string; revoked: boolean }>,
      }),
      durable: ["codes", "refreshes"],
      display: { icon: "key", status: (s) => (s.dcr ? "registers clients" : "needs a client registered by hand") },
      actions: {
        revoke: {
          label: "Revoke Axo's access",
          description: "A person revokes Axo's access at the service.",
          when: (s) => Object.values(s.refreshes).some((r) => !r.revoked),
          run(state) {
            for (const r of Object.values(state.refreshes)) r.revoked = true;
          },
        },
      },
      transitions: {
        [Register]: {
          description: "Registers Axo as a client, if this service supports it.",
          sends: [Registered, NoRegistration],
          run(state, m, ctx) {
            if (!state.dcr) return ctx.reply(NoRegistration, m);
            ctx.reply(Registered, { ...m, client: ctx.fresh("client") });
          },
        },
        [Consent]: {
          description: "The person approves Axo with their own account at the service; a one-time code goes back with the state.",
          sends: [ToCallback],
          run(state, m, ctx) {
            const code = ctx.fresh("code");
            state.codes[code] = { client: m.client, upstream: m.upstream, used: false };
            ctx.reply(ToCallback, { state: m.state, code });
          },
        },
        [Token]: {
          description: "Redeems a code once, for the client it was issued to.",
          sends: [Tokens, CodeRejected],
          run(state, m, ctx) {
            const code = state.codes[m.code];
            if (!code || code.used || code.client !== m.client) return ctx.reply(CodeRejected, { account: m.account, name: m.name });
            code.used = true;
            const refresh = ctx.fresh("tok-refresh");
            state.refreshes[refresh] = { upstream: code.upstream, revoked: false };
            ctx.reply(Tokens, { account: m.account, name: m.name, refresh, upstream: code.upstream });
          },
        },
        [Refresh]: {
          description: "Rotates a refresh token unless access was revoked.",
          sends: [Refreshed, RefreshRejected],
          run(state, m, ctx) {
            const r = state.refreshes[m.refresh];
            if (!r || r.revoked) return ctx.reply(RefreshRejected, { account: m.account, name: m.name, generation: m.generation });
            delete state.refreshes[m.refresh];
            const refresh = ctx.fresh("tok-refresh");
            state.refreshes[refresh] = { upstream: r.upstream, revoked: false };
            ctx.reply(Refreshed, { account: m.account, name: m.name, refresh, generation: m.generation });
          },
        },
      },
    });

    const Session = spec.defineActor({
      name: "Session",
      description: "An agent in one of the person's Axo Sessions.",
      zone: people,
      initialState: (ctx) => ({ account: accountOf(ctx.label.replace(/'s session$/, "")), links: [] as string[], heard: [] as string[] }),
      display: {
        icon: "robot",
        names: ["Alice's session", "Mallory's session"],
        status: (s) => s.heard.at(-1) ?? "idle",
        owner: (s) => cap(who(s.account)),
        tokens: (s) => s.links.slice(-1).map((link) => ({ kind: "sign-in link", value: link })),
      },
      actions: {
        add: {
          label: "Add Linear",
          description: "The agent adds a third-party connection mid-task.",
          sends: [Add],
          run: (state, _i, ctx) => ctx.send(ctx.the(Manager), Add, { account: state.account, name: "linear" }),
        },
      },
      transitions: {
        [Link]: { description: "Gives the person the sign-in link.", run: (s, m) => void (s.links.push(m.link), s.heard.push("sign-in link ready")) },
        [NeedsClient]: { description: "Tells the person to enter a client on the Connections page.", run: (s) => void s.heard.push("needs a client") },
        [NameTaken]: { description: "Tells the person the name is taken.", run: (s) => void s.heard.push("name taken") },
      },
    });

    const Browser = spec.defineActor({
      name: "Browser",
      description: "A person's browser, signed in to Axo as them and to the service as them.",
      zone: people,
      initialState: (ctx) => ({
        person: ctx.label.replace(/'s browser$/, ""),
        account: accountOf(ctx.label.replace(/'s browser$/, "")),
        cookie: null as string | null,
        consent: null as null | { state: string; client: string },
        callbacks: [] as string[],
        pageLinks: [] as string[],
        result: null as string | null,
      }),
      display: {
        icon: "browser",
        names: ["Alice's browser", "Mallory's browser"],
        status: (s) => s.result ?? (s.consent ? "on the consent page" : "idle"),
        owner: (s) => s.person,
        tokens: (s) => [
          ...(s.consent ? [{ kind: "consent page", value: `${s.consent.state}|${s.consent.client}` }] : []),
          ...s.callbacks.map((c) => ({ kind: "callback link", value: c })),
        ],
      },
      actions: {
        enterClient: {
          label: "Enter a client",
          description: "On the Connections page, the person types a client they registered with the service.",
          sends: [EnterClient],
          run: (state, _i, ctx) => ctx.send(ctx.the(Worker), EnterClient, { account: state.account, name: "linear", client: "client-by-hand", secret: "secret-by-hand" }),
        },
        open: {
          label: "Open a sign-in link",
          description: "The person opens a sign-in link while signed in to Axo.",
          inputs: { link: spec.defineInput(String, { accepts: "sign-in link", examples: (w): string[] => [...w.all(Session).flatMap((s) => s.state.links), ...w.all(Browser).flatMap((b) => b.state.pageLinks)] }) },
          sends: [Start],
          run: (state, { link }, ctx) => ctx.send(ctx.the(Worker), Start, { account: state.account, link }),
        },
        approve: {
          label: "Approve at the service",
          description: "The person approves Axo on a consent page with their own account at the service, perhaps on a page someone else sent them.",
          inputs: { page: spec.defineInput(String, { accepts: "consent page", examples: (w): string[] => w.all(Browser).flatMap((b) => (b.state.consent ? [`${b.state.consent.state}|${b.state.consent.client}`] : [])) }) },
          sends: [Consent],
          run(state, { page }, ctx) {
            const [st, client] = page.split("|");
            if (state.consent && `${state.consent.state}|${state.consent.client}` === page) state.consent = null;
            ctx.send(ctx.the(AuthServer), Consent, { state: st!, client: client!, upstream: state.person });
          },
        },
        follow: {
          label: "Follow a callback link",
          description: "The service's redirect takes this browser to Axo's callback.",
          inputs: { link: spec.defineInput(String, { accepts: "callback link", examples: (w): string[] => w.all(Browser).flatMap((b) => b.state.callbacks) }) },
          when: (s) => s.callbacks.length > 0,
          sends: [Callback],
          run(state, { link }, ctx) {
            // Only a redirect this browser received; a leaked callback URL is out of scope (RFD0016, Drawbacks).
            if (!state.callbacks.includes(link)) return;
            const [st, code] = link.split("|");
            ctx.send(ctx.the(Worker), Callback, { state: st!, code: code!, cookie: state.cookie });
          },
        },
      },
      transitions: {
        [ClientSaved]: { description: "The page shows the sign-in link.", run: (s, m) => void s.pageLinks.push(m.link) },
        [ToAuthorize]: {
          description: "Keeps the flow cookie and shows the service's consent page.",
          run(s, m) {
            s.cookie = m.nonce;
            s.consent = { state: m.state, client: m.client };
          },
        },
        [ToCallback]: { description: "The service redirects back with a one-time code.", run: (s, m) => void s.callbacks.push(`${m.state}|${m.code}`) },
        [Connected]: { description: "The page says the connection is being signed in.", run: (s, m) => void (s.result = `${m.name} signing in`) },
        [Refused]: { description: "The page says the sign-in was refused.", run: (s, m) => void (s.result = `refused: ${m.reason}`) },
      },
    });

    spec.defineProperties({
      grantMatchesItsAccount: {
        description: "A grant only lands in the Axo account of the person whose service account it is.",
        always: (w) => Object.entries(w.the(Manager).state.conns).every(([account, cs]) => Object.values(cs).every((c) => !c.grant || accountOf(c.grant.upstream) === account)),
      },
      tokensStayInTheCloud: {
        description: "No browser or agent ever holds a refresh token or a sealed client secret.",
        always: (w) => [...w.all(Browser), ...w.all(Session)].every((x) => !/tok-|sealed:/.test(JSON.stringify(x.state))),
      },
      secretsAreSealed: {
        description: "The Durable Object keeps client secrets only sealed.",
        always: (w) => Object.values(w.the(Manager).state.conns).every((cs) => Object.values(cs).every((c) => c.secret === null || c.secret.startsWith("sealed:"))),
      },
      readyHasAGrant: {
        description: "A connection is ready only while it holds a grant.",
        always: (w) => Object.values(w.the(Manager).state.conns).every((cs) => Object.values(cs).every((c) => c.status !== "ready" || c.grant !== null)),
      },
      codesRedeemedOnce: {
        description: "The service hands out tokens for a code at most once.",
        always: (w) => Object.keys(w.the(AuthServer).state.refreshes).length <= Object.values(w.the(AuthServer).state.codes).filter((c) => c.used).length,
      },
    });

    const signIn = (s: any, browser: any, link: string) => {
      s.act(browser, "open", { link });
      s.settle();
      s.act(browser, "approve", { page: `${browser.state.consent.state}|${browser.state.consent.client}` });
      s.settle();
      s.act(browser, "follow", { link: browser.state.callbacks[0]! });
      s.settle();
    };

    spec.defineScenario({
      name: "Add Linear mid-task",
      description: "Alice's agent adds Linear; Alice opens the link, approves Axo at Linear, and the grant lands in her account.",
      setup(w) {
        w.spawn(Session, "Alice's session");
        w.spawn(Browser, "Alice's browser");
      },
      run(s) {
        s.act(s.the(Session), "add");
        s.settle();
        signIn(s, s.the(Browser), s.the(Session).state.links[0]!);
      },
    });
    spec.defineScenario({
      name: "A service that does not register clients",
      description: "The server has no client registration, so Alice types a client on the Connections page and signs in with it.",
      setup(w) {
        w.set(AuthServer, { dcr: false });
        w.spawn(Session, "Alice's session");
        w.spawn(Browser, "Alice's browser");
      },
      run(s) {
        const browser = s.the(Browser);
        s.act(s.the(Session), "add");
        s.settle();
        s.act(browser, "enterClient");
        s.settle();
        signIn(s, browser, browser.state.pageLinks[0]!);
      },
    });
    spec.defineScenario({
      name: "Mallory sends Alice her consent page",
      description: "Mallory starts a sign-in for her own account and sends Alice the consent page. Alice approves with her own Linear account, but the callback lands in Alice's browser without Mallory's flow cookie, so Alice's grant never reaches Mallory's account.",
      setup(w) {
        w.spawn(Session, "Mallory's session");
        w.spawn(Browser, "Mallory's browser");
        w.spawn(Browser, "Alice's browser");
      },
      run(s) {
        const browser = (label: string) => s.world.all(Browser).find((b) => b.label === label)!;
        s.act(s.the(Session), "add");
        s.settle();
        s.act(browser("Mallory's browser"), "open", { link: s.the(Session).state.links[0]! });
        s.settle();
        const page = browser("Mallory's browser").state.consent!;
        s.act(browser("Alice's browser"), "approve", { page: `${page.state}|${page.client}` });
        s.settle();
        s.act(browser("Alice's browser"), "follow", { link: browser("Alice's browser").state.callbacks[0]! });
        s.settle();
      },
    });
    spec.defineScenario({
      name: "Alice revokes Axo at the service",
      description: "After Alice revokes Axo's access at Linear, the next refresh is refused and the connection needs sign-in again.",
      setup(w) {
        w.spawn(Session, "Alice's session");
        w.spawn(Browser, "Alice's browser");
      },
      run(s) {
        s.act(s.the(Session), "add");
        s.settle();
        const browser = s.the(Browser);
        s.act(browser, "open", { link: s.the(Session).state.links[0]! });
        s.settle();
        s.act(browser, "approve", { page: `${browser.state.consent!.state}|${browser.state.consent!.client}` });
        s.settle();
        s.act(browser, "follow", { link: browser.state.callbacks[0]! });
        s.settle({ until: (w) => w.the(Manager).state.conns["acct-alice"]?.linear?.status === "ready" });
        s.act(s.the(AuthServer), "revoke");
        s.settle();
      },
    });

    spec.defineGroup({ name: "Axo cloud", actors: [Worker, Manager], icon: "cloud", collapsed: false });

    return { Manager, Worker, AuthServer, Session, Browser };
  },
);
