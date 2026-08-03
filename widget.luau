--!nonstrict

local snapshot = noctalia.state.get("music_snapshot")
local position = noctalia.state.get("music_position")

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

local function render()
  if not snapshot then
    barWidget.render(ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "music", size = 15, color = "on_surface_variant" }),
    }))
    barWidget.setTooltip(noctalia.tr("bar_widget.tooltip_idle") .. "\n" .. noctalia.tr("bar_widget.click_hint"))
    return
  end

  local current = snapshot.current or {}
  local playing = snapshot.playing == true
  local paused = snapshot.paused == true
  local vertical = barWidget.isVertical()
  local showTitle = noctalia.getConfig("show_title") ~= false

  local glyphName = "music"
  local glyphColor = "on_surface_variant"
  if playing then
    glyphName = paused and "player-pause-filled" or "disc"
    glyphColor = "primary"
  elseif snapshot.lastError and snapshot.lastError ~= "" then
    glyphName = "alert-triangle"
    glyphColor = "error"
  end

  local children = {
    ui.glyph({ name = glyphName, size = 15, color = glyphColor }),
  }
  if not vertical and showTitle and playing and current.title and current.title ~= "" then
    children[#children + 1] = ui.label({
      text = current.title,
      color = "on_surface",
      fontSize = 12,
      maxWidth = 200,
      maxLines = 1,
    })
  end

  barWidget.render(ui.row({ gap = 6, align = "center" }, children))

  if not playing then
    if snapshot.lastError and snapshot.lastError ~= "" then
      barWidget.setTooltip(snapshot.lastError .. "\n" .. noctalia.tr("bar_widget.click_hint"))
    else
      barWidget.setTooltip(noctalia.tr("bar_widget.tooltip_idle") .. "\n" .. noctalia.tr("bar_widget.click_hint"))
    end
    return
  end

  local pos = position and position.position or 0
  local duration = current.duration or 0
  local lines = {
    noctalia.tr("bar_widget.tooltip_playing", { title = current.title or "" }),
  }
  if duration and duration > 0 then
    lines[#lines + 1] = formatDuration(pos) .. " / " .. formatDuration(duration)
  end
  if current.speed and current.speed ~= 1 then
    lines[#lines + 1] = noctalia.tr("speed.current", { speed = tostring(current.speed) })
  end
  lines[#lines + 1] = noctalia.tr("bar_widget.click_hint")
  barWidget.setTooltip(table.concat(lines, "\n"))
end

noctalia.state.watch("music_snapshot", function(value)
  snapshot = value
  render()
end)

noctalia.state.watch("music_position", function(value)
  position = value
  render()
end)

function update()
  snapshot = noctalia.state.get("music_snapshot")
  position = noctalia.state.get("music_position")
  render()
end

function onClick()
  noctalia.togglePanel("kevichi7/music-search:player")
end

render()
