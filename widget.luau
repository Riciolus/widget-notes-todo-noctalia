--!nonstrict
-- Bar widget: open-task count plus a completion bar, and a hover list of the
-- tasks themselves. Left click toggles the panel (see [widget.actions]).

local dataDir = noctalia.pluginDataDir()
local todosPath = dataDir .. "/todos.json"
local MAX_TITLES = 5 -- tasks listed in the tooltip

local stats = { open = 0, total = 0, titles = {} }

-- Mirrors isDone() in panel.luau: a one-time task stores `done`, a daily task
-- is done only while its doneDay matches today.
local function isDone(item)
  if item.type == "daily" then
    return item.doneDay ~= nil and item.doneDay == noctalia.formatTime("%Y-%m-%d")
  end
  return item.done == true
end

local function readStats()
  local raw = noctalia.readFile(todosPath)
  if raw == nil or raw == "" then
    return { open = 0, total = 0, titles = {} }
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    return { open = 0, total = 0, titles = {} }
  end
  -- v2 stores { version, groups, tasks }; v1 was a bare task array.
  local list = type(decoded.tasks) == "table" and decoded.tasks or decoded
  local groupNames = {}
  if type(decoded.groups) == "table" then
    for _, group in ipairs(decoded.groups) do
      if type(group) == "table" and type(group.id) == "number" and type(group.title) == "string" then
        groupNames[group.id] = group.title
      end
    end
  end
  local open = 0
  local titles = {}
  for _, item in ipairs(list) do
    if type(item) == "table" and not isDone(item) then
      open += 1
      if #titles < MAX_TITLES then
        local title = type(item.title) == "string" and item.title or "?"
        local name = type(item.group) == "number" and groupNames[item.group] or nil
        table.insert(titles, name ~= nil and (name .. " · " .. title) or title)
      end
    end
  end
  return { open = open, total = #list, titles = titles }
end

-- The tooltip is the task list: how many are open, then the first few titles.
local function tooltipRows()
  local rows = {
    { key = "Open", value = stats.open .. " of " .. stats.total .. " tasks" },
  }
  for _, title in ipairs(stats.titles) do
    table.insert(rows, { key = "○", value = title })
  end
  local hidden = stats.open - #stats.titles
  if hidden > 0 then
    table.insert(rows, { key = "", value = "+ " .. hidden .. " more" })
  end
  if #rows == 1 then
    table.insert(rows, { key = "", value = "Nothing pending" })
  end
  return rows
end

local function present()
  local ratio = 0
  if stats.total > 0 then
    ratio = (stats.total - stats.open) / stats.total
  end
  -- isVertical() is read every tick: barWidget.render() replaces the built-in
  -- text/glyph row for good, so one presentation must not depend on stale state.
  if barWidget.isVertical() then
    -- A vertical bar has no room for a horizontal rail: stack glyph + ratio.
    barWidget.render(ui.column({ key = "todo-widget-v", gap = 2, align = "center" }, {
      ui.glyph({
        key = "glyph",
        name = "clipboard-check",
        size = 14,
        color = stats.open > 0 and "primary" or "on_surface",
      }),
      ui.label({
        key = "ratio",
        text = stats.open .. "/" .. stats.total,
        fontSize = 10,
        color = stats.open > 0 and "primary" or "on_surface_variant",
      }),
    }))
  else
    -- The glyph has to live in the tree: barWidget.render() replaces the
    -- built-in glyph/text row, so setGlyph() would no longer show anything.
    barWidget.render(ui.row({ key = "todo-widget-h", gap = 6, align = "center", paddingH = 6 }, {
      ui.glyph({
        key = "glyph",
        name = "clipboard-check",
        size = 14,
        color = stats.open > 0 and "primary" or "on_surface",
      }),
      ui.progress({
        key = "rail",
        -- A bar capsule hugs its content, so a flexGrow rail would be sized to
        -- nothing; give it a width the progress can actually fill.
        width = 40,
        height = 6,
        radius = 3,
        progress = ratio,
        fill = "primary",
        track = "surface_variant",
      }),
      ui.label({
        key = "ratio",
        text = stats.open .. "/" .. stats.total,
        fontSize = 11,
        fontWeight = "bold",
        color = stats.open > 0 and "primary" or "on_surface_variant",
      }),
    }))
  end
  barWidget.setTooltip(tooltipRows())
end

function update()
  noctalia.setUpdateInterval(5000)
  stats = readStats()
  present()
end

-- The panel publishes the whole picture, so the bar updates without waiting
-- for the next poll; the file poll stays as the fallback.
noctalia.state.watch("todoStats", function(value)
  if type(value) == "table" and type(value.open) == "number" then
    stats = {
      open = value.open,
      total = type(value.total) == "number" and value.total or stats.total,
      titles = type(value.titles) == "table" and value.titles or {},
    }
    present()
  end
end)

noctalia.state.watch("pendingCount", function(value)
  if type(value) == "number" then
    stats.open = value
    present()
  end
end)
