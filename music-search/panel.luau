--!nonstrict

local snapshot = noctalia.state.get("music_snapshot")
local position = noctalia.state.get("music_position")

local helper = ((noctalia.pluginDir() or ""):gsub("/+$", "")) .. "/musicctl.sh"
local CACHE_DIR = (noctalia.getenv("XDG_CACHE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.cache"))
  .. "/noctalia/plugins/music-search/thumbs"
local thumbPath = nil
local thumbForId = ""
local thumbPending = false

local searchQuery = ""
local searchResults = {}
local searchBusy = false
local searchFailed = false
local pendingSearchQuery = nil
local lastCompletedQuery = ""
local dragTarget = nil
local dragUpdatedAt = nil
local lastSeekAt = 0
local WAVE_N = 28
local wave = {}

for i = 1, WAVE_N do
  wave[i] = 0.5
end

local function buildWave()
  local active = (snapshot or {}).playing == true
  local t = os.clock() * 2.4
  local squash = active and 1 or 0.12
  local center = (WAVE_N - 1) / 2
  for i = 1, WAVE_N do
    local d = (i - 1) - center
    local env = math.max(0, 1 - math.abs(d) / center)
    env = env ^ 1.3
    local pulse = 0.55 + 0.45 * math.sin(t + i * 0.9)
    local v = env * pulse * squash
    wave[i] = math.max(0.04, math.min(1, v))
  end
end

local trCache = {}

local function tr(key)
  local cached = trCache[key]
  if cached ~= nil then
    return cached
  end
  local value = noctalia.tr(key)
  trCache[key] = value
  return value
end

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function dispatch(message)
  noctalia.state.set("music_command", message)
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

local function maxResultsSetting()
  return tonumber(noctalia.getConfig("max_results") or 8) or 8
end

local render

local function ensureThumbnail(id, url)
  if thumbPending or id == "" or url == "" then return end
  if thumbPath ~= nil and thumbForId == id then return end
  thumbPending = true
  thumbForId = id
  local dest = CACHE_DIR .. "/" .. id .. ".jpg"
  noctalia.download(url, dest, function(ok)
    thumbPending = false
    if ok then
      thumbPath = dest
    else
      thumbPath = nil
      thumbForId = ""
    end
    render()
  end)
end

local function playSearchEntry(entry)
  searchQuery = ""
  searchResults = {}
  searchBusy = false
  searchFailed = false
  pendingSearchQuery = nil
  lastCompletedQuery = ""
  dispatch({ action = "play", payload = { entry = entry } })
  render()
end

local startSearch

startSearch = function(text)
  local provider = ((snapshot or {}).provider) or "youtube"
  searchBusy = true
  searchFailed = false
  lastCompletedQuery = text
  local ok = noctalia.runAsync(
    "bash " .. shellQuote(helper) .. " search " .. shellQuote(text) .. " " .. shellQuote(provider),
    function(result)
      searchBusy = false
      searchFailed = result.exitCode ~= 0
      local decoded, list = pcall(noctalia.json.decode, result.stdout or "")
      searchResults = decoded and type(list) == "table" and list or {}
      if pendingSearchQuery then
        local nextQuery = pendingSearchQuery
        pendingSearchQuery = nil
        startSearch(nextQuery)
        return
      end
      if text == trim(searchQuery) then
        render()
      end
    end, 60000)
  if not ok then
    searchBusy = false
    searchFailed = true
    searchResults = {}
  end
end

local function ensureSearch(text)
  if text == "" then
    searchResults = {}
    searchBusy = false
    searchFailed = false
    pendingSearchQuery = nil
    render()
    return
  end
  if text == lastCompletedQuery then
    render()
    return
  end
  if searchBusy then
    pendingSearchQuery = text
    render()
    return
  end
  startSearch(text)
end

render = function()
  local current = (snapshot or {}).current or {}
  local playing = (snapshot or {}).playing == true
  local paused = (snapshot or {}).paused == true
  local title = current.title or ""
  local query = trim(searchQuery)
  if type(panel.setNeedsFrameTick) == "function" then
    panel.setNeedsFrameTick(playing and not paused and query == "")
  end

  local header = ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "music", size = 16 }),
    ui.label({
      text = tr("panel.title"),
      flexGrow = 1,
      maxLines = 1,
    }),
    ui.button({ glyph = "close", onClick = function()
      panel.close()
    end }),
  })

  local children = {}
  if query ~= "" then
    local rows = {}
    local maxResults = maxResultsSetting()
    local shown = 0
    if searchBusy and #searchResults == 0 then
      rows[1] = ui.label({ key = "search-busy", text = tr("search.searching"), color = "on_surface_variant" })
    elseif searchFailed and #searchResults == 0 then
      rows[1] = ui.label({ key = "search-failed", text = tr("search.failed_default"), color = "error" })
    else
      for _, entry in ipairs(searchResults) do
        if shown >= maxResults then break end
        shown = shown + 1
        rows[#rows + 1] = ui.button({
          key = "hit-" .. shown,
          glyph = "music",
          text = entry.title or tr("common.untitled"),
          variant = "ghost",
          contentAlign = "start",
          onClick = function()
            playSearchEntry(entry)
          end,
        })
      end
      if shown == 0 then
        rows[1] = ui.label({ key = "search-empty", text = tr("search.no_results"), color = "on_surface_variant" })
      end
    end
    children[#children + 1] = ui.scroll({ key = "results", flexGrow = 1, gap = 2 }, rows)
  else
    if playing or title ~= "" then
      local pos = math.max(0, math.floor(tonumber((position or {}).position) or 0))
      local duration = math.max(0, math.floor(tonumber(current.duration) or 0))
      local sliderValue = dragTarget or pos
      local artist = trim(current.uploader or "")
      local media = {
        ui.row({ key = "now-head", align = "center", justify = "space-between" }, {
          ui.label({ text = tr("panel.now_playing"), color = "primary", fontSize = 12 }),
          ui.glyph({ name = "headphones", size = 14, color = "on_surface_variant" }),
        }),
      }
      if thumbPath then
        media[#media + 1] = ui.image({ key = "art", path = thumbPath, width = 210, height = 210, fit = "cover", radius = 12 })
      else
        media[#media + 1] = ui.column({ key = "art", width = 210, height = 210, radius = 12, align = "center", justify = "center" }, {
          ui.glyph({ name = "music", size = 44, color = "on_surface_variant" }),
        })
      end
      media[#media + 1] = ui.label({
        text = title,
        fontWeight = "bold",
        color = "#DDB067",
        fontSize = 16,
        maxLines = 1,
        textAlign = "center",
        maxWidth = 500,
      })
      if artist ~= "" then
        media[#media + 1] = ui.label({
          text = artist,
          color = "on_surface_variant",
          fontSize = 13,
          maxLines = 1,
          textAlign = "center",
          maxWidth = 500,
        })
      end
      media[#media + 1] = ui.row({ gap = 12, align = "center" }, {
          ui.label({ text = formatDuration(sliderValue), width = 44 }),
          ui.slider({
            min = 0,
            max = math.max(1, duration),
            step = 1,
            value = sliderValue,
            flexGrow = 1,
            onChange = function(value)
              dragTarget = tonumber(value) or 0
              dragUpdatedAt = noctalia.nowMs()
              local now = noctalia.nowMs()
              if now - lastSeekAt >= 150 then
                lastSeekAt = now
                dispatch({ action = "seek", position = dragTarget })
              end
            end,
            onDragEnd = function()
              local target = dragTarget or pos
              dragTarget = nil
              dragUpdatedAt = nil
              dispatch({ action = "seek", position = target })
            end,
          }),
          ui.label({ text = formatDuration(duration), width = 44 }),
        })
      media[#media + 1] = ui.row({ gap = 12, align = "center" }, {
        ui.button({ glyph = "media-prev", variant = "ghost", width = 40, height = 40, glyphSize = 18, tooltip = tr("panel.prev_track"), onClick = function()
          dispatch({ action = "prev" })
        end }),
        ui.button({ glyph = paused and "player-pause-filled" or "player-play-filled", variant = "primary", width = 48, height = 48, glyphSize = 22, tooltip = tr("panel.toggle_play"), onClick = function()
          dispatch({ action = "toggle" })
        end }),
        ui.button({ glyph = "media-next", variant = "ghost", width = 40, height = 40, glyphSize = 18, tooltip = tr("panel.next_track"), onClick = function()
          dispatch({ action = "next" })
        end }),
      })
      buildWave()
      local bars = {}
      for i = 1, WAVE_N do
        local amp = wave[i]
        bars[#bars + 1] = ui.row({ key = "bar-" .. i, width = 156, height = 12, align = "center", justify = "center" }, {
          ui.box({ width = math.max(2, math.floor(amp * 150)), height = 12, fill = "#98C39E", radius = 6 }),
        })
      end
      children[#children + 1] = ui.row({ flexGrow = 1, gap = 12, align = "center" }, {
        ui.column({ flexGrow = 1, radius = 16, padding = 12, gap = 10, fill = "#1E1C1ACC", border = "outline", borderWidth = 1, align = "center" }, media),
        ui.column({ key = "vizcard", width = 180, radius = 16, padding = 12, gap = 2, fill = "#1E1C1ACC", border = "outline", borderWidth = 1, align = "center", justify = "center" }, bars),
      })
    else
      children[#children + 1] = ui.column({ align = "center", flexGrow = 1, gap = 12 }, {
        ui.glyph({ name = "music", size = 56 }),
        ui.label({ text = tr("panel.no_track"), color = "on_surface_variant", fontSize = 14 }),
      })
    end
  end

  panel.render(ui.column({ flexGrow = 1, gap = 16, padding = 16 }, {
    header,
    ui.input({
      key = "search-input",
      value = searchQuery,
      placeholder = tr("panel.search_placeholder"),
      focus = true,
      onChange = function(value)
        searchQuery = value
        ensureSearch(value)
      end,
      onSubmit = function()
        if #searchResults > 0 then
          playSearchEntry(searchResults[1])
        end
      end,
    }),
    ui.column({ flexGrow = 1, gap = 12, align = "center" }, children),
  }))
end

local function readState()
  snapshot = noctalia.state.get("music_snapshot")
  position = noctalia.state.get("music_position")
  local current = (snapshot or {}).current or {}
  ensureThumbnail(current.id or "", current.thumbnail or "")
end

local function resolveStaleDrag()
  if dragTarget ~= nil and dragUpdatedAt ~= nil and noctalia.nowMs() - dragUpdatedAt > 1500 then
    local target = dragTarget
    dragTarget = nil
    dragUpdatedAt = nil
    dispatch({ action = "seek", position = target })
  end
end

function onOpen(context)
  readState()
  resolveStaleDrag()
  render()
end

function update()
  readState()
  resolveStaleDrag()
  render()
end

function onFrameTick(deltaMs)
  if not (snapshot or {}).playing or (snapshot or {}).paused then return end
  render()
end

noctalia.state.watch("music_snapshot", function(value)
  snapshot = value
  local current = (snapshot or {}).current or {}
  ensureThumbnail(current.id or "", current.thumbnail or "")
  render()
end)

noctalia.state.watch("music_position", function(value)
  position = value
  render()
end)

noctalia.runAsync("mkdir -p " .. shellQuote(CACHE_DIR), function()
  local current = (snapshot or {}).current or {}
  ensureThumbnail(current.id or "", current.thumbnail or "")
  render()
end)

render()
panel.setWantsSecondTicks(true)
