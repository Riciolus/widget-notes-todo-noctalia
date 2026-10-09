--!nonstrict
-- Headless reminder service: fires a desktop notification when a task's due
-- time arrives. It never writes todos.json (the panel owns that file); all it
-- persists is its own log of already-fired reminders.
--
-- Due formats, mirroring panel.luau: a daily task stores "HH:MM", a one-time
-- task "YYYY-MM-DD HH:MM". A reminder fires at most once per due slot, within
-- GRACE_MINUTES after it - so a missed slot simply expires instead of
-- shouting at you hours later.

local dataDir = noctalia.pluginDataDir()
local todosPath = dataDir .. "/todos.json"
local logPath = dataDir .. "/reminders-notified.json"

local GRACE_MINUTES = 240 -- how long after the due time a reminder is still useful
local MAX_LOG = 500 -- oldest fired keys are dropped beyond this

local fired = {} -- set: key -> true
local firedOrder = {} -- array, oldest first
local summary = "no scan yet" -- last scan, reported over IPC (see onIpc)

-- "HH:MM" -> minutes since midnight, or nil if the stamp is malformed.
local function minutesOf(hhmm)
  local h, m = string.match(hhmm or "", "^(%d%d):(%d%d)$")
  if h == nil then
    return nil
  end
  h, m = tonumber(h), tonumber(m)
  if h > 23 or m > 59 then
    return nil
  end
  return h * 60 + m
end

-- Mirrors isDone() in panel.luau.
local function isDone(item)
  if item.type == "daily" then
    return item.doneDay ~= nil and item.doneDay == noctalia.formatTime("%Y-%m-%d")
  end
  return item.done == true
end

local function loadLog()
  fired = {}
  firedOrder = {}
  local raw = noctalia.readFile(logPath)
  if raw == nil or raw == "" then
    return
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    return
  end
  for _, key in ipairs(decoded) do
    if type(key) == "string" and not fired[key] then
      fired[key] = true
      table.insert(firedOrder, key)
    end
  end
end

local function saveLog()
  local ok, err = noctalia.writeFile(logPath, noctalia.json.encode(firedOrder))
  if not ok then
    noctalia.notifyError("To-Do", err or "Could not save reminder history")
  end
end

local function markFired(key)
  if fired[key] then
    return
  end
  fired[key] = true
  table.insert(firedOrder, key)
  while #firedOrder > MAX_LOG do
    local oldest = table.remove(firedOrder, 1)
    fired[oldest] = nil
  end
  saveLog()
end

local function scan()
  local raw = noctalia.readFile(todosPath)
  if raw == nil or raw == "" then
    summary = "no task file yet"
    return
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    summary = "task file unreadable"
    return
  end
  -- v2 stores { version, groups, tasks }; v1 was a bare task array.
  local list = type(decoded.tasks) == "table" and decoded.tasks or decoded

  local today = noctalia.formatTime("%Y-%m-%d")
  local nowMin = minutesOf(noctalia.formatTime("%H:%M"))
  if nowMin == nil then
    return
  end

  local watched = 0 -- open tasks carrying a due time
  for _, item in ipairs(list) do
    if type(item) == "table" and type(item.due) == "string" and not isDone(item) then
      watched += 1
      local dueMin, key
      if item.type == "daily" then
        -- A fresh key per day, so the daily slot fires once per day.
        dueMin = minutesOf(item.due)
        key = tostring(item.id) .. "|" .. today .. "|" .. item.due
      elseif item.due:sub(1, 10) == today then
        -- One-time tasks remind on their own day only.
        dueMin = minutesOf(item.due:sub(12))
        key = tostring(item.id) .. "|" .. item.due
      end
      if dueMin ~= nil and not fired[key]
        and nowMin >= dueMin and (nowMin - dueMin) <= GRACE_MINUTES
      then
        markFired(key)
        local title = type(item.title) == "string" and item.title or "a task"
        noctalia.notify("To-Do · " .. title, "Due at " .. item.due:sub(-5))
      end
    end
  end
  summary = string.format("checked %s · %d task(s) due · %d reminder(s) fired",
    noctalia.formatTime("%H:%M"), watched, #firedOrder)
end

loadLog()

function update()
  noctalia.setUpdateInterval(30000)
  scan()
end

-- Diagnostics: noctalia msg plugin riciolus/notes-todo:reminders all status
function onIpc(event, payload)
  if event ~= "status" and payload ~= "status" then
    return
  end
  noctalia.notify("To-Do reminders", summary)
end
