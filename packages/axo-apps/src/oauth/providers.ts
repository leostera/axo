import { githubProvider } from "./github";
import { googleProvider } from "./google";
import { spotifyProvider } from "./spotify";
import { withingsProvider } from "./withings";
import type { OAuthProvider, OAuthProviderName } from "./provider";

/** Every OAuth provider an app can sign in with, by name. */
export const OAUTH_PROVIDER_CONFIGS: Record<OAuthProviderName, OAuthProvider> = {
  google: googleProvider,
  github: githubProvider,
  spotify: spotifyProvider,
  withings: withingsProvider,
};
