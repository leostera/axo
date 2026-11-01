# @axo/apps

Axo's apps (RFD0016, Apps): the services Axo provides itself, reached from a Session as
`codemode.apps.<app>.<tool>({ account, ... })`.

This package says what each app is, and holds no state:

- `src/app.ts`: the shapes of an app (OAuth, token, device, Mac) and of a tool, and the errors a
  call can end with.
- `src/apps/<app>.ts`: one app each: its description, permissions, API hosts and tools.
- `src/oauth/`: the OAuth providers apps sign in with (`provider.ts` is the shape, one file per
  provider), and ChatGPT's device sign-in (`openai.ts`).
- `src/catalog.ts`: every app by name, and each app's tools (its own, then `request`).

The account's gateway (`packages/axo-api-worker/src/connections/apps`) does everything stateful
with these: it stores the OAuth clients the person set up and the grants and tokens of each
account, sealed; it runs sign-ins; and it makes every call, through the `ProviderApi` a tool is
given, which only reaches the app's own hosts.

## Adding an app

1. Add its name to `APPS` in `packages/axo-api/src/connections.ts`.
2. Write `src/apps/<app>.ts` and add it to `src/catalog.ts`.
3. For an OAuth app of a new provider, write `src/oauth/<provider>.ts`, add the provider to
   `OAUTH_PROVIDERS` and `src/oauth/providers.ts`, and a fake of it in
   `packages/axo-api-worker/tests`.

Checks: `npm test` here, and `npm run test:core` in `packages/axo-api-worker`.
