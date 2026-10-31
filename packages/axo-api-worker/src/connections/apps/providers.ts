import { githubProvider } from "./github";
import { googleProvider } from "./google";
import { oauthClients, type OAuthClients, type OAuthProvider, type OAuthProviderName } from "./oauth-provider";

/** Every OAuth provider Axo has its own client with, by name. */
export const OAUTH_PROVIDER_CONFIGS: Record<OAuthProviderName, OAuthProvider> = {
  google: googleProvider,
  github: githubProvider,
};

/** Axo's OAuth clients set on the Worker (`<PROVIDER>_CLIENT_ID` and `_SECRET`), for AccountConnections' `clients`. */
export function appClients(env: object): OAuthClients {
  return oauthClients(env as Record<string, unknown>, Object.values(OAUTH_PROVIDER_CONFIGS));
}
