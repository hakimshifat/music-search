# Music Search

Search YouTube, SoundCloud, or your local music library and play audio in the
background with mpv — no browser, no window, just audio. Built a library of
saved tracks, organize them with tags, ratings, and playlists, queue tracks,
and control playback from the bar widget or the `/music` launcher.

This is a conversion of the legacy v4 plugin `music-search` by `kevichi7`
(from <https://github.com/noctalia-dev/legacy-v4-plugins>) to the v5 Luau
plugin API. The command-line backend (`musicctl.sh` + `lib/`) is ported
verbatim from the original.

## Plugin

| Field | Value |
| --- | --- |
| ID | `kevichi7/music-search` |
| Entries | Bar widget: `music`; player panel: `player`; launcher provider: `launcher`; service: `svc` |
| Launcher Prefix | `/music` |

## Requirements

Install on `PATH`:

- `bash` — the plugin shells out to the bundled `musicctl.sh` backend
- `mpv` — background audio playback
- `yt-dlp` — YouTube/SoundCloud search, playback, and downloads
- `jq` — state, library, queue, and playlist data
- `socat` *or* `python3` — mpv IPC (pause, seek, speed, position)
- `ffmpeg` — only needed for mp3 downloads

## Usage

Open the launcher and type `/music`:

- **Search** — type a query to search the default provider. Prefix with `yt:`,
  `sc:`, or `local:` to force a provider, e.g. `/music yt:some song`.
- **Paste a URL** (YouTube, SoundCloud, or a local file path) to play it,
  save it to the library, or download it as mp3.
- **Home** — pressing enter with an empty query shows playback status and your
  recently played, most played, tags, artists, and playlists.
- **Saved tracks** — `saved:` lists your library, optionally filtered:
  `/music saved:rock`.
- **Queue** — `queue` shows the queue with actions to start it now, arm it to
  start when playback stops, autoplay all saved tracks (optionally shuffled),
  stop it, skip, or clear it. `skip` jumps to the next track.
- **Playlists** — `playlist:` browses your playlists; `playlist:<name>` opens
  one and offers play, play shuffled, add to queue, rename, delete, and (for
  folder-synced playlists) sync and "hide local from saved".
- **Artists** — `artist:<name>` lists a library artist's tracks.
- **Tags** — `#tag` or `tag:<name>` lists tagged tracks; typing an unknown
  tag lets you apply it to any library track.
- **Edit metadata** — `edit:` lets you pick a track and change its title,
  artist, or album.
- **Playback speed** — `speed:1.25` sets the mpv speed multiplier (0.25–4).
- **Import a folder** — `import:</path/to/music>` imports all audio files
  into the library, optionally creating a folder-synced playlist.

Activating a search result or library track plays it. The first result of any
list additionally shows actions to save/remove it from the library, add it to
the queue, rate it, edit its metadata, manage its tags, and download it as mp3.

The bar widget shows the current track while playing: left click opens the
player panel. When no track is playing it shows an idle music icon.

The `player` panel shows the current track title, its thumbnail, a seekbar,
and previous/play-pause/next buttons. The next button skips the queued track,
or plays a related song (YouTube radio) when nothing is queued; the previous
button steps back through recently played tracks. The transport row also has
repeat (off/all/one) and shuffle toggles, and a volume slider (0–100, persisted
between sessions) with a mute toggle. The search box on top looks
up tracks directly from the panel: type to search, click a result (or press
Enter for the top hit) to play it; clearing the box returns to the current
track:

noctalia msg panel-toggle kevichi7/music-search:player

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_title` | `bool` | `true` | Show the current track title in the bar (hidden on vertical bars). |
| `provider` | `select` | `youtube` | Default search provider when no `yt:`/`sc:`/`local:` prefix is typed. |
| `sort_by` | `select` | `date` | Default sort for library and playlists. |
| `yt_player_client` | `select` | `web_embedded` | yt-dlp player client used for YouTube. `web_embedded` exposes audio-only streams (best quality, up to ~137 kbps Opus); falls back to `tv`/`web`/`android` when blocked. |
| `download_directory` | `folder` | `~/Music/Noctalia` | Folder where mp3 downloads are saved. |
| `download_cache_max_mb` | `int` | `0` | Download cache limit in MB; `0` = unlimited. Old mp3s are deleted first to stay under the limit. |
| `auto_save_mp3` | `bool` | `false` | Automatically save the current track as mp3 when playback starts. |
| `max_results` | `int` | `8` | Maximum number of results per search. |
| `show_home_recent` | `bool` | `true` | Show recently played tracks on the launcher home. |
| `show_home_top` | `bool` | `true` | Show most played tracks on the launcher home. |
| `show_home_tags` | `bool` | `true` | Show tags on the launcher home. |
| `show_home_artists` | `bool` | `true` | Show artists on the launcher home. |
| `show_home_playlists` | `bool` | `true` | Show playlists on the launcher home. |
| `show_uploader` | `bool` | `true` | Show the uploader in results and the library. |
| `show_duration` | `bool` | `true` | Show the duration in results and the library. |
| `show_rating` | `bool` | `true` | Show the rating in results and the library. |
| `show_tags` | `bool` | `true` | Show tags in results and the library. |
| `show_play_stats` | `bool` | `true` | Show play counts in the library. |

## IPC

All IPC messages target the service entry. Events (payload in parentheses):

```sh
noctalia msg plugin kevichi7/music-search:svc all help
noctalia msg plugin kevichi7/music-search:svc all status
noctalia msg plugin kevichi7/music-search:svc all toggle
noctalia msg plugin kevichi7/music-search:svc all play '<url>'            # or play_url '<url>'
noctalia msg plugin kevichi7/music-search:svc all play '{"entry":{"title":"...","url":"...","uploader":"...","duration":123}}'
noctalia msg plugin kevichi7/music-search:svc all stop
noctalia msg plugin kevichi7/music-search:svc all pause
noctalia msg plugin kevichi7/music-search:svc all resume
noctalia msg plugin kevichi7/music-search:svc all seek '123.5'
noctalia msg plugin kevichi7/music-search:svc all speed '1.25'
noctalia msg plugin kevichi7/music-search:svc all volume '70'
noctalia msg plugin kevichi7/music-search:svc all repeat 'one'    # off | all | one
noctalia msg plugin kevichi7/music-search:svc all shuffle 'true'  # shuffles the current queue
noctalia msg plugin kevichi7/music-search:svc all save '<url>'            # or save_url '<url>'
noctalia msg plugin kevichi7/music-search:svc all refresh
```

`help` shows the full event list as a notification. `play`/`save` accept either a
plain URL string or a JSON entry table (the string form matches the legacy v4
`play`/`save` IPC). Queue and playlist events (`queue_skip`, `queue_clear`,
`queue_start`, `playlist_play <id>`, `import_folder <path>`, …) also work — send
`help` for the complete list.

## Notes

- Playback is handled by the bundled `musicctl.sh` backend, ported from the
  v4 plugin. It writes state to `~/.cache/noctalia/plugins/music-search/`
  (`state.json`, `library.json`, `playlists.json`, `queue.json`,
  `settings.json`, `mpv.pid`, `mpv.sock`, `mpv.log`).
- Volume, repeat mode, and shuffle are persisted in `settings.json` and
  applied to every new mpv launch; volume changes also update a running mpv
  through its IPC socket.
- Repeat one re-plays the finished track (queue does not advance); repeat all
  moves the finished track to the back of the queue; shuffle reorders the
  current queue in place.
- A notification is shown whenever a new track starts. When mpv ships its
  MPRIS script (`/usr/share/mpv/scripts/mpris.so` on most distros), it is
  loaded automatically so media keys and Noctalia's built-in media widget
  work with this player.
- mp3 downloads go to `download_directory` (default `~/Music/Noctalia`);
  downloaded YouTube tracks are reused as the local playback source for
  subsequent plays to avoid re-streaming.
- Search and playback require network access (yt-dlp).
- The queue is armed in-memory; it does not survive a Noctalia restart
  (queued tracks themselves persist in `queue.json`).
- Local search scans `~/Music` (set `MUSIC_CACHE_DIR` to relocate the plugin's
  cache directory for testing).

## Installing from this repository

```sh
noctalia msg plugins source add music-search git https://github.com/hakimshifat/music-search
noctalia msg plugins enable kevichi7/music-search
```

For IDE support, fetch the plugin API typings into the repo root before
editing `.luau` files:

```sh
curl -O https://raw.githubusercontent.com/noctalia-dev/official-plugins/main/noctalia.d.luau
```
