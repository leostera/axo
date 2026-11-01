import { githubProvider } from "./github";
import { googleProvider } from "./google";
import type { OAuthProvider, OAuthProviderName } from "./provider";

/** Every OAuth provider an app can sign in with, by name. */
export const OAUTH_PROVIDER_CONFIGS: Record<OAuthProviderName, OAuthProvider> = {
  google: googleProvider,
  github: githubProvider,
};
