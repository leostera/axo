import type { OAuthProvider } from "./provider";

/**
 * Google as an OAuth provider, for the Google apps (Gmail, Calendar, Drive...): one Web
 * application client registered in Google Cloud serves all of them. The account is named by the
 * email in the ID token, which oauth4webapi checks names Google and this client. Google does not
 * rotate refresh tokens.
 */

export const GOOGLE_REVOKE_URL = "https://oauth2.googleapis.com/revoke";
const TIMEOUT_MS = 15_000;

export const googleProvider: OAuthProvider = {
  name: "google",
  title: "Google",
  issuer: "https://accounts.google.com",
  authorizeUrl: "https://accounts.google.com/o/oauth2/v2/auth",
  tokenUrl: "https://oauth2.googleapis.com/token",
  consoleUrl: "https://console.cloud.google.com/apis/credentials",
  scopeSeparator: " ",
  // A refresh token on every sign-in, so signing in again always replaces a spent grant; consent
  // every time (so Google returns one), and a choice of account (so a second one can be added).
  authorizeParams: { access_type: "offline", prompt: "consent select_account" },
  pkce: true,
  tokenAuth: "body",
  tokenParams: {},
  rotatesRefreshTokens: false,
  identify: async (grant) => grant.email,
  async revoke(grant, _client, fetcher) {
    const response = await fetcher(GOOGLE_REVOKE_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ token: grant.refreshToken ?? grant.accessToken }),
      redirect: "manual",
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    await response.body?.cancel();
  },
};
