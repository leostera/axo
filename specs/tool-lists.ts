import { call, defineSpec, message } from "@leostera/feynman";

const HOUR = 60 * 60 * 1_000;

// RFD0016: how the account's Durable Object keeps each third-party connection's tool definitions.
// Searches answer from the stored lists at once; a list older than an hour, or a server's
// tool-list-changed notification, starts a background refresh; a failing server leaves its list
// stale with the error recorded.
//
// Not built yet, so no step has sources. One connection and one Session; host connections have a
// fixed tool list and need no sync. Staleness is a timer that flips state: specs have no clock.

export default defineSpec(
  "Tool lists",
  {
    description:
      "How the account's Durable Object keeps third-party tool lists fresh enough for search without ever making a search wait on a server.",
    messages: {
      Search: call<{}>({ name: "connections_search", over: "relay" }),
      Results: message<{ tools: string[]; stale: boolean }>({ name: "search results", over: "relay", tone: "reply" }),
      ListTools: call<{}>({ name: "tools/list", over: "https" }),
      Tools: message<{ tools: string[] }>({ name: "tools/list result", over: "https", tone: "reply" }),
      ListChanged: message<{}>({ name: "notifications/tools/list_changed", over: "https" }),
    },
  },
  (spec) => {
    const { Search, Results, ListTools, Tools, ListChanged } = spec.messages;

    const macs = spec.defineZone({ name: "Macs", description: "an agent in a Session" });
    const cloudflare = spec.defineZone({ name: "Cloudflare", description: "the account's Durable Object", place: { column: 1, region: true } });
    const services = spec.defineZone({ name: "Third-party services", place: { column: 2 } });

    spec.defineLimit({ name: "A stored tool list is refreshed in the background once older than", value: HOUR });

    const Manager = spec.defineActor({
      name: "AxoAccountManager",
      description: "The account's Durable Object: it stores each connection's tool list and refreshes it in the background.",
      zone: cloudflare,
      singleton: true,
      initialState: () => ({
        tools: ["list_issues"] as string[],
        stale: false,
        /** One refresh at a time; a change heard during one queues exactly one more. */
        syncing: false,
        again: false,
        error: null as string | null,
        /** Flips each time a search is answered, so a step can tell it answered one. */
        answered: false,
      }),
      durable: ["tools"],
      display: {
        icon: "cloud",
        status: (s) => (s.syncing ? "refreshing linear's tools" : s.error ? `stale: ${s.error}` : s.stale ? "linear's tools are stale" : "linear's tools are fresh"),
        mood: (s) => (s.error ? "warn" : s.syncing ? "busy" : "ok"),
        rows: (s) => [{ group: "linear", label: "tools", detail: s.tools.join(", ") || "none", mood: s.stale ? ("warn" as const) : ("ok" as const) }],
      },
      transitions: {
        [Search]: {
          description: "Answers from the stored list at once; a stale list also starts a refresh.",
          sends: [Results, ListTools],
          run(state, _m, ctx) {
            state.answered = !state.answered;
            ctx.reply(Results, { tools: [...state.tools], stale: state.stale });
            if (state.stale && !state.syncing) {
              state.syncing = true;
              ctx.send(ctx.the(Linear), ListTools, {});
            }
          },
        },
        [ListChanged]: {
          description: "The server says its tools changed; the list is stale and a refresh starts, or queues behind the one in flight.",
          sends: [ListTools],
          run(state, _m, ctx) {
            state.stale = true;
            if (state.syncing) return void (state.again = true);
            state.syncing = true;
            ctx.send(ctx.the(Linear), ListTools, {});
          },
        },
        [Tools]: {
          description: "Stores the new list; if a change was heard meanwhile, it stays stale and lists again.",
          sends: [ListTools],
          starts: ["ageing"],
          run(state, m, ctx) {
            state.tools = [...m.tools];
            state.error = null;
            if (state.again) {
              state.again = false;
              return ctx.send(ctx.the(Linear), ListTools, {});
            }
            state.stale = false;
            state.syncing = false;
            ctx.start("ageing");
          },
        },
        [spec.failed(ListTools)]: {
          description: "The refresh failed; the old list stays, marked stale, with the error. The next search retries.",
          run(state) {
            state.syncing = false;
            state.again = false;
            state.stale = true;
            state.error = "linear did not answer tools/list";
          },
        },
        ageing: {
          description: "The stored list is now older than an hour.",
          after: "1 hour",
          run: (state) => void (state.stale = true),
        },
      },
    });

    const Linear = spec.defineActor({
      name: "Linear MCP",
      description: "A third-party MCP server whose tools change when it deploys.",
      zone: services,
      singleton: true,
      initialState: () => ({ tools: ["list_issues"] as string[], deploys: 0, changedSinceListed: false }),
      durable: ["tools", "deploys", "changedSinceListed"],
      display: { icon: "server", status: (s) => s.tools.join(", ") },
      actions: {
        deploy: {
          label: "Deploy a new tool",
          description: "The service adds a tool and tells connected clients its list changed.",
          when: (s) => s.deploys < 2,
          sends: [ListChanged],
          run(state, _i, ctx) {
            state.deploys += 1;
            state.tools.push(state.deploys === 1 ? "create_issue" : "close_issue");
            state.changedSinceListed = true;
            ctx.send(ctx.the(Manager), ListChanged, {});
          },
        },
        quietDeploy: {
          label: "Deploy without notifying",
          description: "The service adds a tool and does not send a notification.",
          when: (s) => s.deploys < 2,
          run(state) {
            state.deploys += 1;
            state.tools.push(state.deploys === 1 ? "create_issue" : "close_issue");
            state.changedSinceListed = true;
          },
        },
      },
      transitions: {
        [ListTools]: {
          description: "Returns its current tools.",
          sends: [Tools],
          run(state, _m, ctx) {
            state.changedSinceListed = false;
            ctx.reply(Tools, { tools: [...state.tools] });
          },
        },
      },
    });

    const Session = spec.defineActor({
      name: "Session",
      description: "An agent searching its account's tools.",
      zone: macs,
      singleton: true,
      initialState: () => ({ waiting: false, seen: null as null | { tools: string[]; stale: boolean } }),
      display: { icon: "robot", status: (s) => (s.waiting ? "searching" : s.seen ? `saw ${s.seen.tools.join(", ")}${s.seen.stale ? " (stale)" : ""}` : "idle") },
      actions: {
        search: {
          label: "Search tools",
          description: "The agent searches its account's tools.",
          when: (s) => !s.waiting,
          sends: [Search],
          run(state, _i, ctx) {
            state.waiting = true;
            ctx.send(ctx.the(Manager), Search, {});
          },
        },
      },
      transitions: {
        [spec.failed(Search)]: {
          description: "The relay dropped; the search fails and the agent may search again (RFD0016, Transport).",
          run: (state) => void (state.waiting = false),
        },
        [Results]: {
          description: "Reads the results.",
          run(state, m) {
            state.waiting = false;
            state.seen = { tools: m.tools, stale: m.stale };
          },
        },
      },
    });

    const same = (a: string[], b: string[]) => a.length === b.length && a.every((x, i) => x === b[i]);

    spec.defineProperties({
      searchNeverWaits: {
        description: "The Durable Object answers a search in the same step it handles it, whatever the server is doing.",
        everyStep: (before, after, e) =>
          !e.is(Manager, "message:Search") || after.the(Manager).state.answered === before.the(Manager).state.answered || e.replied("message:Results"),
      },
      freshMeansCurrent: {
        description: "Once nothing is in flight, a list not marked stale matches the server's tools, unless they changed since the server last listed them and the notification never came (not sent, or lost); the hourly ageing covers that.",
        always: (w) => !w.quiet || w.the(Manager).state.stale || w.the(Linear).state.changedSinceListed || same(w.the(Manager).state.tools, w.the(Linear).state.tools),
      },
      notifiedChangesArrive: {
        description: "A refresh in flight always ends, with the new list or a recorded error; a change heard meanwhile never leaves it running forever.",
        leadsTo: {
          whenever: (w) => w.the(Manager).state.syncing,
          then: (w) => !w.the(Manager).state.syncing,
        },
      },
    });

    spec.defineScenario({
      name: "A new tool appears",
      description: "Linear deploys create_issue and notifies; the stored list refreshes and the next search finds it.",
      run(s) {
        s.act(s.the(Linear), "deploy");
        s.settle();
        s.act(s.the(Session), "search");
        s.settle();
      },
    });
    spec.defineScenario({
      name: "A quiet deploy is found after an hour",
      description: "After one notified deploy, Linear adds a tool without notifying; searches return the old list until it ages, and the first search after that answers from the old list and starts a refresh.",
      run(s) {
        s.act(s.the(Linear), "deploy");
        s.settle({ until: (w) => w.the(Manager).state.tools.includes("create_issue") && !w.the(Manager).state.syncing });
        s.act(s.the(Linear), "quietDeploy");
        s.act(s.the(Session), "search");
        s.settle({ until: (w) => !w.the(Session).state.waiting });
        s.fire(s.the(Manager), "ageing");
        s.act(s.the(Session), "search");
        s.settle();
        s.act(s.the(Session), "search");
        s.settle();
      },
    });

    return { Manager, Linear, Session };
  },
);
