import { FakeOAuth, json } from "./fake-oauth";

/**
 * Spotify as the Spotify app sees it: PKCE with the client in HTTP basic, refresh tokens that
 * rotate, `/me` without an email (development mode, February 2026), and enough of the player,
 * search, playlists and library. Player commands answer 204; with nothing playing, 204 too.
 */
export class FakeSpotify {
  readonly oauth = new FakeOAuth({ authorizeUrl: "https://accounts.spotify.com/authorize", tokenAuth: "basic", pkce: true, scopeSeparator: " ", rotates: true, answerSeparator: " " });
  readonly calls: Array<{ as: string; call: string; query: URLSearchParams; body: string }> = [];
  playing = true;

  async handle(request: Request): Promise<Response | undefined> {
    const url = new URL(request.url);
    if (url.origin === "https://accounts.spotify.com" && url.pathname === "/api/token" && request.method === "POST") {
      const result = this.oauth.token(new URLSearchParams(await request.text()), request.headers);
      if (!result.ok) return json({ error: result.error, error_description: "Invalid" }, result.status);
      return json({ access_token: result.accessToken, token_type: "Bearer", scope: result.scope, expires_in: result.expiresIn, refresh_token: result.refreshToken });
    }
    if (url.origin !== "https://api.spotify.com") return undefined;
    const as = this.oauth.who(request);
    if (!as) return json({ error: { status: 401, message: "The access token expired" } }, 401);
    const body = request.body ? await request.text() : "";
    const call = `${request.method} ${url.pathname}`;
    this.calls.push({ as, call, query: url.searchParams, body });
    const track = (n: number) => ({ type: "track", uri: `spotify:track:t${n}`, id: `t${n}`, name: `Song ${n}`, artists: [{ name: "Ada" }], album: { name: "Engines" }, duration_ms: 180_000 });
    const none = () => new Response(null, { status: 204 });
    switch (call) {
      case "GET /v1/me": return json({ id: as, display_name: as.toUpperCase(), type: "user" });
      case "GET /v1/me/player":
        return this.playing ? json({ is_playing: true, progress_ms: 1000, item: track(1), shuffle_state: false, repeat_state: "off", device: { id: "d1", name: "Kitchen", type: "Speaker", volume_percent: 40 }, context: { uri: "spotify:playlist:p1" } }) : none();
      case "GET /v1/me/player/devices": return json({ devices: [{ id: "d1", name: "Kitchen", type: "Speaker", is_active: true, volume_percent: 40 }] });
      case "PUT /v1/me/player/play": case "PUT /v1/me/player/pause": case "POST /v1/me/player/next": case "PUT /v1/me/player/volume": case "PUT /v1/me/player": case "POST /v1/me/player/queue": case "PUT /v1/me/library":
        return none();
      case "GET /v1/search": return json({ tracks: { items: [track(2), null], total: 1, next: null } });
      case "GET /v1/me/playlists": return json({ items: [{ id: "p1", uri: "spotify:playlist:p1", name: "Mine", public: false, collaborative: false, owner: { id: as }, items: { total: 2 } }], total: 1, next: null });
      case "GET /v1/playlists/p1": return json({ id: "p1", uri: "spotify:playlist:p1", name: "Mine", public: false, collaborative: false, owner: { id: as }, items: { total: 2 } });
      case "GET /v1/playlists/p1/items": return json({ items: [{ added_at: "2026-10-01T00:00:00Z", item: track(1) }, { added_at: "2026-10-02T00:00:00Z", item: track(3) }], total: 2, next: null });
      case "POST /v1/playlists/p1/items": return json({ snapshot_id: "snap2" }, 201);
      case "POST /v1/me/playlists": return json({ id: "p2", uri: "spotify:playlist:p2", name: JSON.parse(body).name, external_urls: { spotify: "https://open.spotify.com/playlist/p2" } }, 201);
      case "GET /v1/me/player/recently-played": return json({ items: [{ played_at: "2026-10-31T10:00:00Z", track: track(4) }] });
      case "GET /v1/me/top/artists": return json({ items: [{ uri: "spotify:artist:a1", name: "Ada", genres: ["synth"] }], total: 1, next: "more" });
      default: return json({ error: { status: 404, message: "Service not found" } }, 404);
    }
  }
}
