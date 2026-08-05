# AGENTS.md

Noctalia v5 Luau plugin (`kevichi7/music-search`). Launcher `/music` + bar widget + player panel that searches YouTube/SoundCloud/local and plays via mpv. Port of the legacy v4 plugin.

The repo is a standalone plugin **source**: `catalog.toml` at the repo root, the plugin itself in `music-search/` (directory name must match the id segment after the `/` — Noctalia exports that directory from the git source on enable; a root-level `plugin.toml` will not enable).

## Platform: Noctalia and niri

- **Noctalia** (docs.noctalia.dev/v5, still beta) is a native Wayland desktop shell (C++, OpenGL ES, no Qt/GTK) that owns the shell layer — bars, launcher, notifications, lock screen, wallpaper, panels — on top of a Wayland compositor. It is not a compositor itself. Plugin capability levels are `plugin_api` 3–23 and cumulative; this repo pins `plugin_api = 18` and should only bump when it adopts a newer capability (e.g. 18 = `panel.setWantsSecondTicks()` for self-refreshing panels; 15 = `noctalia.openSettings()`, 17 = `onEnable()`/`onExit(signal, reason)`, 22 = `require("./...")` modules). Keep a `[[plugin.release]]` row for the previous `plugin_api` level in `catalog.toml` so older Noctalia shells stay installable.
- **Noctalia plugins**: a plugin is a `plugin.toml` manifest + entry `.luau` scripts; entries can be `[[widget]]` (bar), `[[shortcut]]`, `[[launcher_provider]]`, `[[desktop_widget]]`, `[[panel]]`, `[[service]]` (headless). Each entry runs in its own isolated Luau VM, off the UI thread, with per-call time budgets — entries share nothing except plain values via `noctalia.state` (copies, in-memory, cleared on stop). Core entry callbacks: `update()`, `onIpc(event, payload)`, `onOpen()` (panels), `onQuery`/`onActivate` (launchers), `onExit`.
- **Noctalia sync/async split**: most `noctalia.*` calls are synchronous; `runAsync`, `http`, `download` return a boolean "accepted" and deliver results to a callback. `runAsync(cmd, cb)` calls back once with `{ exitCode, stdout, stderr, timedOut }`. The repo uses this with its own 60 s timeout.
- **IPC from the shell** (`noctalia msg ...`): messages target an entry: `noctalia msg plugin <author>/<plugin>:<entry> focused|all <event> [payload]` — services are singletons with no output so only `all` matches. Host messages use the same CLI: `noctalia msg panel-toggle kevichi7/music-search:player`, `noctalia msg volume-up`, etc. An entry receives these as `onIpc(event, payload)`.
- **Settings** are read-only in plugins: `noctalia.getConfig(key)` resolves only declared keys (undeclared → warning + nil); `noctalia.openSettings()` is how a plugin offers its own "configure me". Setting `label_key`/`description_key` are always translation keys, never literals.
- **Persistence**: never write into `noctalia.pluginDir()` — for git-installed plugins it is a runtime copy Noctalia rewrites on update. Use `noctalia.pluginDataDir()` (survives updates, honors `NOCTALIA_STATE_HOME`); that's why this repo's `queue-active.json` lives there. `noctalia.state` is in-memory only.
- **Translations**: `noctalia.tr("dotted.key", { subst })` reads `translations/<lang>.json` and falls back to the key when missing; `noctalia.trp(key, count)` picks `<key>.one`/`.other` for plurals.
- **Dev loop**: drop the plugin under `$XDG_DATA_HOME/noctalia/plugins/<id>/` or add a `path` source; `.luau` edits hot-reload, manifest changes apply on config reload. A plugin id is canonical — the local data dir outranks sources, later-added sources outrank earlier ones, and user sources outrank built-in `official`/`community`, so you can clone `noctalia-dev/official-plugins` and edit in place to override a shipped plugin.
- **Reference material**: `https://docs.noctalia.dev/v5/plugins/development/{manifest,entries,runtime-api,declarative-ui,workflow}` and the `example` plugin (service→state→widget) in `noctalia-dev/official-plugins` — this repo mirrors that exact service/consumer pattern.
- **niri** (niri.dev) is a scrollable-tiling Wayland compositor commonly paired with Noctalia (`~/.config/niri/config.kdl`, `spawn-at-startup "noctalia"`); Noctalia detects it via `$NIRI_SOCKET`. Not a dependency of this plugin, but context for the system: Noctalia's bar/panels/dock are niri layer-shell surfaces with `noctalia-*` namespaces (list with `niri msg layers`), and niri keybinds shell out to the shell via `spawn-sh "noctalia msg ..."`.

## Architecture

- `music-search/service.luau` (entry `svc`) is the only file that talks to the backend. It shells out via `noctalia.runAsync("bash <pluginDir>/musicctl.sh <cmd> ...")` (60s timeout, args shell-quoted) and publishes snapshots to `noctalia.state`: `music_snapshot`, `music_position`. Consumers dispatch actions by setting `music_command`; the service `watch`es it.
- `music-search/launcher.luau`, `music-search/widget.luau`, `music-search/panel.luau` are thin state consumers — never call the backend directly, never import each other's code.
- `music-search/musicctl.sh` + `music-search/lib/*.sh` is the bash backend, ported verbatim from the v4 plugin. Playback/library/queue logic lives here, not in Luau. State files (json) live in `~/.cache/noctalia/plugins/music-search/`; override with `MUSIC_CACHE_DIR` for testing.
- `music-search/musicctl.sh` has no tests — all playback logic (search, queue, playlists, settings, ipc) is exercised through it, so it is the test harness.
- `.luau` files must start with `--!nonstrict` (see `.luaurc`). There is no CI, no linter, no test runner.

## Commands

- Shell command list: read the `case` in `musicctl.sh` (or `noctalia msg plugin kevichi7/music-search:svc all help` for the IPC event list).
- Test a backend command without touching real state: `MUSIC_CACHE_DIR=/tmp/music-test bash music-search/musicctl.sh search 'some song'`.
- Manual IPC smoke test: `noctalia msg plugin kevichi7/music-search:svc all status`.
- IDE support: fetch the plugin API typings into repo root before editing `.luau` files — `curl -O https://raw.githubusercontent.com/noctalia-dev/official-plugins/main/noctalia.d.luau` (never commit it; README documents this). `luau-lsp` reads `.luaurc`.

## Conventions and gotchas

- A plugin source repo ships one plugin per subdirectory named after the id segment after the `/` (`music-search/` here); `catalog.toml` at the repo root indexes it. `catalog.toml` must stay in sync with `music-search/plugin.toml` (version, description, `updated_at`); bump both when the manifest changes.
- Settings: plugin.toml keys are snake_case (`yt_player_client`), but JSON files and `music-search/lib/config.sh` read camelCase (`ytPlayerClient`, `downloadCacheMaxMb`, `downloadDirectory`). `music-search/lib/config.sh` holds the defaults — plugin.toml defaults must match.
- Every user-facing string goes through `noctalia.tr("dotted.key")` with text in `translations/en.json` (nested JSON, dot-addressed). plugin.toml `label_key`/`description_key` use the same dot notation.
- Plugin ID `kevichi7/music-search` is hardcoded in strings (e.g. `noctalia.togglePanel("kevichi7/music-search:player")`, `noctalia.state.set("music_command", ...)`) and must match `music-search/plugin.toml` `id`.
- JSON safety: writes go through `json_write_raw` (tmp file, `.bak` backup, jq validation); `safe_read_json` quarantines corrupt files as `.corrupt.<ts>` and restores from `.bak`. Don't bypass these; `state.json` reinitializes but user data files die hard.
- File writes take `flock` locks from `with_lock` — keep lock ordering consistent to avoid deadlocks.
- mpv is headless: `--vo=null` in `music-search/lib/launch.sh`; mpv IPC via socat with python3 fallback (`music-search/lib/mpv-ipc.sh`). Dependencies: bash, mpv, yt-dlp, jq, socat (or python3), ffmpeg (mp3 only).
- Queue "armed" state is in-memory (`queue-active.json` in `noctalia.pluginDataDir()`) — doesn't survive restart, and lives outside `MUSIC_CACHE_DIR`.
- Downloaded mp3s double as local playback source for later plays of the same URL.
