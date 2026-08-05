--!nonstrict

local helper = ((noctalia.pluginDir() or ""):gsub("/+$", "")) .. "/musicctl.sh"
local cacheDir = noctalia.expandPath(noctalia.getenv("XDG_CACHE_HOME") or "~/.cache") .. "/noctalia/plugins/music-search"
local libraryFile = cacheDir .. "/library.json"
local dataDir = noctalia.pluginDataDir() or cacheDir
local queueActiveFile = dataDir .. "/queue-active.json"

local snapshot = {
  ready = false,
  loading = true,
  playing = false,
  paused = false,
  provider = "youtube",
  sortBy = "date",
  volume = 100,
  ["repeat"] = "off",
  shuffle = false,
  current = {
    id = "", title = "", url = "", uploader = "",
    duration = 0, speed = 1, pid = 0, error = "", endReason = "", updatedAt = "",
  },
  library = {},
  playlists = {},
  queue = {},
  queueActive = false,
  busy = {},
  lastError = "",
  lastNotice = "",
}

local queueState = {
  active = false,
  launching = false,
  pendingLaunch = nil,
  lastHandledUpdate = "0",
}

local radioState = {
  busy = false,
  entries = {},
  index = 0,
}

local history = {}

local cfg = {}
local ready = false
local lastPublished = ""
local tick = 0
local positionBusy = false
local statusBusy = false
local autoSaveBusy = false
local autoSavedId = ""
local thumbnailBusy = false
local thumbnailRecoveredFor = ""
local commandsInFlight = 0
local stuckSince = 0

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function run(args, onDone)
  commandsInFlight = commandsInFlight + 1
  local cmd = "bash " .. shellQuote(helper)
  for _, arg in ipairs(args) do
    cmd = cmd .. " " .. shellQuote(arg)
  end
  noctalia.runAsync(cmd, function(result)
    commandsInFlight = commandsInFlight - 1
    if onDone then
      local ok, err = pcall(onDone, result)
      if not ok then
        print("music-search: command callback failed: " .. tostring(err))
      end
    end
  end, 60000)
end

local function decode(text)
  if not text or text == "" then return nil end
  local ok, value = pcall(noctalia.json.decode, text)
  if not ok then return nil end
  return value
end

local function publish()
  snapshot.ready = ready
  snapshot.loading = not ready
  snapshot.queueActive = queueState.active
  local enc = noctalia.json.encode(snapshot) or ""
  if enc ~= lastPublished then
    lastPublished = enc
    noctalia.state.set("music_snapshot", snapshot)
  end
end

local function setNotice(key, args)
  snapshot.lastNotice = noctalia.tr(key, args or {})
end

local function lastErrorFrom(result, fallbackKey)
  local message = noctalia.string.trim(result.stderr or "")
  if message == "" then message = noctalia.tr(fallbackKey) end
  return message
end

local recoverThumbnail

local function applyStateJson(text)
  local state = decode(text)
  if not state or type(state) ~= "table" or type(state.isPlaying) ~= "boolean" then
    return nil
  end
  snapshot.playing = state.isPlaying
  snapshot.paused = state.isPaused == true
  snapshot.current = {
    id = state.id or "",
    title = state.title or "",
    url = state.url or "",
    uploader = state.uploader or "",
    duration = tonumber(state.duration) or 0,
    speed = tonumber(state.speed) or 1,
    pid = tonumber(state.pid) or 0,
    error = state.error or "",
    endReason = state.endReason or "",
    updatedAt = state.updatedAt or "",
    thumbnail = ((snapshot.current or {}).id == state.id)
        and ((snapshot.current or {}).thumbnail or "") or "",
  }
  if not snapshot.playing then
    snapshot.paused = false
  end
  recoverThumbnail()
  return state
end

recoverThumbnail = function()
  local current = snapshot.current or {}
  if thumbnailBusy or current.thumbnail ~= "" or not snapshot.playing then return end
  if current.id == "" or current.id == thumbnailRecoveredFor then return end
  thumbnailRecoveredFor = current.id
  thumbnailBusy = true
  local url = current.url
  run({ "details", url }, function(result)
    thumbnailBusy = false
    if result.exitCode == 0 then
      local entry = decode(result.stdout)
      if entry and entry.thumbnail and entry.thumbnail ~= "" then
        snapshot.current.thumbnail = entry.thumbnail
        publish()
      end
    end
  end)
end

local function applyLibraryJson(text)
  local library = decode(text)
  if type(library) == "table" then snapshot.library = library end
end

local function applyPlaylistsJson(text)
  local playlists = decode(text)
  if type(playlists) == "table" then snapshot.playlists = playlists end
end

local function applyQueueJson(text)
  local queue = decode(text)
  if type(queue) == "table" then snapshot.queue = queue end
end

local function applySettingsJson(text)
  local settings = decode(text)
  if type(settings) ~= "table" then return end
  if type(settings.activeProvider) == "string" then
    snapshot.provider = settings.activeProvider
  end
  if type(settings.sortBy) == "string" then
    snapshot.sortBy = settings.sortBy
  end
  if type(settings.volume) == "number" then
    snapshot.volume = math.max(0, math.min(100, math.floor(settings.volume)))
  end
  if settings.repeatMode == "off" or settings.repeatMode == "all" or settings.repeatMode == "one" then
    snapshot["repeat"] = settings.repeatMode
  end
  if type(settings.shuffle) == "boolean" then
    snapshot.shuffle = settings.shuffle
  end
end

local function persistQueueActive()
  local ok = noctalia.writeFile(queueActiveFile, noctalia.json.encode({ active = queueState.active }) or "{}")
  return ok
end

local function loadQueueActive()
  local contents = noctalia.readFile(queueActiveFile)
  if not contents then return end
  local data = decode(contents)
  if type(data) == "table" and data.active == true then
    queueState.active = true
  end
end

local function pushHistory(entry)
  if not entry or entry.id == "" then return end
  if #history > 0 and history[#history].id == entry.id then return end
  history[#history + 1] = {
    id = entry.id, title = entry.title or "", url = entry.url or "",
    uploader = entry.uploader or "", duration = entry.duration or 0,
    thumbnail = entry.thumbnail or "",
  }
  if #history > 30 then
    table.remove(history, 1)
  end
end

local maybeAutoSave

local function playEntry(entry, fromQueue, fromRadio)
  snapshot.busy.play = true
  snapshot.lastError = ""
  publish()
  run({
    "play",
    entry.id or "",
    entry.title or "",
    entry.url or "",
    entry.uploader or "",
    tostring(entry.duration or 0),
  }, function(result)
    snapshot.busy.play = false
    local previous = snapshot.current or {}
    local state = applyStateJson(result.stdout)
    local started = state ~= nil and (snapshot.current or {}).id ~= ""
      and (snapshot.current or {}).id ~= previous.id
    if started then
      pushHistory(previous)
    end
    if not fromRadio then
      radioState.entries = {}
      radioState.index = 0
    end
    snapshot.current.thumbnail = entry.thumbnail or ""
    if result.exitCode ~= 0 then
      snapshot.lastError = lastErrorFrom(result, "errors.playback_failed")
    elseif not state then
      snapshot.lastError = noctalia.tr("errors.playback_failed")
    elseif started and snapshot.playing then
      local current = snapshot.current or {}
      noctalia.notify(
        current.title or "",
        (current.uploader and current.uploader ~= "") and current.uploader
          or noctalia.tr("queue.now_playing")
      )
    end
    if fromQueue and queueState.pendingLaunch and snapshot.playing
      and snapshot.current.id == queueState.pendingLaunch.id then
      queueState.launching = false
      local launched = queueState.pendingLaunch
      queueState.pendingLaunch = nil
      snapshot.lastNotice = noctalia.tr("queue.now_playing")
      if snapshot["repeat"] == "all" and launched.url and launched.url ~= "" then
        run({
          "queue-enqueue", launched.id, launched.title, launched.url,
          launched.uploader, tostring(launched.duration or 0), "true",
        }, function(recycled)
          if recycled.exitCode == 0 then applyQueueJson(recycled.stdout) end
          publish()
        end)
      else
        run({ "queue-remove", launched.id }, function(removed)
          if removed.exitCode == 0 then applyQueueJson(removed.stdout) end
          publish()
        end)
      end
    elseif fromQueue then
      queueState.launching = false
      queueState.pendingLaunch = nil
    end
    publish()
    maybeAutoSave(entry)
  end)
end

maybeAutoSave = function(entry)
  if not cfg.autoSave or autoSaveBusy then return end
  if not entry or entry.id == "" or entry.id == autoSavedId then return end
  autoSaveBusy = true
  run({ "download-mp3", entry.title or "", entry.url or "" }, function(result)
    autoSaveBusy = false
    if result.exitCode == 0 then
      autoSavedId = entry.id
      setNotice("notices.saved_mp3_to", { folder = cfg.downloadDir })
      publish()
    end
  end)
end

local function launchNextQueue()
  if #snapshot.queue == 0 then
    queueState.active = false
    queueState.lastHandledUpdate = "0"
    persistQueueActive()
    setNotice("queue.no_next")
    publish()
    return
  end
  local entry = snapshot.queue[1]
  queueState.launching = true
  queueState.pendingLaunch = {
    id = entry.id, title = entry.title, url = entry.url,
    uploader = entry.uploader, duration = entry.duration,
  }
  playEntry(entry, true)
end

local radioNext

local function handleEnded(state)
  if queueState.launching or snapshot.playing then return end
  if state.endReason ~= "finished" and state.endReason ~= "error" then return end
  if not state.updatedAt or state.updatedAt == queueState.lastHandledUpdate then return end
  queueState.lastHandledUpdate = state.updatedAt
  local ended = snapshot.current or {}
  if snapshot["repeat"] == "one" and state.endReason == "finished"
    and ended.id ~= "" and ended.url ~= "" then
    playEntry({
      id = ended.id,
      title = ended.title or "",
      url = ended.url or "",
      uploader = ended.uploader or "",
      duration = ended.duration or 0,
      thumbnail = ended.thumbnail or "",
    }, false)
    return
  end
  if queueState.active then
    launchNextQueue()
    return
  end
  if #radioState.entries > 0 and radioState.index < #radioState.entries then
    radioNext()
  end
end

local actionResume
local function actionStop()
  if not snapshot.playing then
    setNotice("actions.already_stopped")
    publish()
    return
  end
  snapshot.busy.stop = true
  publish()
  run({ "stop" }, function(result)
    snapshot.busy.stop = false
    if result.exitCode == 0 then
      applyStateJson(result.stdout)
      setNotice("notices.stopped")
    else
      snapshot.lastError = lastErrorFrom(result, "errors.playback_failed")
    end
    publish()
  end)
end

local function actionPause()
  if not snapshot.playing then return end
  if snapshot.paused then
    actionResume()
    return
  end
  snapshot.busy.pause = true
  publish()
  run({ "pause" }, function(result)
    snapshot.busy.pause = false
    if result.exitCode == 0 then
      applyStateJson(result.stdout)
      setNotice("notices.paused")
    else
      snapshot.lastError = lastErrorFrom(result, "errors.playback_failed")
    end
    publish()
  end)
end

actionResume = function()
  if not snapshot.playing or not snapshot.paused then return end
  snapshot.busy.resume = true
  publish()
  run({ "resume" }, function(result)
    snapshot.busy.resume = false
    if result.exitCode == 0 then
      applyStateJson(result.stdout)
      setNotice("notices.resumed")
    else
      snapshot.lastError = lastErrorFrom(result, "errors.playback_failed")
    end
    publish()
  end)
end

local function actionToggle()
  if not snapshot.playing then return end
  if snapshot.paused then
    actionResume()
  else
    actionPause()
  end
end

local function actionSeek(value)
  if not snapshot.playing and (snapshot.current or {}).id == "" then
    setNotice("speed.no_playback")
    publish()
    return
  end
  snapshot.busy.seek = true
  publish()
  run({ "seek", tostring(value) }, function(result)
    snapshot.busy.seek = false
    if result.exitCode ~= 0 then
      snapshot.lastError = lastErrorFrom(result, "errors.seek_failed")
    end
    publish()
  end)
end

local function actionSpeed(value)
  if not snapshot.playing then
    setNotice("speed.no_playback")
    publish()
    return
  end
  snapshot.busy.speed = true
  publish()
  run({ "speed", tostring(value) }, function(result)
    snapshot.busy.speed = false
    if result.exitCode == 0 then
      applyStateJson(result.stdout)
      setNotice("speed.set_to", { speed = tostring(value) })
    else
      snapshot.lastError = lastErrorFrom(result, "errors.speed_failed")
    end
    publish()
  end)
end

local function actionVolume(value)
  local volume = tonumber(value)
  if not volume or volume ~= volume then volume = snapshot.volume or 100 end
  volume = math.max(0, math.min(100, math.floor(volume)))
  snapshot.busy.volume = true
  publish()
  run({ "set-volume", tostring(volume) }, function(result)
    snapshot.busy.volume = false
    if result.exitCode == 0 then
      applySettingsJson(result.stdout)
      setNotice("volume.set", { volume = tostring(volume) })
    else
      snapshot.lastError = lastErrorFrom(result, "errors.volume_failed")
    end
    publish()
  end)
end

local function setRepeat(mode)
  if mode ~= "off" and mode ~= "all" and mode ~= "one" then return end
  snapshot.busy["repeat"] = true
  publish()
  run({ "set-repeat", mode }, function(result)
    snapshot.busy["repeat"] = false
    if result.exitCode == 0 then
      applySettingsJson(result.stdout)
      setNotice("repeat.set", { mode = noctalia.tr("repeat." .. mode) })
    else
      snapshot.lastError = lastErrorFrom(result, "errors.repeat_failed")
    end
    publish()
  end)
end

local function setShuffle(value)
  local shuffle = value == true or value == "true"
  snapshot.busy.queue = true
  snapshot.lastError = ""
  publish()
  run({ "set-shuffle", shuffle and "true" or "false" }, function(result)
    if result.exitCode ~= 0 then
      snapshot.busy.queue = false
      snapshot.lastError = lastErrorFrom(result, "errors.queue_failed")
      publish()
      return
    end
    applySettingsJson(result.stdout)
    if not shuffle then
      snapshot.busy.queue = false
      setNotice("shuffle.set", { state = noctalia.tr("shuffle." .. (shuffle and "on" or "off")) })
      publish()
      return
    end
    run({ "queue-shuffle" }, function(queueResult)
      snapshot.busy.queue = false
      if queueResult.exitCode == 0 then applyQueueJson(queueResult.stdout) end
      setNotice("shuffle.set", { state = noctalia.tr("shuffle.on") })
      publish()
    end)
  end)
end

local function mutation(args, busyKey, errorKey, noticeKey, noticeArgs, dataKind)
  snapshot.busy[busyKey] = true
  snapshot.lastError = ""
  publish()
  run(args, function(result)
    snapshot.busy[busyKey] = false
    if result.exitCode ~= 0 then
      snapshot.lastError = lastErrorFrom(result, errorKey)
    else
      if dataKind == "library" then applyLibraryJson(result.stdout)
      elseif dataKind == "playlists" then applyPlaylistsJson(result.stdout)
      elseif dataKind == "queue" then applyQueueJson(result.stdout)
      elseif dataKind == "settings" then applySettingsJson(result.stdout)
      end
      if noticeKey then setNotice(noticeKey, noticeArgs) end
    end
    publish()
  end)
end

local function refreshLibrary()
  run({ "library" }, function(result)
    if result.exitCode == 0 then applyLibraryJson(result.stdout) end
    publish()
  end)
end

local function refreshPlaylists()
  run({ "playlists" }, function(result)
    if result.exitCode == 0 then applyPlaylistsJson(result.stdout) end
    publish()
  end)
end

local function refreshAll()
  run({ "library" }, function(first)
    if first.exitCode == 0 then applyLibraryJson(first.stdout) end
    run({ "playlists" }, function(second)
      if second.exitCode == 0 then applyPlaylistsJson(second.stdout) end
      run({ "queue-list" }, function(third)
        if third.exitCode == 0 then applyQueueJson(third.stdout) end
        run({ "status" }, function(fourth)
          if fourth.exitCode == 0 then
            local state = applyStateJson(fourth.stdout)
            if state then handleEnded(state) end
          end
          publish()
        end)
      end)
    end)
  end)
end

local function playUrl(url, fromRadio)
  if not url or url == "" then return end
  snapshot.busy.play = true
  snapshot.lastError = ""
  publish()
  run({ "details", url }, function(result)
    if result.exitCode ~= 0 then
      snapshot.busy.play = false
      snapshot.lastError = lastErrorFrom(result, "errors.playback_failed")
      publish()
      return
    end
    local entry = decode(result.stdout)
    if not entry or type(entry) ~= "table" or not entry.url then
      snapshot.busy.play = false
      snapshot.lastError = noctalia.tr("errors.search_malformed")
      publish()
      return
    end
    playEntry({
      id = entry.id or "",
      title = entry.title or url,
      url = entry.url or url,
      uploader = entry.uploader or "",
      duration = tonumber(entry.duration) or 0,
      thumbnail = entry.thumbnail or "",
    }, false, fromRadio == true)
  end)
end

local function saveUrl(url)
  if not url or url == "" then return end
  mutation({ "save-url", url }, "save", "errors.library_failed", "notices.library_updated", nil, "library")
end

local function queueStart(mode)
  if mode == "saved" or mode == "saved_shuffle" then
    local shuffle = mode == "saved_shuffle"
    snapshot.busy.queue = true
    snapshot.lastError = ""
    setNotice(shuffle and "queue.loading_shuffled_saved" or "queue.loading_saved")
    publish()
    run({ "queue-load-library", libraryFile, shuffle and "shuffle" or "ordered" }, function(result)
      snapshot.busy.queue = false
      if result.exitCode ~= 0 then
        snapshot.lastError = lastErrorFrom(result, "errors.queue_failed")
      else
        applyQueueJson(result.stdout)
        if #snapshot.queue == 0 then
          setNotice("queue.loaded_empty")
        else
          queueState.active = true
          persistQueueActive()
          if snapshot.playing then
            queueState.lastHandledUpdate = snapshot.current.updatedAt or "0"
            setNotice(shuffle and "queue.playing_shuffled_saved" or "queue.playing_saved")
          else
            setNotice("queue.armed")
          end
        end
      end
      publish()
    end)
    return
  end
  if #snapshot.queue == 0 then
    setNotice("queue.empty")
    publish()
    return
  end
  queueState.active = true
  persistQueueActive()
  if mode == "now" or not snapshot.playing then
    launchNextQueue()
  else
    queueState.lastHandledUpdate = snapshot.current.updatedAt or "0"
    setNotice("queue.armed")
    publish()
  end
end

local function queueStop(kind)
  queueState.active = false
  queueState.lastHandledUpdate = "0"
  persistQueueActive()
  if kind == "pause" and snapshot.playing then
    actionPause()
  end
  setNotice("queue.stopped")
  publish()
end

local function queueSkip()
  if #snapshot.queue == 0 then
    setNotice("queue.no_next")
    publish()
    return
  end
  launchNextQueue()
end

local function playRadioEntry(entry)
  if not entry or entry.url == "" then
    setNotice("radio.no_related")
    publish()
    return
  end
  playUrl(entry.url, true)
end

radioNext = function()
  if radioState.busy then return end
  if #radioState.entries == 0 then
    local url = (snapshot.current or {}).url or ""
    if url == "" then
      setNotice("radio.no_track")
      publish()
      return
    end
    radioState.busy = true
    setNotice("radio.loading")
    publish()
    run({ "radio", url }, function(result)
      radioState.busy = false
      local decoded, entries = pcall(noctalia.json.decode, result.stdout or "")
      radioState.entries = (decoded and type(entries) == "table") and entries or {}
      radioState.index = 0
      if result.exitCode ~= 0 or #radioState.entries == 0 then
        setNotice("radio.no_related")
        publish()
        return
      end
      playRadioEntry(radioState.entries[1])
    end)
    return
  end
  if radioState.index >= #radioState.entries then
    setNotice("radio.ended")
    publish()
    return
  end
  radioState.index = radioState.index + 1
  playRadioEntry(radioState.entries[radioState.index])
end

local function actionNext()
  if #snapshot.queue > 0 then
    queueSkip()
    return
  end
  radioNext()
end

local function actionPrev()
  if #history > 0 then
    local entry = table.remove(history)
    playEntry(entry, false)
    return
  end
  if snapshot.playing then
    run({ "seek", "0" }, function(result)
      if result.exitCode ~= 0 then
        snapshot.lastError = lastErrorFrom(result, "errors.seek_failed")
        publish()
      end
    end)
    return
  end
  setNotice("radio.no_prev")
  publish()
end

local function queueEnqueue(entry)
  local isSaved = entry.isSaved == true and "true" or "false"
  mutation({
    "queue-enqueue",
    entry.id or "",
    entry.title or "",
    entry.url or "",
    entry.uploader or "",
    tostring(entry.duration or 0),
    isSaved,
  }, "queue", "errors.queue_failed", "notices.added_to_queue", nil, "queue")
end

local function queueRemove(id)
  mutation({ "queue-remove", id }, "queue", "errors.queue_failed", "queue.removed", nil, "queue")
end

local function queueClear()
  mutation({ "queue-clear" }, "queue", "errors.queue_failed", "queue.cleared", nil, "queue")
end

local function playlistCreate(name, entryId)
  snapshot.busy.playlists = true
  snapshot.lastError = ""
  publish()
  run({ "create-playlist", name }, function(created)
    if created.exitCode ~= 0 then
      snapshot.busy.playlists = false
      snapshot.lastError = lastErrorFrom(created, "errors.library_failed")
      publish()
      return
    end
    applyPlaylistsJson(created.stdout)
    if entryId then
      local target = nil
      for _, playlist in ipairs(snapshot.playlists) do
        if playlist.name == name then target = playlist.id end
      end
      if target then
        run({ "playlist-add", target, entryId }, function(added)
          snapshot.busy.playlists = false
          if added.exitCode == 0 then
            applyPlaylistsJson(added.stdout)
            setNotice("notices.library_updated")
          else
            snapshot.lastError = lastErrorFrom(added, "errors.library_failed")
          end
          publish()
        end)
        return
      end
    end
    snapshot.busy.playlists = false
    setNotice("notices.playlists_updated")
    publish()
  end)
end

local function playlistDelete(id)
  mutation({ "delete-playlist", id }, "playlists", "errors.library_failed", "notices.playlists_updated", nil, "playlists")
end

local function playlistRename(id, name)
  mutation({ "rename-playlist", id, name }, "playlists", "errors.library_failed", "notices.playlists_updated", nil, "playlists")
end

local function playlistAdd(id, entryId)
  mutation({ "playlist-add", id, entryId }, "playlists", "errors.library_failed", "notices.library_updated", nil, "playlists")
end

local function playlistRemove(id, entryId)
  mutation({ "playlist-remove", id, entryId }, "playlists", "errors.library_failed", "notices.playlists_updated", nil, "playlists")
end

local function playlistHideLocal(id)
  snapshot.busy.playlists = true
  publish()
  run({ "playlist-hide-local-from-saved", id }, function(result)
    snapshot.busy.playlists = false
    if result.exitCode == 0 then
      refreshLibrary()
    else
      snapshot.lastError = lastErrorFrom(result, "errors.library_failed")
      publish()
    end
  end)
end

local function playlistSync(id)
  snapshot.busy.playlists = true
  setNotice("notices.syncing_folder")
  publish()
  run({ "sync-folder-playlist", id }, function(result)
    snapshot.busy.playlists = false
    if result.exitCode ~= 0 then
      snapshot.lastError = lastErrorFrom(result, "errors.library_failed")
      publish()
      return
    end
    run({ "library" }, function(lib)
      if lib.exitCode == 0 then applyLibraryJson(lib.stdout) end
      refreshPlaylists()
    end)
  end)
end

local function importFolder(path, name)
  snapshot.busy.import = true
  setNotice("notices.importing_folder")
  publish()
  run({ "import-folder-playlist", path, name or "" }, function(result)
    snapshot.busy.import = false
    if result.exitCode ~= 0 then
      snapshot.lastError = lastErrorFrom(result, "errors.folder_import_failed")
      publish()
      return
    end
    setNotice("notices.folder_imported")
    run({ "library" }, function(lib)
      if lib.exitCode == 0 then applyLibraryJson(lib.stdout) end
      refreshPlaylists()
    end)
  end)
end

local function libraryEntriesForPlaylist(playlistId, shuffle)
  local playlist = nil
  for _, candidate in ipairs(snapshot.playlists) do
    if candidate.id == playlistId then playlist = candidate end
  end
  if not playlist then return {} end
  local ids = playlist.entryIds or {}
  local byId = {}
  for _, entry in ipairs(snapshot.library) do
    byId[entry.id] = entry
  end
  local entries = {}
  for _, id in ipairs(ids) do
    local entry = byId[id]
    if entry and entry.url and entry.url ~= "" then
      entries[#entries + 1] = { id = id, title = entry.title, url = entry.url, uploader = entry.uploader, duration = entry.duration }
    end
  end
  if shuffle then
    for i = #entries, 2, -1 do
      local j = math.random(1, i)
      entries[i], entries[j] = entries[j], entries[i]
    end
  end
  return entries
end

local function playlistBuildQueue(playlistId, shuffle, startNow, noticeKey)
  local entries = libraryEntriesForPlaylist(playlistId, shuffle)
  if #entries == 0 then
    setNotice("notices.playlist_empty")
    publish()
    return
  end
  snapshot.busy.queue = true
  snapshot.lastError = ""
  publish()
  run({ "queue-clear" }, function(cleared)
    if cleared.exitCode ~= 0 then
      snapshot.busy.queue = false
      snapshot.lastError = lastErrorFrom(cleared, "errors.queue_failed")
      publish()
      return
    end
    local index = 0
    local function enqueueNext()
      index = index + 1
      if index > #entries then
        snapshot.busy.queue = false
        queueState.active = true
        persistQueueActive()
        setNotice(noticeKey)
        publish()
        if startNow then
          launchNextQueue()
        else
          queueState.lastHandledUpdate = snapshot.current.updatedAt or "0"
        end
        return
      end
      local entry = entries[index]
      run({
        "queue-enqueue", entry.id, entry.title, entry.url, entry.uploader,
        tostring(entry.duration), "true",
      }, function(enqueued)
        if enqueued.exitCode == 0 then
          applyQueueJson(enqueued.stdout)
        else
          snapshot.busy.queue = false
          snapshot.lastError = lastErrorFrom(enqueued, "errors.queue_failed")
          publish()
          return
        end
        enqueueNext()
      end)
    end
    enqueueNext()
  end)
end

local function dispatch(message)
  local action = message.action
  local p = message.payload or {}
  if action == "play" then
    playEntry(p.entry or {}, false)
  elseif action == "play_url" then
    playUrl(p.url)
  elseif action == "stop" then
    actionStop()
  elseif action == "pause" then
    actionPause()
  elseif action == "resume" then
    actionResume()
  elseif action == "toggle" then
    actionToggle()
  elseif action == "next" then
    actionNext()
  elseif action == "prev" then
    actionPrev()
  elseif action == "seek" then
    actionSeek(p.position)
  elseif action == "speed" then
    actionSpeed(p.value)
  elseif action == "volume" then
    actionVolume(p.value)
  elseif action == "repeat" then
    setRepeat(p.mode)
  elseif action == "shuffle" then
    setShuffle(p.value)
  elseif action == "save" then
    mutation({
      "save", p.entry.id or "", p.entry.title or "", p.entry.url or "",
      p.entry.uploader or "", tostring(p.entry.duration or 0),
    }, "save", "errors.library_failed", "notices.library_updated", nil, "library")
  elseif action == "save_url" then
    saveUrl(p.url)
  elseif action == "download" then
    mutation({ "download-mp3", p.entry.title or "", p.entry.url or "" }, "download",
      "errors.mp3_save_failed", "notices.saved_mp3", nil, nil)
  elseif action == "remove" then
    mutation({ "remove", p.id }, "save", "errors.library_failed", "notices.library_updated", nil, "library")
  elseif action == "enqueue" then
    queueEnqueue(p.entry or {})
  elseif action == "queue_remove" then
    queueRemove(p.id)
  elseif action == "queue_clear" then
    queueClear()
  elseif action == "queue_start" then
    queueStart(p.mode or "now")
  elseif action == "queue_stop" then
    queueStop(p.kind or "keep")
  elseif action == "queue_skip" then
    queueSkip()
  elseif action == "playlist_create" then
    playlistCreate(p.name, p.entryId)
  elseif action == "playlist_delete" then
    playlistDelete(p.id)
  elseif action == "playlist_rename" then
    playlistRename(p.id, p.name)
  elseif action == "playlist_add" then
    playlistAdd(p.id, p.entryId)
  elseif action == "playlist_remove" then
    playlistRemove(p.id, p.entryId)
  elseif action == "playlist_play" then
    playlistBuildQueue(p.id, p.shuffle == true, true,
      p.shuffle == true and "notices.playing_shuffled_playlist" or "notices.playing_playlist")
  elseif action == "playlist_queue" then
    playlistBuildQueue(p.id, p.shuffle == true, false,
      p.shuffle == true and "notices.added_shuffled_playlist_to_queue" or "notices.added_playlist_to_queue")
  elseif action == "playlist_hide_local" then
    playlistHideLocal(p.id)
  elseif action == "playlist_sync" then
    playlistSync(p.id)
  elseif action == "tag" then
    mutation({ "tag", p.id, p.tag }, "tag", "errors.library_failed", "notices.library_updated", nil, "library")
  elseif action == "untag" then
    mutation({ "untag", p.id, p.tag }, "tag", "errors.library_failed", "notices.library_updated", nil, "library")
  elseif action == "rate" then
    mutation({ "rate", p.id, tostring(p.rating or 0) }, "tag", "errors.library_failed", "notices.library_updated", nil, "library")
  elseif action == "edit_metadata" then
    mutation({ "edit-metadata", p.id, p.field, p.value or "" }, "metadata",
      "errors.library_failed", "notices.library_updated", nil, "library")
  elseif action == "import_folder" then
    importFolder(p.path, p.name)
  elseif action == "refresh" then
    refreshAll()
  end
end

function onIpc(event, payload)
  if event == "help" then
    noctalia.notify("Music Search IPC",
      "help · status\nplay <url> · play_url <url>\nsave <url> · save_url <url>\ntoggle · pause · resume · stop\nseek <sec> · speed <x> · volume <0-100>\nrepeat <off|all|one> · shuffle <true|false>\nnext · prev (history/radio)\nqueue_skip · queue_clear · queue_start\nplaylist_play <id> · import_folder <path>")
    return
  end
  if not ready then return end
  if event == "status" then
    publish()
    return
  end
  local message = { action = event }
  if event == "play" and type(payload) == "string" then
    message = { action = "play_url", payload = { url = payload } }
  elseif event == "save" and type(payload) == "string" then
    message = { action = "save_url", payload = { url = payload } }
  elseif event == "play" and type(payload) == "table" then
    message.payload = { entry = payload }
  elseif event == "play_url" and type(payload) == "string" then
    message.payload = { url = payload }
  elseif event == "seek" then
    message.payload = { position = tonumber(payload) }
  elseif event == "speed" then
    message.payload = { value = tonumber(payload) }
  elseif event == "volume" then
    message.payload = { value = tonumber(payload) }
  elseif event == "repeat" then
    message.payload = { mode = payload }
  elseif event == "shuffle" then
    message.payload = { value = payload == "true" }
  elseif event == "save" and type(payload) == "table" then
    message.payload = { entry = payload }
  elseif type(payload) == "table" then
    message.payload = payload
  end
  dispatch(message)
end

local function applyConfig()
  cfg = {
    provider = noctalia.getConfig("provider") or "youtube",
    sortBy = noctalia.getConfig("sort_by") or "date",
    ytClient = noctalia.getConfig("yt_player_client") or "web_embedded",
    downloadDir = noctalia.expandPath(noctalia.getConfig("download_directory") or "~/Music/Noctalia"),
    cacheMb = tostring(noctalia.getConfig("download_cache_max_mb") or 0),
    autoSave = noctalia.getConfig("auto_save_mp3") == true,
  }
  run({ "set-provider", cfg.provider }, function(first)
    if first.exitCode == 0 then applySettingsJson(first.stdout) end
    run({ "set-sort", cfg.sortBy }, function(second)
      if second.exitCode == 0 then applySettingsJson(second.stdout) end
      run({ "set-yt-player-client", cfg.ytClient }, function()
        run({ "set-download-dir", cfg.downloadDir }, function()
          run({ "set-cache-size", cfg.cacheMb }, function()
            run({ "library" }, function(lib)
              if lib.exitCode == 0 then applyLibraryJson(lib.stdout) end
              run({ "playlists" }, function(playlists)
                if playlists.exitCode == 0 then applyPlaylistsJson(playlists.stdout) end
                run({ "queue-list" }, function(queue)
                  if queue.exitCode == 0 then applyQueueJson(queue.stdout) end
                  run({ "status" }, function(status)
                    if status.exitCode == 0 then applyStateJson(status.stdout) end
                    loadQueueActive()
                    ready = true
                    publish()
                  end)
                end)
              end)
            end)
          end)
        end)
      end)
    end)
  end)
end

function onConfigChanged()
  if not ready then return end
  applyConfig()
end

function update()
  if not ready then return end
  tick = tick + 1
  if commandsInFlight > 0 then
    if stuckSince == 0 then stuckSince = tick end
    if tick - stuckSince == 120 then
      stuckSince = 0
      noctalia.notify("Music Search", noctalia.tr("notices.stuck_detected"))
    end
  else
    stuckSince = 0
  end
  if snapshot.playing and not positionBusy then
    positionBusy = true
    run({ "position" }, function(result)
      positionBusy = false
      if result.exitCode == 0 then
        local position = decode(result.stdout)
        if position and position.position ~= nil then
          noctalia.state.set("music_position", {
            position = tonumber(position.position) or 0,
            duration = snapshot.current.duration or 0,
            speed = snapshot.current.speed or 1,
            playing = snapshot.playing,
          })
        end
      end
    end)
  end
  if tick % 5 == 0 and not statusBusy and commandsInFlight == 0 then
    statusBusy = true
    run({ "status" }, function(result)
      statusBusy = false
      if result.exitCode == 0 then
        local state = applyStateJson(result.stdout)
        if state then handleEnded(state) end
        publish()
      end
    end)
  end
end

noctalia.state.watch("music_command", dispatch)

applyConfig()
