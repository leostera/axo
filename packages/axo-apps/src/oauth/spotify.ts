import type { OAuthProvider } from "./provider";

/**
 * Spotify as an OAuth provider: the authorization code flow with PKCE, the client sent with HTTP
 * basic. A renewal may return a new refresh token, which replaces the old one. A development-mode
 * app only signs in people on its allow-list, and Spotify no longer gives such apps the account's
 * email (February 2026), so an account is named by its Spotify ID.
 */
export const spotifyProvider: OAuthProvider = {
  name: "spotify",
  title: "Spotify",
  issuer: "https://accounts.spotify.com",
  authorizeUrl: "https://accounts.spotify.com/authorize",
  tokenUrl: "https://accounts.spotify.com/api/token",
  consoleUrl: "https://developer.spotify.com/dashboard",
  scopeSeparator: " ",
  // Spotify's own page every time, so another account can be signed in to.
  authorizeParams: { show_dialog: "true" },
  pkce: true,
  tokenAuth: "basic",
  tokenParams: {},
  rotatesRefreshTokens: true,
  async identify(_grant, api) {
    const me = (await api.request("GET", "/v1/me")) as { id?: unknown };
    return typeof me.id === "string" ? me.id : null;
  },
};
