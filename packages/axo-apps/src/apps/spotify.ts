import { z } from "zod";
import { tool, type AppDefinition, type AppTool, type ProviderApi } from "../app";

/**
 * Spotify as an app: `codemode.apps.spotify.<tool>({ account, ... })`: what is playing and on
 * which device, playback control, search, playlists, the library, and listening history. Named
 * by the Spotify ID (oauth/spotify.ts). Playback control needs Spotify Premium; Spotify answers
 * 403 otherwise. Endpoints follow Spotify's February 2026 changes (`/me/library`,
 * `/playlists/{id}/items`, `items` for a playlist's tracks).
 */

const uri = z.string().regex(/^spotify:[a-z]+:[A-Za-z0-9]{1,64}$/).describe("A Spotify URI, such as spotify:track:4iV5W9uYEdYUVa79Axb7Rh.");
const id = z.string().regex(/^[A-Za-z0-9]{1,64}$/);
const device = z.string().regex(/^[A-Za-z0-9_-]{1,128}$/).optional().describe("A device ID from list_devices; the active device when left out.");
const limit = (max: number) => z.number().int().min(1).max(max).optional();
const offset = z.number().int().min(0).max(100_000).optional();
const n = (value: number | undefined) => (value === undefined ? undefined : String(value));

type Artist = { name?: string };
type Track = { type?: string; uri: string; id?: string; name: string; artists?: Artist[]; album?: { name?: string; uri?: string }; duration_ms?: number; show?: { name?: string } };
type Playlist = { id: string; uri: string; name: string; description?: string | null; public?: boolean | null; collaborative?: boolean; owner?: { id?: string; display_name?: string | null }; items?: { total?: number }; tracks?: { total?: number } };

/** A track or episode in a line's worth of fields. */
const track = (t: Track | null | undefined) => t ? ({
  uri: t.uri, name: t.name, type: t.type ?? "track",
  artists: (t.artists ?? []).map((a) => a.name).filter(Boolean), album: t.album?.name ?? t.show?.name ?? null, durationMs: t.duration_ms ?? null,
}) : null;
const playlist = (p: Playlist) => ({
  id: p.id, uri: p.uri, name: p.name, description: p.description ?? null, public: p.public ?? null, collaborative: p.collaborative ?? false,
  owner: p.owner?.display_name ?? p.owner?.id ?? null, trackCount: (p.items ?? p.tracks)?.total ?? null,
});
type Page<T> = { items: T[]; total?: number; next?: string | null };
const page = <T,>(answer: Page<T>, map: (item: any) => unknown) => ({ items: answer.items.map(map), total: answer.total ?? null, more: Boolean(answer.next) });

/** A player command: Spotify answers 204 (or 202) with nothing. */
const command = async (api: ProviderApi, method: "PUT" | "POST", path: string, query: Record<string, string | undefined>, body?: unknown) => {
  await api.request(method, path, { query, body });
  return { ok: true };
};

const tools: AppTool[] = [
  tool({
    name: "get_me",
    description: "The signed-in Spotify user: { id, display_name, ... }.",
    input: z.object({}).strict(),
    idempotent: true,
    run: (api) => api.request("GET", "/v1/me"),
  }),
  tool({
    name: "get_playback",
    description: "What is playing and where: { playing, track, progressMs, device: { id, name, type, volume }, shuffle, repeat, context }, or { playing: false, track: null } when nothing is.",
    input: z.object({}).strict(),
    idempotent: true,
    async run(api) {
      const state = (await api.request("GET", "/v1/me/player", { query: { additional_types: "track,episode" } })) as null | {
        is_playing: boolean; progress_ms?: number | null; item?: Track | null; shuffle_state?: boolean; repeat_state?: string;
        device?: { id?: string | null; name: string; type: string; volume_percent?: number | null }; context?: { uri?: string; type?: string } | null;
      };
      if (!state) return { playing: false, track: null, device: null };
      return {
        playing: state.is_playing, track: track(state.item), progressMs: state.progress_ms ?? null,
        device: state.device ? { id: state.device.id ?? null, name: state.device.name, type: state.device.type, volume: state.device.volume_percent ?? null } : null,
        shuffle: state.shuffle_state ?? false, repeat: state.repeat_state ?? "off", context: state.context?.uri ?? null,
      };
    },
  }),
  tool({
    name: "now_playing",
    description: "The track or episode playing now: { playing, track: { uri, name, artists: [names], album: name, durationMs }, progressMs }, or { playing: false, track: null }.",
    input: z.object({}).strict(),
    idempotent: true,
    async run(api) {
      const now = (await api.request("GET", "/v1/me/player/currently-playing", { query: { additional_types: "track,episode" } })) as null | { is_playing: boolean; progress_ms?: number | null; item?: Track | null };
      return now ? { playing: now.is_playing, track: track(now.item), progressMs: now.progress_ms ?? null } : { playing: false, track: null, progressMs: null };
    },
  }),
  tool({
    name: "list_devices",
    description: "Devices Spotify can play on: { devices: [{ id, name, type, active, volume }] }.",
    input: z.object({}).strict(),
    idempotent: true,
    async run(api) {
      const answer = (await api.request("GET", "/v1/me/player/devices")) as { devices: Array<{ id: string | null; name: string; type: string; is_active: boolean; volume_percent: number | null }> };
      return { devices: answer.devices.map((d) => ({ id: d.id, name: d.name, type: d.type, active: d.is_active, volume: d.volume_percent })) };
    },
  }),
  tool({
    name: "play",
    description: "Starts or resumes playback. With `context` (an album, playlist or artist URI) plays it, from `offset` (a position, or a track URI in it); with `uris` plays those tracks. Needs Premium.",
    input: z.object({
      device,
      context: uri.optional(),
      uris: z.array(uri).min(1).max(100).optional(),
      offset: z.union([z.number().int().min(0), uri]).optional(),
      positionMs: z.number().int().min(0).optional(),
    }).strict(),
    idempotent: true,
    async run(api, input) {
      if (input.context && input.uris) throw new Error("pass `context` or `uris`, not both");
      const body = {
        ...(input.context ? { context_uri: input.context } : {}),
        ...(input.uris ? { uris: input.uris } : {}),
        ...(input.offset === undefined ? {} : { offset: typeof input.offset === "number" ? { position: input.offset } : { uri: input.offset } }),
        ...(input.positionMs === undefined ? {} : { position_ms: input.positionMs }),
      };
      return command(api, "PUT", "/v1/me/player/play", { device_id: input.device }, Object.keys(body).length ? body : undefined);
    },
  }),
  tool({
    name: "pause",
    description: "Pauses playback. Needs Premium.",
    input: z.object({ device }).strict(),
    idempotent: true,
    run: (api, input) => command(api, "PUT", "/v1/me/player/pause", { device_id: input.device }),
  }),
  tool({
    name: "next",
    description: "Skips to the next track. Needs Premium.",
    input: z.object({ device }).strict(),
    idempotent: false,
    run: (api, input) => command(api, "POST", "/v1/me/player/next", { device_id: input.device }),
  }),
  tool({
    name: "previous",
    description: "Goes back to the previous track. Needs Premium.",
    input: z.object({ device }).strict(),
    idempotent: false,
    run: (api, input) => command(api, "POST", "/v1/me/player/previous", { device_id: input.device }),
  }),
  tool({
    name: "seek",
    description: "Moves to `positionMs` in the current track. Needs Premium.",
    input: z.object({ positionMs: z.number().int().min(0), device }).strict(),
    idempotent: true,
    run: (api, input) => command(api, "PUT", "/v1/me/player/seek", { position_ms: String(input.positionMs), device_id: input.device }),
  }),
  tool({
    name: "set_volume",
    description: "Sets the volume, 0 to 100. Needs Premium, and a device that allows it.",
    input: z.object({ percent: z.number().int().min(0).max(100), device }).strict(),
    idempotent: true,
    run: (api, input) => command(api, "PUT", "/v1/me/player/volume", { volume_percent: String(input.percent), device_id: input.device }),
  }),
  tool({
    name: "set_shuffle",
    description: "Turns shuffle on or off. Needs Premium.",
    input: z.object({ on: z.boolean(), device }).strict(),
    idempotent: true,
    run: (api, input) => command(api, "PUT", "/v1/me/player/shuffle", { state: String(input.on), device_id: input.device }),
  }),
  tool({
    name: "set_repeat",
    description: "Repeats the track, the context (album or playlist), or nothing (`off`). Needs Premium.",
    input: z.object({ mode: z.enum(["track", "context", "off"]), device }).strict(),
    idempotent: true,
    run: (api, input) => command(api, "PUT", "/v1/me/player/repeat", { state: input.mode, device_id: input.device }),
  }),
  tool({
    name: "transfer_playback",
    description: "Moves playback to another device, playing there if `play`. Needs Premium.",
    input: z.object({ device: z.string().regex(/^[A-Za-z0-9_-]{1,128}$/).describe("A device ID from list_devices."), play: z.boolean().optional() }).strict(),
    idempotent: true,
    run: (api, input) => command(api, "PUT", "/v1/me/player", {}, { device_ids: [input.device], play: input.play ?? false }),
  }),
  tool({
    name: "get_queue",
    description: "What is playing and what plays next: { current, queue: [tracks] }.",
    input: z.object({}).strict(),
    idempotent: true,
    async run(api) {
      const answer = (await api.request("GET", "/v1/me/player/queue")) as { currently_playing?: Track | null; queue?: Track[] };
      return { current: track(answer.currently_playing), queue: (answer.queue ?? []).map(track) };
    },
  }),
  tool({
    name: "add_to_queue",
    description: "Adds a track or episode to the end of the queue. Needs Premium.",
    input: z.object({ uri, device }).strict(),
    idempotent: false,
    run: (api, input) => command(api, "POST", "/v1/me/player/queue", { uri: input.uri, device_id: input.device }),
  }),
  tool({
    name: "search",
    description: "Searches Spotify's catalogue, with its field filters (\"artist:Radiohead year:1997\"). Returns { tracks, albums, artists, playlists, shows, episodes }, each { items, total, more } for the types asked. At most 10 per type (Spotify's limit).",
    input: z.object({
      query: z.string().min(1).max(256),
      types: z.array(z.enum(["track", "album", "artist", "playlist", "show", "episode"])).min(1).max(6).optional().describe("Default track."),
      limit: limit(10),
      offset,
    }).strict(),
    idempotent: true,
    async run(api, input) {
      const types = input.types ?? ["track"];
      const answer = (await api.request("GET", "/v1/search", { query: { q: input.query, type: types.join(","), limit: n(input.limit), offset: n(input.offset) } })) as Record<string, Page<any> | undefined>;
      const result: Record<string, unknown> = {};
      for (const type of types) {
        const found = answer[`${type}s`];
        if (!found) continue;
        const items = found.items.filter(Boolean);
        result[`${type}s`] = page({ ...found, items }, type === "track" || type === "episode" ? track
          : type === "playlist" ? playlist
          : (x: { uri: string; name: string; artists?: Artist[]; release_date?: string; genres?: string[]; publisher?: string }) => ({ uri: x.uri, name: x.name, artists: x.artists?.map((a) => a.name), released: x.release_date }));
      }
      return result;
    },
  }),
  tool({
    name: "list_playlists",
    description: "The user's playlists, their own and followed: { items: [{ id, uri, name, description, public, collaborative, owner: name, trackCount }], total, more }.",
    input: z.object({ limit: limit(50), offset }).strict(),
    idempotent: true,
    async run(api, input) {
      return page((await api.request("GET", "/v1/me/playlists", { query: { limit: n(input.limit), offset: n(input.offset) } })) as Page<Playlist>, playlist);
    },
  }),
  tool({
    name: "get_playlist",
    description: "A playlist and its tracks: { ...playlist, tracks: { items: [{ uri, name, artists: [names], album: name, durationMs, addedAt }], total, more } }. Spotify only lists the tracks of the user's own playlists and ones they collaborate on.",
    input: z.object({ id, limit: limit(50), offset }).strict(),
    idempotent: true,
    async run(api, input) {
      const [found, items] = await Promise.all([
        api.request("GET", `/v1/playlists/${input.id}`, { query: { fields: "id,uri,name,description,public,collaborative,owner(id,display_name),items(total),tracks(total)" } }) as Promise<Playlist>,
        api.request("GET", `/v1/playlists/${input.id}/items`, { query: { limit: n(input.limit), offset: n(input.offset), additional_types: "track,episode" } }) as Promise<Page<{ added_at?: string; item?: Track | null; track?: Track | null }>>,
      ]);
      return { ...playlist(found), tracks: page(items, (x) => ({ ...track(x.item ?? x.track), addedAt: x.added_at ?? null })) };
    },
  }),
  tool({
    name: "create_playlist",
    description: "Creates a playlist for the user, private unless `public`. Returns { id, uri, name, url }.",
    input: z.object({ name: z.string().min(1).max(100), description: z.string().max(300).optional(), public: z.boolean().optional(), collaborative: z.boolean().optional() }).strict(),
    idempotent: false,
    async run(api, input) {
      if (input.collaborative && input.public) throw new Error("a collaborative playlist is private");
      const created = (await api.request("POST", "/v1/me/playlists", { body: { name: input.name, description: input.description, public: input.public ?? false, collaborative: input.collaborative ?? false } })) as Playlist & { external_urls?: { spotify?: string } };
      return { id: created.id, uri: created.uri, name: created.name, url: created.external_urls?.spotify ?? null };
    },
  }),
  tool({
    name: "add_to_playlist",
    description: "Adds tracks or episodes to a playlist, at `position` or at the end. Returns { snapshotId }.",
    input: z.object({ id, uris: z.array(uri).min(1).max(100), position: z.number().int().min(0).optional() }).strict(),
    idempotent: false,
    async run(api, input) {
      const answer = (await api.request("POST", `/v1/playlists/${input.id}/items`, { body: { uris: input.uris, position: input.position } })) as { snapshot_id: string };
      return { snapshotId: answer.snapshot_id };
    },
  }),
  tool({
    name: "list_saved_tracks",
    description: "Tracks the user saved (liked), newest first: { items: [{ uri, name, artists: [names], album: name, durationMs, addedAt }], total, more }.",
    input: z.object({ limit: limit(50), offset }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("GET", "/v1/me/tracks", { query: { limit: n(input.limit), offset: n(input.offset) } })) as Page<{ added_at: string; track: Track }>;
      return page(answer, (x) => ({ ...track(x.track), addedAt: x.added_at }));
    },
  }),
  tool({
    name: "list_saved_albums",
    description: "Albums the user saved, newest first: { items: [{ uri, name, artists: [names], released, addedAt }], total, more }.",
    input: z.object({ limit: limit(50), offset }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("GET", "/v1/me/albums", { query: { limit: n(input.limit), offset: n(input.offset) } })) as Page<{ added_at: string; album: { uri: string; name: string; artists?: Artist[]; release_date?: string } }>;
      return page(answer, (x) => ({ uri: x.album.uri, name: x.album.name, artists: (x.album.artists ?? []).map((a: Artist) => a.name), released: x.album.release_date ?? null, addedAt: x.added_at }));
    },
  }),
  tool({
    name: "save_to_library",
    description: "Saves tracks, albums, episodes, shows or playlists to the user's library (likes a track, follows a playlist).",
    input: z.object({ uris: z.array(uri).min(1).max(40) }).strict(),
    idempotent: true,
    run: (api, input) => command(api, "PUT", "/v1/me/library", { uris: input.uris.join(",") }),
  }),
  tool({
    name: "remove_from_library",
    description: "Removes tracks, albums, episodes, shows or playlists from the user's library.",
    input: z.object({ uris: z.array(uri).min(1).max(40) }).strict(),
    idempotent: true,
    async run(api, input) {
      await api.request("DELETE", "/v1/me/library", { query: { uris: input.uris.join(",") } });
      return { ok: true };
    },
  }),
  tool({
    name: "recently_played",
    description: "Tracks the user played lately, newest first (Spotify keeps about the last 50): { items: [{ uri, name, artists: [names], album: name, durationMs, playedAt }] }.",
    input: z.object({ limit: limit(50), before: z.number().int().positive().optional().describe("Only plays before this time, in Unix milliseconds.") }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("GET", "/v1/me/player/recently-played", { query: { limit: n(input.limit), before: n(input.before) } })) as Page<{ played_at: string; track: Track }>;
      return { items: answer.items.map((x) => ({ ...track(x.track), playedAt: x.played_at })) };
    },
  }),
  tool({
    name: "top_items",
    description: "The user's most played artists or tracks over about 4 weeks (short_term), 6 months (medium_term, the default) or a year (long_term): " +
      "{ items: [{ uri, name, genres }] } for artists, { items: [{ uri, name, artists: [names], album: name, durationMs }] } for tracks, with total and more.",
    input: z.object({ type: z.enum(["artists", "tracks"]), timeRange: z.enum(["short_term", "medium_term", "long_term"]).optional(), limit: limit(50), offset }).strict(),
    idempotent: true,
    async run(api, input) {
      const answer = (await api.request("GET", `/v1/me/top/${input.type}`, { query: { time_range: input.timeRange ?? "medium_term", limit: n(input.limit), offset: n(input.offset) } })) as Page<any>;
      return page(answer, input.type === "tracks" ? track : (a: { uri: string; name: string; genres?: string[] }) => ({ uri: a.uri, name: a.name, genres: a.genres ?? [] }));
    },
  }),
];

export const spotify: AppDefinition = {
  name: "spotify",
  title: "Spotify",
  description: "Your Spotify: what is playing, playback on your devices, search, playlists, your library and what you listen to.",
  permissions: [
    "See what you are playing, on which device, and your queue",
    "Play, pause, skip, seek and change the volume on your devices",
    "See, create and change your playlists, public and private",
    "See and change your saved tracks, albums and shows",
    "See what you played lately and your most played artists and tracks",
  ],
  signIn: "oauth",
  provider: "spotify",
  providerTitle: "Spotify",
  category: "media",
  apiOrigin: "https://api.spotify.com",
  hosts: ["api.spotify.com"],
  reference: "https://developer.spotify.com/documentation/web-api",
  scopes: [
    "user-read-playback-state",
    "user-modify-playback-state",
    "user-read-currently-playing",
    "playlist-read-private",
    "playlist-read-collaborative",
    "playlist-modify-private",
    "playlist-modify-public",
    "user-library-read",
    "user-library-modify",
    "user-read-recently-played",
    "user-top-read",
  ],
  requiredScopes: ["user-read-playback-state"],
  tools,
};
