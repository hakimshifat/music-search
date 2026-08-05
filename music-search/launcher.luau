--!nonstrict

local helper = ((noctalia.pluginDir() or ""):gsub("/+$", "")) .. "/musicctl.sh"

local snapshot = noctalia.state.get("music_snapshot")

local searchResults = {}
local searchBusy = false
local searchFailed = false
local lastCompletedQuery = ""
local lastSearchQuery = ""
local pendingSearchQuery = nil

local lastQuery = ""
local actions = {}
local rateCounter = {}
local rowIndex = 0

local playlistPickerEntryId = nil
local tagEditorEntryId = nil
local metadataEditorEntryId = nil
local metadataEditorField = nil
local renamePlaylistId = nil
local renamePlaylistName = nil

local S = {
  status = 1000,
  playback = 950,
  quick = 900,
  header = 800,
  item = 790,
  actions = 780,
}

local trCache = {}

local function tr(key, args)
  if args then
    return noctalia.tr(key, args)
  end
  local cached = trCache[key]
  if cached ~= nil then
    return cached
  end
  local value = noctalia.tr(key)
  trCache[key] = value
  return value
end

local settingsCache = {}

local function getSetting(key, fallback)
  local v = settingsCache[key]
  if v == nil then
    v = noctalia.getConfig(key)
    settingsCache[key] = v
  end
  if v == nil then return fallback end
  return v
end

local rowCfg

function onConfigChanged()
  settingsCache = {}
  trCache = {}
  rowCfg = {
    uploader = getSetting("show_uploader"),
    duration = getSetting("show_duration"),
    rating = getSetting("show_rating"),
    tags = getSetting("show_tags"),
    playStats = getSetting("show_play_stats"),
  }
  warmCaches()
end

function warmCaches()
  for _, key in ipairs({
    "max_results", "show_uploader", "show_duration", "show_rating", "show_tags",
    "show_play_stats", "show_home_recent", "show_home_top", "show_home_tags",
    "show_home_artists", "show_home_playlists",
  }) do
    getSetting(key)
  end
  for _, key in ipairs({
    "actions.download_desc", "actions.play_url", "actions.save_url", "actions.save_url_mp3",
    "actions.stop_desc", "actions.stop_music", "artists.no_artists", "artists.no_match",
    "common.custom_url", "common.one_play", "common.untitled", "errors.last_error",
    "home.artist", "home.artists", "home.artists_desc", "home.most_played",
    "home.most_played_desc", "home.playlists", "home.playlists_desc", "home.recently_played",
    "home.recently_played_desc", "home.tags", "home.tags_desc", "import.create_playlist",
    "import.desc", "import.hint", "import.title", "library.empty", "library.empty_desc",
    "library.playlist_only", "library.saved", "library.saved_empty", "library.saved_tracks",
    "metadata.choose_track", "metadata.clear_value", "metadata.currently_empty",
    "metadata.edit", "metadata.edit_field", "metadata.field_editor",
    "metadata.header_description", "metadata.label", "metadata.type_new",
    "notices.added_playlist_to_queue", "notices.syncing_folder", "playlists.add_to",
    "playlists.choose_first", "playlists.create", "playlists.create_hint",
    "playlists.create_new", "playlists.delete", "playlists.none", "playlists.one_track",
    "playlists.rename", "playlists.rename_title", "playlists.rename_to",
    "playlists.synced_folder_description", "playlists.track_count", "playlists.type_different",
    "playlists.type_new_name", "playlists.untitled", "providers.mixcloud",
    "providers.soundcloud", "providers.youtube", "queue.active",
    "queue.autoplay_saved", "queue.autoplay_saved_desc", "queue.autoplay_saved_shuffle",
    "queue.autoplay_saved_shuffle_desc", "queue.clear", "queue.clear_empty", "queue.empty",
    "queue.empty_desc", "queue.idle", "queue.next_up", "queue.queued", "queue.skip_jump",
    "queue.skip_now", "queue.start_arm", "queue.start_now", "queue.stop_keep",
    "queue.stop_pause", "queue.title", "search.failed_default", "search.hint",
    "search.no_results", "search.searching", "search.type_more", "speed.current",
    "speed.desc", "speed.use_number", "status.background_playback", "status.now_playing",
    "status.ready", "status.starting", "tags.add", "tags.apply_to", "tags.choose_track",
    "tags.editor", "tags.header_description", "tags.hint", "tags.manage", "tags.no_tags",
    "tags.remove", "tags.remove_from", "tags.tag_count", "tooltip.add_to_queue",
    "tooltip.pause", "tooltip.rate", "tooltip.remove_from_library", "tooltip.remove_from_queue",
    "tooltip.resume", "tooltip.save_to_library", "tooltip.unrated",
  }) do
    tr(key)
  end
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function trim(text)
  return noctalia.string.trim(text or "")
end

local function clamp(value, min, max)
  if value < min then return min end
  if value > max then return max end
  return value
end

local function formatDuration(totalSeconds)
  local total = math.max(0, math.floor(tonumber(totalSeconds) or 0))
  local hours = math.floor(total / 3600)
  local minutes = math.floor((total % 3600) / 60)
  local seconds = total % 60
  if hours > 0 then
    return string.format("%d:%02d:%02d", hours, minutes, seconds)
  end
  return string.format("%d:%02d", minutes, seconds)
end

local function formatRelativeTime(timestamp)
  if not timestamp or timestamp == "" then return "" end
  local parts = { timestamp:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)") }
  if #parts ~= 6 then return "" end
  local past = os.time({
    year = tonumber(parts[1]), month = tonumber(parts[2]), day = tonumber(parts[3]),
    hour = tonumber(parts[4]), min = tonumber(parts[5]), sec = tonumber(parts[6]),
  })
  local seconds = math.max(0, os.time() - past)
  if seconds < 60 then return tr("time.just_now") end
  if seconds < 3600 then return tr("time.minutes_ago", { count = tostring(math.floor(seconds / 60)) }) end
  if seconds < 86400 then return tr("time.hours_ago", { count = tostring(math.floor(seconds / 3600)) }) end
  if seconds < 604800 then return tr("time.days_ago", { count = tostring(math.floor(seconds / 86400)) }) end
  return tr("time.weeks_ago", { count = tostring(math.floor(seconds / 604800)) })
end

local function playable()
  return snapshot ~= nil and snapshot.ready == true and snapshot.loading ~= true
end

local function playing()
  return playable() and snapshot.playing == true
end

local function paused()
  return playing() and snapshot.paused == true
end

local function currentProvider()
  return (snapshot and snapshot.provider) or "youtube"
end

local function dispatch(message)
  noctalia.state.set("music_command", message)
end

local function setQuery(text)
  launcher.setQuery(text)
end

local function addRow(rows, title, subtitle, glyph, score, action)
  rowIndex = rowIndex + 1
  local id = "row-" .. rowIndex
  rows[#rows + 1] = {
    id = id,
    title = title,
    subtitle = subtitle,
    glyph = glyph,
    score = score,
  }
  if action then
    actions[id] = action
  end
  return id
end

local function entrySubtitle(entry, isLibraryEntry)
  local config = rowCfg or {}
  local parts = {}
  if config.uploader ~= false and entry.uploader and entry.uploader ~= "" then
    parts[#parts + 1] = entry.uploader
  end
  if config.duration ~= false and entry.duration and entry.duration > 0 then
    parts[#parts + 1] = formatDuration(entry.duration)
  end
  if config.tags ~= false and entry.tags and #entry.tags > 0 then
    parts[#parts + 1] = table.concat(entry.tags, " ")
  end
  if config.rating ~= false and entry.rating and entry.rating > 0 then
    parts[#parts + 1] = tr("common.rating_stars", { rating = tostring(entry.rating) })
  end
  if isLibraryEntry and config.playStats ~= false then
    local plays = entry.playCount or 0
    if plays > 0 then
      parts[#parts + 1] = plays == 1 and tr("common.one_play") or tr("common.plays", { count = tostring(plays) })
    end
  end
  return table.concat(parts, "  ·  ")
end

local function libraryEntryById(id)
  if not snapshot then return nil end
  for _, entry in ipairs((snapshot or {}).library or {}) do
    if entry.id == id then return entry end
  end
  return nil
end

local function addEntryActionRows(rows, entry)
  local inLibrary = libraryEntryById(entry.id) ~= nil
  if inLibrary then
    addRow(rows, tr("tooltip.remove_from_library"), entrySubtitle(entry, true), "bookmark-remove", S.actions,
      function()
        dispatch({ action = "remove", payload = { id = entry.id } })
      end)
  else
    addRow(rows, tr("tooltip.save_to_library"), entrySubtitle(entry, false), "bookmark-plus", S.actions,
      function()
        dispatch({ action = "save", payload = { entry = entry } })
      end)
  end
  addRow(rows, tr("tooltip.add_to_queue"), entrySubtitle(entry, false), "playlist-plus", S.actions,
    function()
      dispatch({ action = "enqueue", payload = { entry = entry } })
    end)
  local rating = rateCounter[entry.id] or 0
  addRow(rows, tr("tooltip.rate", { rating = tostring(rating) }),
    entry.rating and entry.rating > 0 and tr("common.rating_stars", { rating = tostring(entry.rating) }) or tr("tooltip.unrated"),
    "star", S.actions, function()
      local nextRating = ((rateCounter[entry.id] or 0) % 5) + 1
      rateCounter[entry.id] = nextRating
      dispatch({ action = "rate", payload = { id = entry.id, rating = nextRating } })
    end)
  addRow(rows, tr("metadata.edit"), tr("metadata.label"), "pencil", S.actions, function()
    metadataEditorEntryId = entry.id
    metadataEditorField = nil
    setQuery("edit:")
  end)
  addRow(rows, tr("tags.manage"), tr("tags.header_description"), "tag", S.actions, function()
    tagEditorEntryId = entry.id
    setQuery("tag:")
  end)
  addRow(rows, tr("actions.download_desc"), entrySubtitle(entry, false), "download", S.actions,
    function()
      dispatch({ action = "download", payload = { entry = entry } })
    end)
end

local function addEntryRow(rows, entry, score, withActions)
  addRow(rows, entry.title or tr("common.untitled"), entrySubtitle(entry, true), "music", score,
    function()
      dispatch({ action = "play", payload = { entry = entry } })
    end)
  if withActions then
    addEntryActionRows(rows, entry)
  end
end

local function addPlaylistActionRows(rows, playlist)
  addRow(rows, tr("queue.start_now"), tr("queue.skip_jump"), "music", S.actions,
    function()
      dispatch({ action = "playlist_play", payload = { id = playlist.id, shuffle = false } })
    end)
  addRow(rows, tr("queue.autoplay_saved_shuffle"), tr("queue.autoplay_saved_shuffle_desc"), "shuffle", S.actions,
    function()
      dispatch({ action = "playlist_play", payload = { id = playlist.id, shuffle = true } })
    end)
  addRow(rows, tr("queue.queued"), tr("notices.added_playlist_to_queue"), "playlist-plus", S.actions,
    function()
      dispatch({ action = "playlist_queue", payload = { id = playlist.id, shuffle = false } })
    end)
  addRow(rows, tr("playlists.rename"), tr("playlists.rename_title"), "pencil", S.actions, function()
    renamePlaylistId = playlist.id
    renamePlaylistName = playlist.name or ""
    setQuery("playlist:rename:")
  end)
  addRow(rows, tr("playlists.delete"), tr("playlists.create_hint"), "delete", S.actions,
    function()
      dispatch({ action = "playlist_delete", payload = { id = playlist.id } })
    end)
  if playlist.sourceType == "folder" then
    addRow(rows, tr("notices.syncing_folder"), tr("playlists.synced_folder_description"), "refresh", S.actions,
      function()
        dispatch({ action = "playlist_sync", payload = { id = playlist.id } })
      end)
    addRow(rows, tr("library.playlist_only"), tr("playlists.synced_folder_description"), "folder", S.actions,
      function()
        dispatch({ action = "playlist_hide_local", payload = { id = playlist.id } })
      end)
  end
end

local function statusRow(rows)
  if not playable() then
    addRow(rows, tr("status.starting"), tr("status.background_playback"), "music", S.status)
    return
  end
  local current = snapshot.current or {}
  local title = tr("status.ready")
  if playing() then
    title = tr("status.now_playing") .. " · " .. (current.title or "")
  end
  local subtitle = ""
  if snapshot.lastError and snapshot.lastError ~= "" then
    subtitle = tr("errors.last_error", { error = snapshot.lastError })
  elseif snapshot.lastNotice and snapshot.lastNotice ~= "" then
    subtitle = snapshot.lastNotice
  else
    subtitle = tr("providers." .. (snapshot.provider or "youtube")) .. " · " .. tr("status.background_playback")
  end
  addRow(rows, title, subtitle, playing() and (paused() and "player-pause-filled" or "disc") or "music", S.status)
end

local function addPlaybackRows(rows)
  if not playing() then return end
  addRow(rows, paused() and tr("tooltip.resume") or tr("tooltip.pause"), tr("status.now_playing"),
    paused() and "play" or "pause", S.playback,
    function()
      dispatch({ action = "toggle" })
    end)
  addRow(rows, tr("actions.stop_music"), tr("actions.stop_desc"), "stop", S.playback,
    function()
      dispatch({ action = "stop" })
    end)
end

local function addQuickCommandRows(rows)
  addRow(rows, tr("queue.title"), tr("queue.next_up"), "music", S.quick, function()
    setQuery("queue")
  end)
  addRow(rows, tr("import.title"), tr("import.desc"), "folder-open", S.quick, function()
    setQuery("import:")
  end)
  addRow(rows, tr("speed.title"), tr("speed.desc"), "clock", S.quick, function()
    setQuery("speed:")
  end)
  addRow(rows, tr("tags.manage"), tr("tags.header_description"), "tag", S.quick, function()
    tagEditorEntryId = nil
    setQuery("tag:")
  end)
  addRow(rows, tr("metadata.edit"), tr("metadata.header_description"), "pencil", S.quick, function()
    metadataEditorEntryId = nil
    metadataEditorField = nil
    setQuery("edit:")
  end)
  addRow(rows, tr("playlists.create"), tr("playlists.create_hint"), "playlist", S.quick, function()
    playlistPickerEntryId = nil
    setQuery("playlist:")
  end)
  addRow(rows, tr("library.saved"), tr("library.saved_tracks"), "bookmark", S.quick, function()
    setQuery("saved:")
  end)
end

local function addHomeRows(rows)
  statusRow(rows)
  addPlaybackRows(rows)
  addQuickCommandRows(rows)
  local library = (snapshot or {}).library or {}
  local config = {
    recent = getSetting("show_home_recent"),
    top = getSetting("show_home_top"),
    tags = getSetting("show_home_tags"),
    artists = getSetting("show_home_artists"),
    playlists = getSetting("show_home_playlists"),
  }
  if config.recent ~= false then
    local recent = {}
    for _, entry in ipairs(library) do
      if entry.lastPlayedAt and entry.lastPlayedAt ~= "" then
        recent[#recent + 1] = entry
      end
    end
    table.sort(recent, function(a, b) return a.lastPlayedAt > b.lastPlayedAt end)
    if #recent > 0 then
      addRow(rows, tr("home.recently_played"), tr("home.recently_played_desc"), "history", S.header)
      local shown = 0
      for _, entry in ipairs(recent) do
        if shown >= 4 then break end
        shown = shown + 1
        addEntryRow(rows, entry, S.item, shown == 1)
      end
    end
  end
  if config.top ~= false then
    local top = {}
    for _, entry in ipairs(library) do
      if entry.playCount and entry.playCount > 0 then
        top[#top + 1] = entry
      end
    end
    table.sort(top, function(a, b) return a.playCount > b.playCount end)
    if #top > 0 then
      addRow(rows, tr("home.most_played"), tr("home.most_played_desc"), "fire", S.header)
      local shown = 0
      for _, entry in ipairs(top) do
        if shown >= 4 then break end
        shown = shown + 1
        addEntryRow(rows, entry, S.item, shown == 1)
      end
    end
  end
  if config.tags ~= false then
    local counts = {}
    for _, entry in ipairs(library) do
      for _, tag in ipairs(entry.tags or {}) do
        counts[tag] = (counts[tag] or 0) + 1
      end
    end
    local tags = {}
    for tag in pairs(counts) do
      tags[#tags + 1] = tag
    end
    table.sort(tags)
    if #tags > 0 then
      addRow(rows, tr("home.tags"), tr("home.tags_desc"), "tag", S.header)
      local shown = 0
      for _, tag in ipairs(tags) do
        if shown >= 6 then break end
        shown = shown + 1
        addRow(rows, tag, tr("tags.tag_count", { count = tostring(counts[tag]) }), "tag", S.item, function()
          setQuery("tag:" .. tag)
        end)
      end
    end
  end
  if config.artists ~= false then
    local artists = {}
    local seen = {}
    for _, entry in ipairs(library) do
      local artist = entry.uploader or ""
      if artist ~= "" and not seen[artist] then
        seen[artist] = true
        artists[#artists + 1] = artist
      end
    end
    table.sort(artists)
    if #artists > 0 then
      addRow(rows, tr("home.artists"), tr("home.artists_desc"), "account-music", S.header)
      local shown = 0
      for _, artist in ipairs(artists) do
        if shown >= 6 then break end
        shown = shown + 1
        addRow(rows, artist, tr("home.artists_desc"), "account-music", S.item, function()
          setQuery("artist:" .. artist)
        end)
      end
    end
  end
  if config.playlists ~= false then
    local playlists = (snapshot or {}).playlists or {}
    if #playlists > 0 then
      addRow(rows, tr("home.playlists"), tr("home.playlists_desc"), "playlist", S.header)
      local shown = 0
      for _, playlist in ipairs(playlists) do
        if shown >= 4 then break end
        shown = shown + 1
        local count = #(playlist.entryIds or {})
        addRow(rows, playlist.name or tr("playlists.untitled"),
          count == 1 and tr("playlists.one_track") or tr("playlists.track_count", { count = tostring(count) }),
          "playlist", S.item, function()
            setQuery("playlist:" .. (playlist.name or ""))
          end)
      end
    end
  end
end

local function parseSearchQuery(query)
  local name, rest = query:match("^(%a+):(.*)$")
  local provider
  if name == "yt" then
    provider = "youtube"
  elseif name == "sc" then
    provider = "soundcloud"
  elseif name == "local" then
    provider = "local"
  end
  if not provider then
    provider = currentProvider()
    rest = query
  end
  return provider, trim(rest)
end

local function isUrl(query)
  return query:match("^https?://") ~= nil
    or query:match("^file://") ~= nil
    or query:match("^magnet:") ~= nil
    or query:match("^/") ~= nil
    or query:match("^~/") ~= nil
end

local renderAll

local function searchResultRows(maxResults)
  local rows = {}
  if searchFailed then
    rows[1] = { id = "search-failed", title = tr("search.failed_default"), subtitle = tr("search.hint"), glyph = "alert-circle", score = S.header }
    return rows
  end
  if #searchResults == 0 then
    rows[1] = { id = "search-empty", title = tr("search.no_results"), subtitle = tr("search.hint"), glyph = "bell", score = S.header }
    return rows
  end
  for i, entry in ipairs(searchResults) do
    if i > maxResults then break end
    addRow(rows, entry.title or tr("common.untitled"), entrySubtitle(entry, false), "music", S.item, function()
      dispatch({ action = "play", payload = { entry = entry } })
    end)
  end
  return rows
end

local function startSearch(provider, searchText)
  searchBusy = true
  searchFailed = false
  lastSearchQuery = searchText
  local query = trim(lastQuery)
  local ok = noctalia.runAsync(
    "bash " .. shellQuote(helper) .. " search " .. shellQuote(searchText) .. " " .. shellQuote(provider),
    function(result)
      searchBusy = false
      searchFailed = result.exitCode ~= 0
      local decoded, list = pcall(noctalia.json.decode, result.stdout or "")
      searchResults = decoded and type(list) == "table" and list or {}
      lastCompletedQuery = searchText
      if pendingSearchQuery then
        local nextQuery = pendingSearchQuery
        pendingSearchQuery = nil
        startSearch(currentProvider(), nextQuery)
        return
      end
      if searchText == trim(lastQuery) then
        launcher.setResults(query, searchResultRows(getSetting("max_results", 8)))
      end
    end, 60000)
  if not ok then
    searchBusy = false
    searchFailed = true
    searchResults = {}
    lastCompletedQuery = searchText
  end
end

local function ensureSearch(provider, searchText)
  if searchText == lastCompletedQuery then
    renderAll(trim(lastQuery))
    return
  end
  if searchBusy then
    if searchText == lastSearchQuery then return end
    pendingSearchQuery = searchText
    return
  end
  startSearch(provider, searchText)
  renderAll(trim(lastQuery))
end

local function addSearchRows(rows, searchText)
  statusRow(rows)
  if #searchText < 2 then
    addRow(rows, tr("search.type_more", { count = "2" }), tr("search.hint"), "bell", S.header)
    return
  end
  if searchBusy then
    addRow(rows, tr("search.searching"), tr("providers." .. currentProvider()), "clock", S.header)
    return
  end
  if searchText ~= lastCompletedQuery then
    addRow(rows, tr("search.searching"), tr("providers." .. currentProvider()), "clock", S.header)
    return
  end
  if searchFailed then
    addRow(rows, tr("search.failed_default"), tr("search.hint"), "alert-circle", S.header)
    return
  end
  if #searchResults == 0 then
    addRow(rows, tr("search.no_results"), tr("search.hint"), "bell", S.header)
    return
  end
  local maxResults = getSetting("max_results", 8)
  local shown = 0
  for _, entry in ipairs(searchResults) do
    if shown >= maxResults then break end
    shown = shown + 1
    addEntryRow(rows, entry, S.item, false)
  end
end

local function addUrlRows(rows, query)
  statusRow(rows)
  addRow(rows, tr("actions.play_url"), query, "play-circle-outline", S.playback, function()
    dispatch({ action = "play_url", payload = { url = query } })
  end)
  addRow(rows, tr("actions.save_url"), query, "bookmark-plus", S.quick, function()
    dispatch({ action = "save_url", payload = { url = query } })
  end)
  addRow(rows, tr("actions.save_url_mp3"), query, "download", S.quick, function()
    dispatch({ action = "download", payload = { entry = { title = tr("common.custom_url"), url = query } } })
  end)
end

local function nextRepeatMode(mode)
  if mode == "off" then return "all" end
  if mode == "all" then return "one" end
  return "off"
end

local function addQueueRows(rows)
  statusRow(rows)
  local queueActive = (snapshot or {}).queueActive == true
  addRow(rows, tr("queue.title"), queueActive and tr("queue.active") or tr("queue.idle"),
    queueActive and "play" or "playlist", S.header)
  addRow(rows, tr("queue.start_now"), tr("queue.skip_jump"), "skip-next", S.playback, function()
    dispatch({ action = "queue_start", payload = { mode = "now" } })
  end)
  addRow(rows, tr("queue.start_arm"), tr("queue.start_arm"), "music", S.quick, function()
    dispatch({ action = "queue_start", payload = { mode = "arm" } })
  end)
  addRow(rows, tr("queue.autoplay_saved"), tr("queue.autoplay_saved_desc"), "bookmark", S.quick, function()
    dispatch({ action = "queue_start", payload = { mode = "saved" } })
  end)
  addRow(rows, tr("queue.autoplay_saved_shuffle"), tr("queue.autoplay_saved_shuffle_desc"), "shuffle", S.quick, function()
    dispatch({ action = "queue_start", payload = { mode = "saved_shuffle" } })
  end)
  addRow(rows, tr("queue.stop_keep"), tr("queue.stop_keep"), "stop", S.quick, function()
    dispatch({ action = "queue_stop", payload = { kind = "keep" } })
  end)
  addRow(rows, tr("queue.stop_pause"), tr("queue.stop_pause"), "stop-circle", S.quick, function()
    dispatch({ action = "queue_stop", payload = { kind = "pause" } })
  end)
  addRow(rows, tr("queue.skip_now"), tr("queue.skip_now"), "skip-next-circle", S.quick, function()
    dispatch({ action = "queue_skip" })
  end)
  addRow(rows, tr("queue.clear"), tr("queue.clear_empty"), "playlist-remove", S.quick, function()
    dispatch({ action = "queue_clear" })
  end)
  local repeatMode = (snapshot or {})["repeat"] or "off"
  addRow(rows, tr("queue.repeat"), tr("queue.repeat_hint"), "repeat", S.quick, function()
    dispatch({ action = "repeat", payload = { mode = nextRepeatMode(repeatMode) } })
  end)
  local shuffleOn = (snapshot or {}).shuffle == true
  addRow(rows, tr("queue.shuffle", { state = shuffleOn and tr("shuffle.on") or tr("shuffle.off") }),
    tr("queue.shuffle_hint"), "shuffle", S.quick, function()
      dispatch({ action = "shuffle", payload = { value = not shuffleOn } })
    end)
  local queue = (snapshot or {}).queue or {}
  if #queue == 0 then
    addRow(rows, tr("queue.empty"), tr("queue.empty_desc"), "bell", S.header)
    return
  end
  addRow(rows, tr("queue.next_up"), tr("queue.track_count", { count = tostring(#queue) }), "playlist", S.header)
  local shown = 0
  for _, entry in ipairs(queue) do
    shown = shown + 1
    addEntryRow(rows, entry, S.item, false)
    addRow(rows, tr("tooltip.remove_from_queue"), entry.title or tr("common.untitled"), "playlist-remove", S.actions,
      function()
        dispatch({ action = "queue_remove", payload = { id = entry.id } })
      end)
    if shown == 1 then
      addEntryActionRows(rows, entry)
    end
  end
end

local function addSavedRows(rows, filter)
  statusRow(rows)
  local library = (snapshot or {}).library or {}
  local matches = {}
  local lowered = string.lower(filter or "")
  for _, entry in ipairs(library) do
    if entry.isSaved ~= false then
      if lowered == "" or string.lower(entry.title or ""):find(lowered, 1, true)
        or string.lower(entry.uploader or ""):find(lowered, 1, true)
        or string.lower(entry.url or ""):find(lowered, 1, true) then
        matches[#matches + 1] = entry
      end
    end
  end
  if #matches == 0 then
    addRow(rows, tr("library.saved_empty"), tr("library.empty_desc"), "bell", S.header)
    return
  end
  addRow(rows, tr("library.saved"), tr("library.track_count", { count = tostring(#matches) }), "bookmark", S.header)
  local shown = 0
  for _, entry in ipairs(matches) do
    shown = shown + 1
    addEntryRow(rows, entry, S.item, shown == 1)
  end
end

local function addPlaylistRows(rows, rest)
  local playlists = (snapshot or {}).playlists or {}
  if rest:match("^create:") then
    local name = rest:sub(8)
    if name ~= "" then
      addRow(rows, tr("playlists.create") .. " \"" .. name .. "\"", tr("playlists.create_new"), "playlist-plus", S.playback,
        function()
          dispatch({ action = "playlist_create", payload = { name = name, entryId = playlistPickerEntryId } })
          playlistPickerEntryId = nil
        end)
    end
    addRow(rows, tr("playlists.choose_first"), tr("playlists.create_hint"), "arrow-left", S.quick, function()
      setQuery("playlist:")
    end)
    return
  end
  if rest:match("^rename:") then
    local name = rest:sub(8)
    if renamePlaylistId then
      if name ~= "" then
        addRow(rows, tr("playlists.rename_to", { name = name }), tr("playlists.rename_title"), "check", S.playback,
          function()
            dispatch({ action = "playlist_rename", payload = { id = renamePlaylistId, name = name } })
          end)
      end
      addRow(rows, tr("playlists.type_different"), tr("playlists.type_new_name"), "bell", S.quick)
    else
      addRow(rows, tr("playlists.choose_first"), tr("playlists.rename_title"), "bell", S.quick, function()
        setQuery("playlist:")
      end)
    end
    return
  end
  local exact = nil
  for _, playlist in ipairs(playlists) do
    if (playlist.name or "") == rest then exact = playlist end
  end
  if exact then
    local count = #(exact.entryIds or {})
    addRow(rows, exact.name or tr("playlists.untitled"),
      count == 1 and tr("playlists.one_track") or tr("playlists.track_count", { count = tostring(count) }),
      "playlist", S.header)
    addPlaylistActionRows(rows, exact)
    local byId = {}
    for _, entry in ipairs((snapshot or {}).library or {}) do
      byId[entry.id] = entry
    end
    local shown = 0
    for _, entryId in ipairs(exact.entryIds or {}) do
      local entry = byId[entryId]
      if entry then
        shown = shown + 1
        addEntryRow(rows, entry, S.item, shown == 1)
        addRow(rows, tr("tooltip.remove_from_queue"), tr("playlists.rename_title"), "playlist-remove", S.actions,
          function()
            dispatch({ action = "playlist_remove", payload = { id = exact.id, entryId = entryId } })
          end)
      end
    end
    return
  end
  if playlistPickerEntryId then
    addRow(rows, tr("playlists.add_to"), tr("playlists.create_new"), "playlist-plus", S.playback, function()
      setQuery("playlist:create:")
    end)
  else
    addRow(rows, tr("playlists.create"), tr("playlists.create_hint"), "playlist-plus", S.playback, function()
      setQuery("playlist:create:")
    end)
  end
  local lowered = string.lower(rest)
  local shown = 0
  for _, playlist in ipairs(playlists) do
    local name = playlist.name or ""
    if rest == "" or string.lower(name):find(lowered, 1, true) then
      shown = shown + 1
      local count = #(playlist.entryIds or {})
      addRow(rows, name,
        count == 1 and tr("playlists.one_track") or tr("playlists.track_count", { count = tostring(count) }),
        "playlist", S.item, function()
          if playlistPickerEntryId then
            dispatch({ action = "playlist_add", payload = { id = playlist.id, entryId = playlistPickerEntryId } })
            playlistPickerEntryId = nil
          else
            setQuery("playlist:" .. name)
          end
        end)
    end
  end
  if shown == 0 then
    addRow(rows, tr("playlists.none"), tr("playlists.create_hint"), "bell", S.header)
  end
end

local function addTagRows(rows, rest)
  local library = (snapshot or {}).library or {}
  if tagEditorEntryId then
    local entry = libraryEntryById(tagEditorEntryId)
    addRow(rows, tr("tags.editor"), entry and (entry.title or "") or "", "tag", S.header)
    if rest ~= "" then
      addRow(rows, tr("tags.add") .. ": " .. rest, tr("tags.choose_track"), "tag-plus", S.playback, function()
        dispatch({ action = "tag", payload = { id = tagEditorEntryId, tag = rest } })
      end)
      addRow(rows, tr("tags.remove") .. ": " .. rest, tr("tags.choose_track"), "tag-minus", S.quick, function()
        dispatch({ action = "untag", payload = { id = tagEditorEntryId, tag = rest } })
      end)
    end
    local tags = {}
    local entryTags = entry and entry.tags or {}
    for _, tag in ipairs(entryTags) do
      tags[#tags + 1] = { name = tag, applied = true }
    end
    local seen = {}
    for _, candidate in ipairs(library) do
      for _, tag in ipairs(candidate.tags or {}) do
        if not seen[tag] then
          seen[tag] = true
          local already = false
          for _, existing in ipairs(tags) do
            if existing.name == tag then already = true end
          end
          if not already then
            tags[#tags + 1] = { name = tag, applied = false }
          end
        end
      end
    end
    local lowered = string.lower(rest)
    for _, tag in ipairs(tags) do
      if rest == "" or string.lower(tag.name):find(lowered, 1, true) then
        addRow(rows, tag.name, tag.applied and tr("tags.remove_from") or tr("tags.apply_to"),
          tag.applied and "tag-minus" or "tag-plus", S.item,
          function()
            dispatch({ action = tag.applied and "untag" or "tag", payload = { id = tagEditorEntryId, tag = tag.name } })
          end)
      end
    end
    return
  end
  local tagCounts = {}
  for _, entry in ipairs(library) do
    for _, tag in ipairs(entry.tags or {}) do
      tagCounts[tag] = (tagCounts[tag] or 0) + 1
    end
  end
  local tags = {}
  for tag in pairs(tagCounts) do
    tags[#tags + 1] = tag
  end
  table.sort(tags)
  if rest ~= "" and tagCounts[rest] then
    addRow(rows, rest, tr("tags.tag_count", { count = tostring(tagCounts[rest]) }), "tag", S.header)
    local shown = 0
    for _, entry in ipairs(library) do
      for _, tag in ipairs(entry.tags or {}) do
        if tag == rest then
          shown = shown + 1
          addEntryRow(rows, entry, S.item, shown == 1)
          break
        end
      end
    end
    return
  end
  addRow(rows, tr("tags.manage"), tr("tags.header_description"), "tag", S.header)
  if rest ~= "" then
    addRow(rows, tr("tags.apply_to") .. ": " .. rest, tr("tags.choose_track"), "tag-plus", S.playback)
    local shown = 0
    for _, entry in ipairs(library) do
      shown = shown + 1
      addRow(rows, entry.title or tr("common.untitled"), entrySubtitle(entry, true), "music", S.item, function()
        dispatch({ action = "tag", payload = { id = entry.id, tag = rest } })
      end)
    end
  end
  local lowered = string.lower(rest)
  local shown = 0
  for _, tag in ipairs(tags) do
    if rest == "" or string.lower(tag):find(lowered, 1, true) then
      shown = shown + 1
      addRow(rows, tag, tr("tags.tag_count", { count = tostring(tagCounts[tag]) }), "tag", S.item, function()
        setQuery("tag:" .. tag)
      end)
    end
  end
  if shown == 0 and rest == "" then
    addRow(rows, tr("tags.no_tags"), tr("tags.hint"), "bell", S.header)
  end
end

local function addArtistRows(rows, rest)
  local library = (snapshot or {}).library or {}
  local lowered = string.lower(rest)
  local matches = {}
  for _, entry in ipairs(library) do
    local artist = entry.uploader or ""
    if artist ~= "" and (rest == "" or string.lower(artist):find(lowered, 1, true)) then
      matches[#matches + 1] = artist
    end
  end
  local artists = {}
  local seen = {}
  for _, artist in ipairs(matches) do
    if not seen[artist] then
      seen[artist] = true
      artists[#artists + 1] = artist
    end
  end
  table.sort(artists)
  if rest ~= "" and #artists == 1 and artists[1] == rest then
    addRow(rows, rest, tr("home.artist"), "account-music", S.header)
    local shown = 0
    for _, entry in ipairs(library) do
      if (entry.uploader or "") == rest then
        shown = shown + 1
        addEntryRow(rows, entry, S.item, shown == 1)
      end
    end
    return
  end
  addRow(rows, tr("home.artists"), tr("home.artists_desc"), "account-music", S.header)
  for _, artist in ipairs(artists) do
    addRow(rows, artist, tr("home.artists_desc"), "account-music", S.item, function()
      setQuery("artist:" .. artist)
    end)
  end
  if #artists == 0 then
    addRow(rows, tr("artists.no_artists"), tr("artists.no_match"), "bell", S.header)
  end
end

local function addMetadataRows(rows, rest)
  local library = (snapshot or {}).library or {}
  if metadataEditorEntryId then
    local entry = libraryEntryById(metadataEditorEntryId)
    addRow(rows, tr("metadata.field_editor"), entry and (entry.title or "") or "", "pencil", S.header)
    if not metadataEditorField then
      for _, field in ipairs({ "title", "artist", "album" }) do
        local label = tr("metadata." .. field .. "_field")
        addRow(rows, label, tr("metadata.edit_field", { field = label }), "pencil", S.item, function()
          metadataEditorField = field
          setQuery("edit:")
        end)
      end
      return
    end
    local field = metadataEditorField
    local label = tr("metadata." .. field .. "_field")
    local currentValue = entry and entry[field == "artist" and "uploader" or field] or ""
    if rest == "" and field ~= "album" then
      addRow(rows, tr("metadata.type_new"), label .. (currentValue ~= "" and (" · " .. currentValue) or ""), "pencil", S.quick)
      return
    end
    addRow(rows, tr("metadata.set_field", { field = label, value = rest == "" and tr("metadata.clear_value") or rest }),
      currentValue ~= "" and (label .. ": " .. currentValue) or tr("metadata.currently_empty"), "check", S.playback,
      function()
        dispatch({
          action = "edit_metadata",
          payload = { id = metadataEditorEntryId, field = field, value = rest },
        })
      end)
    return
  end
  addRow(rows, tr("metadata.label"), tr("metadata.choose_track"), "pencil", S.header)
  local lowered = string.lower(rest)
  local shown = 0
  for _, entry in ipairs(library) do
    if rest == "" or string.lower(entry.title or ""):find(lowered, 1, true)
      or string.lower(entry.uploader or ""):find(lowered, 1, true) then
      shown = shown + 1
      addRow(rows, entry.title or tr("common.untitled"), entrySubtitle(entry, true), "music", S.item, function()
        metadataEditorEntryId = entry.id
        metadataEditorField = nil
        setQuery("edit:")
      end)
    end
  end
  if shown == 0 then
    addRow(rows, tr("library.empty"), tr("library.empty_desc"), "bell", S.header)
  end
end

local function addImportRows(rows, rest)
  addRow(rows, tr("import.title"), tr("import.desc"), "folder-open", S.header)
  if rest ~= "" then
    local basename = rest:match("([^/]+)/*$") or ""
    addRow(rows, tr("import.title") .. ": " .. rest, tr("playlists.synced_folder_description"), "folder-plus", S.playback,
      function()
        dispatch({ action = "import_folder", payload = { path = rest, name = "" } })
      end)
    addRow(rows, tr("import.create_playlist"), tr("import.title") .. ": " .. rest, "folder-star", S.quick,
      function()
        dispatch({ action = "import_folder", payload = { path = rest, name = basename } })
      end)
  else
    addRow(rows, tr("import.hint"), tr("import.desc"), "bell", S.item)
  end
end

local function addSpeedRows(rows, rest)
  statusRow(rows)
  addRow(rows, tr("speed.title"), tr("speed.desc"), "clock", S.header)
  local currentSpeed = ((snapshot or {}).current or {}).speed or 1
  if rest == "" then
    addRow(rows, tr("speed.current", { speed = tostring(currentSpeed) }), tr("speed.use_number"), "clock", S.item)
    return
  end
  local value = tonumber(rest)
  if not value then
    addRow(rows, tr("speed.use_number"), tr("speed.desc"), "bell", S.item)
    return
  end
  value = clamp(value, 0.25, 4)
  addRow(rows, tr("speed.set_to", { speed = tostring(value) }),
    tr("speed.current", { speed = tostring(currentSpeed) }), "check", S.playback,
    function()
      dispatch({ action = "speed", payload = { value = value } })
    end)
end

renderAll = function(text)
  local tStart = os.clock()
  local query = trim(text)
  lastQuery = query
  rowIndex = 0
  actions = {}
  local rows = {}
  if query == "" then
    addHomeRows(rows)
  elseif query == "queue" then
    addQueueRows(rows)
  elseif query:match("^saved:") then
    addSavedRows(rows, query:sub(7))
  elseif query:match("^playlist:") then
    addPlaylistRows(rows, query:sub(10))
  elseif query:match("^tag:") then
    addTagRows(rows, query:sub(5))
  elseif query:match("^#") then
    addTagRows(rows, query:sub(2))
  elseif query:match("^artist:") then
    addArtistRows(rows, query:sub(8))
  elseif query:match("^edit:") then
    addMetadataRows(rows, query:sub(6))
  elseif query:match("^import:") then
    addImportRows(rows, query:sub(8))
  elseif query:match("^speed:") then
    addSpeedRows(rows, query:sub(7))
  elseif isUrl(query) then
    addUrlRows(rows, query)
  else
    local provider, searchText = parseSearchQuery(query)
    if searchText == "" then
      addHomeRows(rows)
    else
      addSearchRows(rows, searchText)
      if playable() then
        ensureSearch(provider, searchText)
      end
    end
  end
  local tRows = os.clock()
  launcher.setResults(query, rows)
  noctalia.log("music-search: renderAll rows=" .. tostring(#rows) .. " build=" .. string.format("%.2f", (tRows - tStart) * 1000) .. "ms set=" .. string.format("%.2f", (os.clock() - tRows) * 1000) .. "ms")
end

function onQuery(text)
  snapshot = noctalia.state.get("music_snapshot")
  renderAll(text)
end

function onActivate(id)
  local action = actions[id]
  actions = {}
  if action then
    action()
  end
end

warmCaches()
renderAll("")
