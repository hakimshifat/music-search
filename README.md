# Music Search for Noctalia

A [Noctalia](https://docs.noctalia.dev/v5) plugin source repo shipping **Music Search** — search YouTube, SoundCloud, or your local music library and play audio in the background with mpv. No browser, no window, just audio.

This repo is a Noctalia **plugin source**: the plugin lives in [`music-search/`](music-search/README.md), indexed by `catalog.toml` at the repo root.

## Install

Add this repo as a source, then enable the plugin:

```sh
noctalia msg plugins source add music-search git https://github.com/hakimshifat/music-search
noctalia msg plugins enable kevichi7/music-search
```

Or open **Settings → Plugins → Add source** and paste the repo URL above. Toggling the plugin on fetches and activates it; the source updates automatically (startup + every 6 hours, or `noctalia msg plugins update music-search`).

## What you get

| Field | Value |
| --- | --- |
| ID | `kevichi7/music-search` |
| Entries | Bar widget: `music`; player panel: `player`; launcher provider: `launcher`; service: `svc` |
| Launcher Prefix | `/music` |

- **Launcher** — type `/music` to search, paste a URL, browse your library, queue, tags, artists, and playlists.
- **Bar widget** — current track, left-click opens the player panel.
- **Player panel** — `noctalia msg panel-toggle kevichi7/music-search:player`, or click the widget: seekbar, transport buttons, repeat/shuffle, volume.

See [`music-search/README.md`](music-search/README.md) for full usage, settings, and IPC documentation.

## Requirements

`bash`, `mpv`, `yt-dlp`, `jq`, and `socat` *or* `python3` on `PATH` (`ffmpeg` only for mp3 downloads).

## Repository layout

```
catalog.toml        # source index (kept in sync with music-search/plugin.toml)
music-search/       # the plugin: manifest, entry scripts, backend, translations
```

Requires Noctalia v5 (`plugin_api = 3`).
