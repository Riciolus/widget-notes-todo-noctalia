--!nonstrict
-- Bar widget: shows how many tasks are still open. Left click toggles the
-- panel (see [widget.actions] in plugin.toml).

local dataDir = noctalia.pluginDataDir()
local todosPath = dataDir .. "/todos.json"

local pending = 0

-- Mirrors isDone() in panel.luau: a one-time task stores `done`, a daily task
-- is done only while its doneDay matches today.
local function isDone(item)
  if item.type == "daily" then
    return item.doneDay ~= nil and item.doneDay == noctalia.formatTime("%Y-%m-%d")
  end
  return item.done == true
end

local function readPending()
  local raw = noctalia.readFile(todosPath)
  if raw == nil or raw == "" then
    return 0
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    return 0
  end
  local count = 0
  for _, item in ipairs(decoded) do
    if type(item) == "table" and not isDone(item) then
      count += 1
    end
  end
  return count
end

local function present()
  barWidget.setGlyph("clipboard-check")
  barWidget.setText(pending > 0 and tostring(pending) or "")
  barWidget.setColor(pending > 0 and "primary" or "on_surface", "script")
  barWidget.setTooltip(pending > 0 and (pending .. " open task(s)") or "No open tasks")
end

function update()
  noctalia.setUpdateInterval(5000)
  pending = readPending()
  present()
end

-- The panel publishes the live count so the bar updates without waiting for
-- the next poll.
noctalia.state.watch("pendingCount", function(value)
  if type(value) == "number" then
    pending = value
    present()
  end
end)
