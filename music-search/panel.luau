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
local volumeDrag = nil

local repeatOrder = { "off", "all", "one" }

local function nextRepeatMode(mode)
  for i, m in ipairs(repeatOrder) do
    if m == mode then
      return repeatOrder[(i % #repeatOrder) + 1]
    end
  end
  return "all"
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

  local header = ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "music", size = 16 }),
    ui.label({
      text = title ~= "" and title or tr("panel.no_track"),
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
    if thumbPath then
      children[#children + 1] = ui.image({
        path = thumbPath,
        width = 256,
        height = 144,
        fit = "cover",
        radius = 12,
      })
    end
    if playing or title ~= "" then
      local pos = math.max(0, math.floor(tonumber((position or {}).position) or 0))
      local duration = math.max(0, math.floor(tonumber(current.duration) or 0))
      local sliderValue = dragTarget or pos
      children[#children + 1] = ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = formatDuration(sliderValue), width = 44 }),
        ui.slider({
          min = 0,
          max = math.max(1, duration),
          step = 1,
          value = sliderValue,
          flexGrow = 1,
          onChange = function(value)
            dragTarget = tonumber(value) or 0
          end,
          onDragEnd = function()
            local target = dragTarget or pos
            dragTarget = nil
            dispatch({ action = "seek", position = target })
          end,
        }),
        ui.label({ text = formatDuration(duration), width = 44 }),
      })
      children[#children + 1] = ui.row({ gap = 8, align = "center" }, {
        ui.button({ glyph = "media-prev", tooltip = tr("panel.prev_track"), onClick = function()
          dispatch({ action = "prev" })
        end }),
        ui.button({ glyph = paused and "player-play-filled" or "player-pause-filled", tooltip = tr("panel.toggle_play"), onClick = function()
          dispatch({ action = "toggle" })
        end }),
        ui.button({ glyph = "media-next", tooltip = tr("panel.next_track"), onClick = function()
          dispatch({ action = "next" })
        end }),
        ui.button({
          glyph = (snapshot or {})["repeat"] == "one" and "repeat-one" or "repeat",
          tooltip = tr("panel.repeat", { mode = tr("repeat." .. ((snapshot or {})["repeat"] or "off")) }),
          onClick = function()
            dispatch({ action = "repeat", payload = { mode = nextRepeatMode((snapshot or {})["repeat"] or "off") } })
          end,
        }),
        ui.button({
          glyph = "shuffle",
          tooltip = tr("panel.shuffle", { state = (snapshot or {}).shuffle == true and tr("shuffle.on") or tr("shuffle.off") }),
          onClick = function()
            dispatch({ action = "shuffle", payload = { value = not ((snapshot or {}).shuffle == true) } })
          end,
        }),
      })
      local volume = math.max(0, math.min(100, math.floor(tonumber((snapshot or {}).volume) or 100)))
      local volumeDraw = volumeDrag or volume
      children[#children + 1] = ui.row({ gap = 8, align = "center" }, {
        ui.button({ glyph = volume == 0 and "volume-off" or "volume-up", tooltip = tr("panel.mute"), onClick = function()
          dispatch({ action = "volume", payload = { value = volume > 0 and 0 or 100 } })
        end }),
        ui.slider({
          min = 0,
          max = 100,
          step = 1,
          value = volumeDraw,
          flexGrow = 1,
          onChange = function(value)
            volumeDrag = tonumber(value) or 0
          end,
          onDragEnd = function()
            local target = volumeDrag or volume
            volumeDrag = nil
            dispatch({ action = "volume", payload = { value = math.max(0, math.min(100, math.floor(target))) } })
          end,
        }),
        ui.label({ text = tostring(volumeDraw) .. "%", width = 36 }),
      })
    else
      children[#children + 1] = ui.label({ text = tr("panel.no_track") })
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
