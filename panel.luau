--!nonstrict
-- Notes on the left, to-do list on the right, in one panel.
--
-- Notes are .md files in <plugin data>/notes and the tasks live in
-- <plugin data>/todos.json. Tasks are one-time or daily; a daily task is done
-- only while its doneDay matches today, so it resets itself at midnight. The
-- note editor autosaves after a short pause in typing, on navigation, and on
-- panel close.

local AUTOSAVE_IDLE_TICKS = 2 -- 1s panel ticks with no edits before a flush
local UNDO_TICKS = 6 -- seconds the "task deleted - Undo" strip stays up
local SUFFIX = ".md"
local DRAG_TYPE = "todo" -- dragType shared by every todo grip and insertion zone
local GROUP_DRAG_TYPE = "group" -- dragType of the project-header grips
local SCRATCH = "scratch" .. SUFFIX
local UNGROUPED = 0 -- scope key for tasks that belong to no project

local dataDir = noctalia.pluginDataDir()
local notesDir = dataDir .. "/notes"
local todosPath = dataDir .. "/todos.json"
local pinsPath = dataDir .. "/pins.json"

-- Notes state
local files = {}
local view = "list" -- "list" | "editor"
local current = nil -- filename while the editor is open
local buffer = ""
local loadedContent = "" -- what the file held when we last read/wrote it
local editorRev = 0 -- bumped to reseed the editor input after external changes
local dirty = false
local idleTicks = 0
local searchQuery = ""
local searchRev = 0 -- bumped to clear the (uncontrolled) search input
local previewMode = false -- rendering the note with ui.markdown instead of editing
local pins = {} -- set of filenames sorted ahead of everything else

-- Todo state
local todos = {} -- { { id, title, type, done?, doneDay?, due?, group? } }
local groups = {} -- ordered projects: { { id, title, collapsed } }
local nextId = 1 -- shared by tasks and projects, so every id is unique
local showCompleted = true
local addDrafts = {} -- scope ("0" or a group id) -> text typed in that add row
local addRevs = {} -- scope -> bumped to reseed the (uncontrolled) add input
local addType = "once" -- type stamped on the next submitted task
local editingGroup = nil -- project id whose name is being edited in place
local groupDraft = ""
local groupRev = 0 -- bumped to reseed the (uncontrolled) name input
local pendingGroup = nil -- project id awaiting the second (confirm) click
local currentDay = "" -- local YYYY-MM-DD, watched for the daily reset
local editingTodo = nil -- task id whose title is being edited in place
local editDraft = ""
local editRev = 0 -- bumped to reseed the (uncontrolled) edit input
local pendingDue = nil -- task id awaiting a due-time input
local dueDraft = ""
local dueRev = 0
local lastDeleted = nil -- { todo, index } backing the undo strip
local undoTicks = 0 -- seconds left before the undo strip disappears
local panelOpen = false -- IPC writes must know whether `todos` is live or stale

-- Shared UI state
local hoveredNote = nil
local hoveredTodo = nil
local hoveredBtn = nil -- key of the hbtn control under the pointer
local pendingNote = nil -- filename awaiting the second (confirm) click
local pendingTodo = nil -- task id awaiting the second (confirm) click
local cornerRadiusScale = 1.0

local render

-- ── helpers ──────────────────────────────────────────────────────────────

local function notePath(file)
  return notesDir .. "/" .. file
end

local function displayName(file)
  return file:sub(1, #file - #SUFFIX)
end

local function today()
  return noctalia.formatTime("%Y-%m-%d")
end

-- A one-time task stores `done`. A daily task stores `doneDay` instead and is
-- only done while that day matches today, so it rolls back to open at midnight
-- on its own - no write, no drift, same answer after a restart.
local function isDone(todo)
  if todo.type == "daily" then
    return todo.doneDay ~= nil and todo.doneDay == today()
  end
  return todo.done == true
end

-- The bar widget renders a progress bar from these, so publish the whole
-- picture rather than a bare count.
local function publishStats()
  local open = 0
  local total = #todos
  local titles = {}
  for _, todo in ipairs(todos) do
    if not isDone(todo) then
      open += 1
      if #titles < 5 then
        table.insert(titles, todo.title)
      end
    end
  end
  noctalia.state.set("pendingCount", open)
  noctalia.state.set("todoStats", { open = open, total = total, titles = titles })
end

local function findIndex(id)
  for index, todo in ipairs(todos) do
    if todo.id == id then
      return index
    end
  end
  return nil
end

-- ── due times ─────────────────────────────────────────────────────────────
--
-- A daily task stores "HH:MM", a one-time task "YYYY-MM-DD HH:MM". Both are
-- fixed-width and zero-padded, so "has it passed?" is a plain string compare
-- against the same formatTime() output - no calendar math anywhere.

local function isOverdue(todo)
  if todo.due == nil or isDone(todo) then
    return false
  end
  if todo.type == "daily" then
    return todo.due <= noctalia.formatTime("%H:%M")
  end
  return todo.due <= noctalia.formatTime("%Y-%m-%d %H:%M")
end

-- Returns the normalised due value, or nil + an error message. An empty
-- string clears the due time (normalised to nil, no error).
local function parseDue(text, type)
  local raw = noctalia.string.trim(text or "")
  if raw == "" then
    return nil
  end
  if type == "daily" then
    local h, m = raw:match("^(%d%d?):(%d%d)$")
    if h == nil then
      return nil, "A daily task needs just a time, like 09:30."
    end
    h, m = tonumber(h), tonumber(m)
    if h > 23 or m > 59 then
      return nil, "Time must be between 00:00 and 23:59."
    end
    return string.format("%02d:%02d", h, m)
  end
  local y, mo, d, h, m = raw:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[ T]+(%d%d?):(%d%d)$")
  if y == nil then
    return nil, "A one-time task needs a date, like 2026-10-08 09:30."
  end
  h, m = tonumber(h), tonumber(m)
  if tonumber(mo) > 12 or tonumber(d) > 31 or h > 23 or m > 59 then
    return nil, "That date or time doesn't exist - use 2026-10-08 09:30."
  end
  return string.format("%s-%s-%s %02d:%02d", y, mo, d, h, m)
end

-- A bordered stand-in for ui.button: the fill never changes under the pointer,
-- only the border does (transparent -> accent). The 1px border is laid out even
-- while idle, so nothing shifts when hover starts.
local function hbtn(opts)
  local isHovered = hoveredBtn == opts.key
  local selected = opts.selected == true
  local nodes = {}
  if opts.glyph ~= nil then
    table.insert(nodes, ui.glyph({
      name = opts.glyph,
      size = opts.glyphSize or 15,
      color = opts.color or "on_surface",
    }))
  end
  if opts.text ~= nil then
    table.insert(nodes, ui.label({
      text = opts.text,
      fontSize = opts.fontSize or 12,
      color = opts.color or "on_surface",
    }))
  end
  return ui.row({
    key = opts.key,
    width = opts.width or (opts.text == nil and 32 or nil),
    height = opts.height or 32,
    align = "center",
    justify = "center",
    gap = opts.gap or 6,
    padding = opts.text ~= nil and (opts.padding or 10) or 0,
    fill = opts.fill,
    radius = 6 * cornerRadiusScale,
    borderWidth = 1,
    border = (isHovered or selected) and (opts.border or "primary") or "#00000000",
    onClick = opts.onClick,
    onHover = "onUiHover",
    tooltip = opts.tooltip,
  }, nodes)
end

-- ── notes storage ────────────────────────────────────────────────────────

-- Pinned note filenames, kept in their own file so the .md directory stays
-- pure content. The set is small and rewritten whole.
local function loadPins()
  pins = {}
  local raw = noctalia.readFile(pinsPath)
  if raw == nil or raw == "" then
    return
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    return
  end
  for _, name in ipairs(decoded) do
    if type(name) == "string" then
      pins[name] = true
    end
  end
end

local function savePins()
  local out = {}
  for name in pairs(pins) do
    table.insert(out, name)
  end
  table.sort(out)
  local ok, err = noctalia.writeFile(pinsPath, noctalia.json.encode(out))
  if not ok then
    noctalia.notifyError("Notes", err or "Could not save pinned notes")
  end
end

local function refreshFiles()
  files = {}
  local list = noctalia.listDir(notesDir)
  if list ~= nil then
    for _, name in ipairs(list) do
      if name ~= SCRATCH and #name > #SUFFIX and name:sub(-#SUFFIX) == SUFFIX and name:sub(1, 1) ~= "." then
        table.insert(files, name)
      end
    end
  end
  -- Pinned first, then most recently edited.
  local mtimes = {}
  for _, name in ipairs(files) do
    local info = noctalia.fileInfo(notePath(name))
    mtimes[name] = info ~= nil and info.mtime or 0
  end
  table.sort(files, function(a, b)
    local pinnedA, pinnedB = pins[a] == true, pins[b] == true
    if pinnedA ~= pinnedB then
      return pinnedA
    end
    if mtimes[a] ~= mtimes[b] then
      return mtimes[a] > mtimes[b]
    end
    return a < b
  end)
end

local function flush()
  if not dirty or current == nil then
    return
  end
  local ok, err = noctalia.writeFile(notePath(current), buffer)
  if not ok then
    noctalia.notifyError("Notes", err or "Could not save the note")
    return
  end
  loadedContent = buffer
  dirty = false
end

local function openNote(file)
  flush()
  local contents = noctalia.readFile(notePath(file))
  buffer = contents or ""
  loadedContent = buffer
  current = file
  view = "editor"
  dirty = false
  idleTicks = 0
  pendingNote = nil
  previewMode = false
  render()
end

local function uniqueNoteName()
  local base = noctalia.formatTime("%Y-%m-%d %H.%M.%S")
  local name = base .. SUFFIX
  local counter = 2
  while noctalia.fileExists(notePath(name)) do
    name = base .. " (" .. counter .. ")" .. SUFFIX
    counter += 1
  end
  return name
end

local function newNote()
  flush()
  local name = uniqueNoteName()
  local ok, err = noctalia.writeFile(notePath(name), "")
  if not ok then
    noctalia.notifyError("Notes", err or "Could not create the note")
    return
  end
  refreshFiles()
  openNote(name)
end

local function deleteNote(file)
  local ok, err = noctalia.removeFile(notePath(file))
  if not ok then
    noctalia.notifyError("Notes", err or "")
  end
  if current == file then
    current = nil
    buffer = ""
    loadedContent = ""
    dirty = false
    view = "list"
  end
  pendingNote = nil
  if pins[file] then
    pins[file] = nil
    savePins()
  end
  refreshFiles()
  render()
end

-- ── todo storage ─────────────────────────────────────────────────────────
--
-- The file is one object: { version = 2, groups = [...], tasks = [...] }.
-- Files written before projects existed were a bare task array; the loader
-- still reads that shape, so an upgrade never loses a task.

local function loadTodos()
  todos = {}
  groups = {}
  nextId = 1
  addDrafts = {}
  addRevs = {}
  local raw = noctalia.readFile(todosPath)
  if raw == nil or raw == "" then
    return
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    return
  end

  local rawTasks = decoded
  if type(decoded.tasks) == "table" then
    rawTasks = decoded.tasks
    if type(decoded.groups) == "table" then
      for _, item in ipairs(decoded.groups) do
        if type(item) == "table" and type(item.title) == "string" and item.title ~= "" then
          local gid = type(item.id) == "number" and item.id or nextId
          table.insert(groups, {
            id = gid,
            title = item.title,
            collapsed = item.collapsed == true,
          })
          if gid >= nextId then
            nextId = gid + 1
          end
        end
      end
    end
  end

  local known = {}
  for _, group in ipairs(groups) do
    known[group.id] = true
  end

  for _, item in ipairs(rawTasks) do
    if type(item) == "table" and type(item.title) == "string" and item.title ~= "" then
      local id = type(item.id) == "number" and item.id or nextId
      local kind = item.type == "daily" and "daily" or "once"
      -- Keep only the due shape this type can actually compare against.
      local due = nil
      if type(item.due) == "string" then
        if kind == "daily" and item.due:match("^%d%d:%d%d$") then
          due = item.due
        elseif kind == "once" and item.due:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d$") then
          due = item.due
        end
      end
      -- A task pointing at a project that is gone degrades to ungrouped
      -- rather than disappearing.
      local group = nil
      if type(item.group) == "number" and known[item.group] then
        group = item.group
      end
      table.insert(todos, {
        id = id,
        title = item.title,
        -- Anything written before types existed is a one-time task.
        type = kind,
        done = item.done == true,
        doneDay = type(item.doneDay) == "string" and item.doneDay or nil,
        due = due,
        group = group,
      })
      if id >= nextId then
        nextId = id + 1
      end
    end
  end
end

local function saveTodos()
  -- Write an explicit shape: daily tasks carry doneDay and no done flag.
  local outTasks = {}
  for _, todo in ipairs(todos) do
    local row = { id = todo.id, title = todo.title, due = todo.due, group = todo.group }
    if todo.type == "daily" then
      row.type = "daily"
      row.doneDay = todo.doneDay
    else
      row.type = "once"
      row.done = todo.done == true
    end
    table.insert(outTasks, row)
  end
  local outGroups = {}
  for _, group in ipairs(groups) do
    table.insert(outGroups, { id = group.id, title = group.title, collapsed = group.collapsed == true })
  end
  local ok, err = noctalia.writeFile(todosPath, noctalia.json.encode({
    version = 2,
    groups = outGroups,
    tasks = outTasks,
  }))
  if not ok then
    noctalia.notifyError("To-Do", err or "Could not save tasks")
    return
  end
  publishStats()
end

-- ── group helpers ────────────────────────────────────────────────────────

local function findGroupIndex(gid)
  for index, group in ipairs(groups) do
    if group.id == gid then
      return index
    end
  end
  return nil
end

local function groupTitle(gid)
  local index = findGroupIndex(gid)
  return index ~= nil and groups[index].title or nil
end

-- The project's tasks, in list order. Rendering filters the flat array rather
-- than nesting, so a task's position inside its project is its array order.
local function tasksInGroup(gid)
  local out = {}
  for _, todo in ipairs(todos) do
    if (todo.group or UNGROUPED) == gid then
      table.insert(out, todo)
    end
  end
  return out
end

local function countGroup(gid)
  local open, total = 0, 0
  for _, todo in ipairs(todos) do
    if (todo.group or UNGROUPED) == gid then
      total += 1
      if not isDone(todo) then
        open += 1
      end
    end
  end
  return open, total
end

-- ── confirm / edit controls ───────────────────────────────────────────────

-- A ✓/✕ pair used for delete confirmation and for the inline title/due
-- editors. `opts.label` adds a warning word on the left, `opts.onCancel`
-- overrides what ✕ does (the default clears both delete confirmations).
local function confirmControls(prefix, onConfirm, opts)
  opts = opts or {}
  local nodes = {}
  if opts.label ~= nil then
    table.insert(nodes, ui.label({ text = opts.label, color = "error", fontSize = 12 }))
  end
  table.insert(nodes, hbtn({
    key = prefix .. "-confirm-yes",
    glyph = "check",
    fill = "primary",
    color = "on_primary",
    tooltip = opts.okTooltip or "Confirm",
    onClick = onConfirm,
  }))
  table.insert(nodes, hbtn({
    key = prefix .. "-confirm-no",
    glyph = "close",
    tooltip = "Cancel",
    onClick = function()
      if opts.onCancel ~= nil then
        opts.onCancel()
      else
        pendingNote = nil
        pendingTodo = nil
      end
      render()
    end,
  }))
  return nodes
end

-- ── notes UI ─────────────────────────────────────────────────────────────

local function togglePin(file)
  if pins[file] then
    pins[file] = nil
  else
    pins[file] = true
  end
  savePins()
  refreshFiles() -- pinned notes sort to the top
  render()
end

local function noteRow(file)
  local isHovered = hoveredNote == file
  local pinned = pins[file] == true
  local children = {
    ui.row({
      key = file,
      flexGrow = 1,
      gap = 6,
      align = "center",
      padding = 7,
      paddingH = 10,
      fill = "surface",
      radius = 6 * cornerRadiusScale,
      borderWidth = 1,
      border = isHovered and "primary" or "#00000000",
      onHover = "onNoteHover",
      onClick = function()
        openNote(file)
      end,
    }, {
      ui.label({ text = displayName(file), maxLines = 1, flexGrow = 1, color = "on_surface" }),
    }),
    hbtn({
      key = "note-pin-" .. file,
      glyph = pinned and "pin-filled" or "pin",
      color = pinned and "primary" or "on_surface",
      tooltip = pinned and "Unpin from the top" or "Pin to the top",
      onClick = function()
        togglePin(file)
      end,
    }),
  }
  if pendingNote == file then
    for _, node in ipairs(confirmControls("note", function()
      deleteNote(file)
    end, { label = "Delete?", okTooltip = "Yes, delete" })) do
      table.insert(children, node)
    end
  else
    table.insert(children, hbtn({
      key = "note-trash-" .. file,
      glyph = "trash",
      tooltip = "Delete note",
      onClick = function()
        pendingNote = file
        render()
      end,
    }))
  end
  return ui.row({ key = "note-" .. file, gap = 6, align = "center" }, children)
end

-- A note matches when the query hits its title (fuzzy or literal) or its body
-- (literal, case-insensitive). Bodies are only read while a query is active.
local function noteMatches(file)
  if searchQuery == "" then
    return true
  end
  local name = displayName(file)
  if noctalia.fuzzyScore(searchQuery, name) ~= nil then
    return true
  end
  local lowered = string.lower(searchQuery)
  if string.find(string.lower(name), lowered, 1, true) then
    return true
  end
  local body = noctalia.readFile(notePath(file))
  return body ~= nil and string.find(string.lower(body), lowered, 1, true) ~= nil
end

local function notesListView()
  local scratchHovered = hoveredNote == SCRATCH
  local rows = {
    -- The scratchpad is always present and is not deletable from here.
    ui.row({ key = "scratchpad", gap = 6, align = "center" }, {
      ui.row({
        key = SCRATCH,
        flexGrow = 1,
        gap = 6,
        align = "center",
        padding = 7,
        paddingH = 10,
        fill = "surface",
        radius = 6 * cornerRadiusScale,
        borderWidth = 1,
        border = scratchHovered and "primary" or "#00000000",
        onHover = "onNoteHover",
        onClick = "onOpenScratchpad",
      }, {
        ui.glyph({ name = "pencil", size = 14, color = "primary" }),
        ui.label({ text = "Scratchpad", maxLines = 1, flexGrow = 1, color = "on_surface" }),
      }),
    }),
  }
  local visible = 0
  for _, file in ipairs(files) do
    if noteMatches(file) then
      table.insert(rows, noteRow(file))
      visible += 1
    end
  end
  if #files == 0 then
    table.insert(rows, ui.label({ text = "No notes yet - hit + to make one.", color = "on_surface_variant", fontSize = 12 }))
  elseif visible == 0 then
    table.insert(rows, ui.label({ text = 'No notes match "' .. searchQuery .. '".', color = "on_surface_variant", fontSize = 12 }))
  end
  -- The search field sits outside the scroll so it never scrolls away, and it
  -- seeds from the live query - a reopen shows what the list is filtered by
  -- instead of a blank box over a filtered list.
  local searchChildren = {
    ui.input({
      key = "notes-search-" .. searchRev,
      value = searchQuery,
      placeholder = "Search notes…",
      flexGrow = 1,
      controlSize = "sm",
      onChange = "onNoteSearchChanged",
    }),
  }
  if searchQuery ~= "" then
    table.insert(searchChildren, hbtn({
      key = "notes-search-clear",
      glyph = "close",
      tooltip = "Clear search",
      onClick = "onNoteSearchClear",
    }))
  end
  return ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, {
    ui.row({ gap = 6, align = "center" }, searchChildren),
    ui.scroll({ flexGrow = 1, gap = 4 }, rows),
  })
end

local function statusLine()
  local words = select(2, buffer:gsub("%S+", ""))
  local chars = utf8.len(buffer) or #buffer
  local status = dirty and "Editing" or "Saved"
  return status .. "  ·  " .. words .. " words · " .. chars .. " chars"
end

local function notesEditorView()
  local trailing = {}
  if pendingNote == current then
    for _, node in ipairs(confirmControls("editor", function()
      deleteNote(current)
    end, { label = "Delete?", okTooltip = "Yes, delete" })) do
      table.insert(trailing, node)
    end
  else
    table.insert(trailing, hbtn({
      key = "editor-trash",
      glyph = "trash",
      tooltip = "Delete note",
      onClick = function()
        pendingNote = current
        render()
      end,
    }))
  end
  local children = {
    hbtn({ key = "editor-back", glyph = "arrow-left", tooltip = "Back to the list", onClick = "onBack" }),
    ui.input({
      key = "rename-" .. current,
      value = displayName(current),
      onSubmit = "onRename",
      -- The scratchpad's identity is its name; renaming it would just respawn it.
      enabled = current ~= SCRATCH,
      flexGrow = 1,
    }),
    hbtn({
      key = "editor-preview",
      text = previewMode and "Edit" or "Preview",
      fontSize = 11,
      padding = 8,
      height = 30,
      selected = previewMode,
      fill = previewMode and "primary/0.2" or nil,
      color = previewMode and "primary" or "on_surface",
      tooltip = previewMode and "Back to editing" or "Render the markdown",
      onClick = "onTogglePreview",
    }),
  }
  for _, node in ipairs(trailing) do
    table.insert(children, node)
  end
  -- Preview renders the saved buffer read-only; Edit reseeds the input with
  -- focus (the rev bumps so the uncontrolled field picks the text up again).
  local body = previewMode and ui.markdown({ text = buffer, flexGrow = 1 }) or ui.input({
    -- The rev reseeds the (uncontrolled) editor when the file changed under us.
    key = "editor-" .. current .. "-" .. editorRev,
    value = buffer,
    multiline = true,
    focus = true,
    flexGrow = 1,
    placeholder = "Write something…",
    onChange = "onEdited",
    onSubmit = "onFlushNow",
  })
  return ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, {
    ui.row({ gap = 6, align = "center" }, children),
    body,
    ui.label({ text = statusLine(), fontSize = 11, color = "on_surface_variant" }),
  })
end

local function notesColumn()
  local isEditor = view == "editor" and current ~= nil
  return ui.column({ width = 440, gap = 8, align = "stretch" }, {
    ui.row({ align = "center", gap = 6 }, {
      ui.label({ text = "Notes", fontSize = 14, fontWeight = "bold", flexGrow = 1, color = "on_surface" }),
      hbtn({
        key = "note-new",
        glyph = "plus",
        fill = "primary",
        color = "on_primary",
        tooltip = "New note",
        onClick = "onNewNote",
      }),
    }),
    isEditor and notesEditorView() or notesListView(),
  })
end

-- ── todo UI ──────────────────────────────────────────────────────────────

-- panel.openContextMenu may only be called from a ui.button's onRightClick,
-- so every row carries a ⋯ button: right-click opens the actions menu,
-- left-click jumps straight into the most common one (rename).
--
-- "Move up/down/top/bottom" are scoped to the task's own project: the menu can
-- only shuffle within a project, and "Move to" changes project (no submenus
-- exist, so destinations are flattened under a header).
local function openTodoMenu(id)
  local index = findIndex(id)
  if index == nil then
    return
  end
  local todo = todos[index]
  local scope = todo.group or UNGROUPED
  local siblings = tasksInGroup(scope)
  local position = nil
  for i, other in ipairs(siblings) do
    if other.id == id then
      position = i
    end
  end

  local items = {
    { kind = "header", label = groupTitle(todo.group) or "Ungrouped" },
    { id = "edit", label = "Edit title" },
    { id = "due", label = todo.due ~= nil and "Change due time…" or "Set due time…" },
    { id = "up", label = "Move up", enabled = position ~= nil and position > 1 },
    { id = "down", label = "Move down", enabled = position ~= nil and position < #siblings },
    { id = "top", label = "Move to top", enabled = position ~= nil and position > 1 },
    { id = "bottom", label = "Move to bottom", enabled = position ~= nil and position < #siblings },
  }
  -- Destinations: every other project plus Ungrouped. Skipped past 40 projects
  -- to stay well inside the menu item limit.
  local moves = {}
  if #groups <= 40 then
    for _, group in ipairs(groups) do
      if group.id ~= todo.group then
        table.insert(moves, { id = "move:" .. group.id, label = group.title })
      end
    end
    if todo.group ~= nil then
      table.insert(moves, { id = "move:" .. UNGROUPED, label = "Ungrouped" })
    end
  end
  if #moves > 0 then
    table.insert(items, { kind = "separator" })
    table.insert(items, { kind = "header", label = "Move to" })
    for _, item in ipairs(moves) do
      table.insert(items, item)
    end
  end
  table.insert(items, { kind = "separator" })
  table.insert(items, { id = "duplicate", label = "Duplicate" })
  table.insert(items, { id = "delete", label = "Delete" })

  local ok = panel.openContextMenu({
    items = items,
    onActivate = "onTodoMenuAction",
    context = id,
    maxVisible = 14,
  })
  if not ok then
    noctalia.notifyError("To-Do", "Right-click the ⋯ button to open the actions menu.")
  end
end

local function todoRow(todo)
  local id = todo.id
  local isHovered = hoveredTodo == id
  local done = isDone(todo)
  local isEditing = editingTodo == id
  local isDueEditing = pendingDue == id
  local inner = {
    ui.glyph({
      name = done and "square-check" or "square",
      size = 16,
      color = done and "primary" or "on_surface_variant",
    }),
  }
  if todo.type == "daily" then
    table.insert(inner, ui.glyph({ name = "calendar-event", size = 13, color = "primary" }))
  end
  if isEditing then
    table.insert(inner, ui.input({
      -- Fresh rev per edit so the uncontrolled field seeds and takes focus.
      key = "todo-edit-" .. id .. "-" .. editRev,
      value = editDraft,
      flexGrow = 1,
      controlSize = "sm",
      focus = true,
      onChange = function(value)
        editDraft = value
      end,
      onSubmit = function(value)
        commitTodoEdit(id, value)
      end,
    }))
  elseif isDueEditing then
    table.insert(inner, ui.input({
      key = "todo-due-" .. id .. "-" .. dueRev,
      value = dueDraft,
      flexGrow = 1,
      controlSize = "sm",
      focus = true,
      placeholder = todo.type == "daily" and "Daily at HH:MM, e.g. 09:30" or "Once at YYYY-MM-DD HH:MM",
      onChange = function(value)
        dueDraft = value
      end,
      onSubmit = function(value)
        commitTodoDue(id, value)
      end,
    }))
  else
    table.insert(inner, ui.label({
      text = todo.title,
      flexGrow = 1,
      maxLines = 2,
      color = done and "on_surface_variant" or "on_surface",
    }))
    if todo.due ~= nil then
      -- Fixed-width stamps, so a lexicographic compare against the same
      -- formatTime() output answers "has it passed?" without calendar math.
      local overdue = isOverdue(todo)
      table.insert(inner, ui.glyph({ name = "clock", size = 12, color = overdue and "error" or "on_surface_variant" }))
      table.insert(inner, ui.label({
        -- "09:30" for a daily, "MM-DD HH:MM" for a dated one: the row is
        -- narrow, and the year is noise while the task is in view.
        text = todo.type == "daily" and todo.due or todo.due:sub(6),
        fontSize = 10,
        color = overdue and "error" or "on_surface_variant",
      }))
    end
  end
  -- Clicking a row that is being edited would toggle it under the caret.
  -- (Built as a variable: `cond and nil or f` always evaluates to f.)
  local toggleOnClick
  if not isEditing and not isDueEditing then
    toggleOnClick = function()
      toggleTodo(id)
    end
  end
  local children = {
    -- The grip is a direct child of the outer row, so previewAncestor = 1
    -- shows (and liftFromLayout removes) the whole row, trash button included.
    ui.dragSource({
      key = "todo-grip-" .. id,
      dragType = DRAG_TYPE,
      payload = "t:" .. id,
      previewAncestor = 1,
      liftFromLayout = true,
      width = 20,
      height = 28,
      align = "center",
      justify = "center",
      tooltip = "Drag to reorder",
    }, {
      ui.glyph({ name = "menu-2", size = 14, color = "on_surface_variant" }),
    }),
    ui.row({
      key = tostring(id),
      flexGrow = 1,
      gap = 8,
      align = "center",
      padding = 7,
      paddingH = 10,
      fill = "surface",
      radius = 6 * cornerRadiusScale,
      borderWidth = 1,
      border = isHovered and "primary" or "#00000000",
      onHover = "onTodoHover",
      onClick = toggleOnClick,
    }, inner),
  }
  if isEditing then
    for _, node in ipairs(confirmControls("todo-edit-" .. id, function()
      commitTodoEdit(id)
    end, { okTooltip = "Save title", onCancel = function()
      editingTodo = nil
    end })) do
      table.insert(children, node)
    end
  elseif isDueEditing then
    for _, node in ipairs(confirmControls("todo-due-" .. id, function()
      commitTodoDue(id)
    end, { okTooltip = "Save due time", onCancel = function()
      pendingDue = nil
    end })) do
      table.insert(children, node)
    end
  elseif pendingTodo == id then
    for _, node in ipairs(confirmControls("todo", function()
      deleteTodo(id)
    end, { label = "Delete?", okTooltip = "Yes, delete" })) do
      table.insert(children, node)
    end
  else
    -- A real ui.button: onRightClick exists only there, and it is the only
    -- place panel.openContextMenu may be called from.
    table.insert(children, ui.button({
      key = "todo-menu-" .. id,
      glyph = "dots-vertical",
      glyphSize = 15,
      width = 32,
      height = 32,
      variant = "ghost",
      tooltip = "Right-click: actions · Left-click: rename",
      onClick = function()
        beginTodoEdit(id)
      end,
      onRightClick = function()
        openTodoMenu(id)
      end,
    }))
    table.insert(children, hbtn({
      key = "todo-trash-" .. id,
      glyph = "trash",
      tooltip = "Delete task",
      onClick = function()
        pendingTodo = id
        render()
      end,
    }))
  end
  return ui.row({ key = "todo-" .. id, gap = 6, align = "center" }, children)
end

-- A thin insertion zone between todo rows. Values are anchored by project and
-- task id ("g:<gid>:before:<id>" / "g:<gid>:after:<id>" / "g:<gid>:end") so
-- the target stays correct even when completed rows are filtered out.
local function todoGap(value)
  return ui.dropZone({
    key = "todo-gap-" .. value,
    accepts = { DRAG_TYPE },
    value = value,
    onDrop = "onReorderTodo",
    height = 3,
    radius = 6,
    expandOnDrag = true, -- grows to the dragged row's height while targeted
    hitSlop = 32, -- reachable from the neighbouring rows without idle space
  })
end

-- Insertion zones around a project header. They accept another project header
-- so projects can be reordered by dragging their grip.
local function groupGap(value)
  return ui.dropZone({
    key = "group-gap-" .. value,
    accepts = { GROUP_DRAG_TYPE },
    value = value,
    onDrop = "onReorderGroup",
    height = 3,
    radius = 6,
    expandOnDrag = true,
    hitSlop = 32,
  })
end

-- An empty drop target, so a task can be dragged into a project (or back out
-- of one) that currently holds nothing.
local function emptyDropZone(value, text, grow)
  local props = {
    key = "todo-empty-" .. value,
    accepts = { DRAG_TYPE },
    value = value,
    onDrop = "onReorderTodo",
    minHeight = 36,
    align = "center",
    justify = "center",
  }
  if grow then
    props.flexGrow = 1
  end
  return ui.dropZone(props, {
    ui.label({ text = text, color = "on_surface_variant", fontSize = 12 }),
  })
end

-- The Once/Daily switch. It lives only in the ungrouped add row and sets the
-- shared default every add row stamps onto the task it submits.
local function typeToggle(kind)
  local selected = addType == kind
  return hbtn({
    key = "type-" .. kind,
    text = kind == "daily" and "Daily" or "Once",
    fontSize = 11,
    padding = 9,
    height = 32,
    selected = selected,
    fill = selected and "primary/0.2" or nil,
    color = selected and "primary" or "on_surface_variant",
    border = "primary",
    tooltip = kind == "daily" and "Unchecks itself when the day changes" or "Finish once, then stay until Clear done",
    onClick = function()
      addType = kind
      render()
    end,
  })
end

-- The add row for one scope (UNGROUPED or a project id). `scope` keys the
-- draft/rev state, so every row keeps its own half-typed text.
local function addRow(scope, placeholder)
  local rev = addRevs[scope] or 0
  local children = {
    ui.input({
      key = "todo-add-" .. scope .. "-" .. rev,
      value = "",
      placeholder = placeholder,
      flexGrow = 1,
      controlSize = "sm",
      onChange = function(value)
        addDrafts[scope] = value or ""
      end,
      onSubmit = function(value)
        submitAdd(scope, value)
      end,
    }),
  }
  if scope == UNGROUPED then
    table.insert(children, typeToggle("once"))
    table.insert(children, typeToggle("daily"))
  end
  table.insert(children, hbtn({
    key = "todo-addbtn-" .. scope,
    glyph = "plus",
    fill = "primary",
    color = "on_primary",
    height = 32,
    tooltip = "Add task",
    onClick = function()
      submitAdd(scope)
    end,
  }))
  return ui.row({ key = "todo-addrow-" .. scope, gap = 6, align = "center" }, children)
end

-- A project's header: drag grip, collapse toggle, name (click to rename) and
-- its open count, plus delete. The header is a heading, not a task: it never
-- carries a checkbox.
local function groupHeaderRow(group)
  local gid = group.id
  local open = countGroup(gid)
  local children = {
    ui.dragSource({
      key = "group-grip-" .. gid,
      dragType = GROUP_DRAG_TYPE,
      payload = "g:" .. gid,
      previewAncestor = 1,
      liftFromLayout = true,
      width = 20,
      height = 28,
      align = "center",
      justify = "center",
      tooltip = "Drag to reorder project",
    }, {
      ui.glyph({ name = "menu-2", size = 14, color = "on_surface_variant" }),
    }),
  }
  if editingGroup == gid then
    table.insert(children, ui.input({
      key = "group-edit-" .. gid .. "-" .. groupRev,
      value = groupDraft,
      flexGrow = 1,
      controlSize = "sm",
      focus = true,
      onSubmit = function(value)
        commitGroupEdit(gid, value)
      end,
    }))
    for _, node in ipairs(confirmControls("group-edit", function()
      commitGroupEdit(gid)
    end, { okTooltip = "Save name", onCancel = function()
      editingGroup = nil
    end })) do
      table.insert(children, node)
    end
  else
    table.insert(children, hbtn({
      key = "group-collapse-" .. gid,
      glyph = group.collapsed and "chevron-right" or "chevron-down",
      tooltip = group.collapsed and "Expand project" or "Collapse project",
      onClick = function()
        toggleGroupCollapse(gid)
      end,
    }))
    table.insert(children, ui.row({
      key = "group-name-" .. gid,
      flexGrow = 1,
      gap = 8,
      align = "center",
      onClick = function()
        beginGroupEdit(gid)
      end,
    }, {
      ui.label({ text = group.title, flexGrow = 1, maxLines = 1, color = "on_surface", fontWeight = "bold" }),
      ui.label({ text = open .. " open", fontSize = 10, color = "on_surface_variant" }),
    }))
    if pendingGroup == gid then
      for _, node in ipairs(confirmControls("group", function()
        deleteGroup(gid)
      end, { label = "Delete?", okTooltip = "Yes, delete project and its tasks" })) do
        table.insert(children, node)
      end
    else
      table.insert(children, hbtn({
        key = "group-trash-" .. gid,
        glyph = "trash",
        tooltip = "Delete project",
        onClick = function()
          pendingGroup = gid
          render()
        end,
      }))
    end
  end
  return ui.row({ key = "group-" .. gid, gap = 6, align = "center", paddingV = 2 }, children)
end

local function todoColumn()
  local open = 0
  local done = 0
  for _, todo in ipairs(todos) do
    if isDone(todo) then
      done += 1
    else
      open += 1
    end
  end
  local rows = {}
  -- Projects first, in their own order. A collapsed project shows only its
  -- header; an expanded one shows its tasks, an empty drop target and its own
  -- add row.
  for _, group in ipairs(groups) do
    local gid = group.id
    table.insert(rows, groupGap("group-before:" .. gid))
    table.insert(rows, groupHeaderRow(group))
    if not group.collapsed then
      local lastVisible = nil
      local shown = 0
      for _, todo in ipairs(tasksInGroup(gid)) do
        if showCompleted or not isDone(todo) then
          table.insert(rows, todoGap("g:" .. gid .. ":before:" .. todo.id))
          table.insert(rows, todoRow(todo))
          lastVisible = todo.id
          shown += 1
        end
      end
      if lastVisible ~= nil then
        table.insert(rows, todoGap("g:" .. gid .. ":after:" .. lastVisible))
      end
      if shown == 0 then
        table.insert(rows, emptyDropZone("g:" .. gid .. ":end", "Drag a task here or add one below."))
      end
      table.insert(rows, addRow(gid, "Add a task to this project…"))
    end
  end
  if #groups > 0 then
    table.insert(rows, groupGap("group-after:" .. groups[#groups].id))
  end

  -- Ungrouped tasks always come last. The section label only appears once
  -- projects exist; on a plain list it would just be noise.
  if #groups > 0 then
    table.insert(rows, ui.label({ text = "Ungrouped", fontSize = 11, color = "on_surface_variant" }))
  end
  local ungrouped = tasksInGroup(UNGROUPED)
  local lastVisible = nil
  local shownUngrouped = 0
  for _, todo in ipairs(ungrouped) do
    if showCompleted or not isDone(todo) then
      table.insert(rows, todoGap("g:" .. UNGROUPED .. ":before:" .. todo.id))
      table.insert(rows, todoRow(todo))
      lastVisible = todo.id
      shownUngrouped += 1
    end
  end
  if lastVisible ~= nil then
    table.insert(rows, todoGap("g:" .. UNGROUPED .. ":after:" .. lastVisible))
  end
  if shownUngrouped == 0 then
    if #groups > 0 then
      table.insert(rows, emptyDropZone("g:" .. UNGROUPED .. ":end", "Drag a task here to ungroup it."))
    elseif #ungrouped == 0 then
      -- A plain empty list stays a valid drop target.
      table.insert(rows, emptyDropZone("g:" .. UNGROUPED .. ":end", "Nothing here yet - type below and press Enter.", true))
    end
  end
  local headerChildren = {
    ui.label({ text = "To-Do", fontSize = 14, fontWeight = "bold", flexGrow = 1, color = "on_surface" }),
    ui.label({
      text = string.format("%d of %d done · %d open", done, open + done, open),
      fontSize = 11,
      color = "on_surface_variant",
    }),
    hbtn({
      key = "todo-new-group",
      glyph = "folder-plus",
      tooltip = "New project",
      onClick = "onNewGroup",
    }),
    hbtn({
      key = "todo-show-completed",
      glyph = showCompleted and "eye" or "eye-off",
      tooltip = showCompleted and "Hide completed" or "Show completed",
      onClick = "onToggleCompleted",
    }),
  }
  if done > 0 then
    table.insert(headerChildren, hbtn({
      key = "todo-clear",
      text = "Clear done",
      fontSize = 11,
      padding = 8,
      height = 30,
      tooltip = "Remove every completed task",
      onClick = "onClearDone",
    }))
  end
  local columnChildren = {
    ui.row({ align = "center", gap = 6 }, headerChildren),
    ui.progress({
      progress = (open + done) > 0 and (done / (open + done)) or 0,
      height = 4,
      radius = 2,
      fill = "primary",
      track = "surface_variant",
    }),
    -- gap 1: the 3px insertion zones between rows carry most of the spacing,
    -- so the list keeps roughly its old density while idle.
    ui.scroll({ flexGrow = 1, gap = 1 }, rows),
    -- The ungrouped add row is pinned below the list so it is always reachable;
    -- project add rows live inside their sections above.
    addRow(UNGROUPED, addType == "daily" and "Add a daily task, press Enter…" or "Add a task, press Enter…"),
  }
  -- Undo strip: the last delete stays restorable for a few seconds. It covers
  -- both a single task and a whole project (with all of its tasks).
  if lastDeleted ~= nil and undoTicks > 0 then
    local undoText, undoGlyph
    if lastDeleted.kind == "group" then
      undoText = 'Deleted project "' .. lastDeleted.group.title .. '"'
      undoGlyph = "folder-x"
    else
      undoText = 'Deleted "' .. lastDeleted.todo.title .. '"'
      undoGlyph = "trash"
    end
    table.insert(columnChildren, ui.row({
      key = "todo-undo",
      gap = 8,
      align = "center",
      padding = 6,
      paddingH = 10,
      fill = "primary/0.15",
      radius = 6 * cornerRadiusScale,
      borderWidth = 1,
      border = "primary",
    }, {
      ui.glyph({ name = undoGlyph, size = 14, color = "primary" }),
      ui.label({
        text = undoText,
        flexGrow = 1,
        maxLines = 1,
        fontSize = 11,
        color = "on_surface",
      }),
      ui.label({ text = undoTicks .. "s", fontSize = 10, color = "on_surface_variant" }),
      hbtn({
        key = "todo-undo-btn",
        text = "Undo",
        fontSize = 11,
        padding = 8,
        height = 26,
        fill = "primary",
        color = "on_primary",
        tooltip = "Bring it back",
        onClick = "onUndoDelete",
      }),
    }))
  end
  return ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, columnChildren)
end

-- ── root ─────────────────────────────────────────────────────────────────

render = function()
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch", padding = 0 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = "Notes & To-Do", fontSize = 16, fontWeight = "bold", flexGrow = 1, color = "on_surface" }),
      hbtn({ key = "header-close", glyph = "close", tooltip = "Close", onClick = "onClosePanel" }),
    }),
    ui.separator({ thickness = 1, color = "surface_variant" }),
    ui.row({ flexGrow = 1, gap = 14, align = "stretch" }, {
      notesColumn(),
      ui.separator({ orientation = "vertical", thickness = 1, color = "surface_variant" }),
      todoColumn(),
    }),
  }))
end

-- ── lifecycle ────────────────────────────────────────────────────────────

function onOpen(_context)
  local ok, err = noctalia.mkdirAll(notesDir)
  if not ok then
    noctalia.notifyError("Notes", err or "")
  end
  loadTodos()
  publishStats() -- the bar widget starts from the same numbers
  loadPins()
  refreshFiles()
  pendingNote = nil
  pendingTodo = nil
  pendingGroup = nil
  editingTodo = nil
  editingGroup = nil
  pendingDue = nil
  previewMode = false
  lastDeleted = nil
  undoTicks = 0
  currentDay = today()
  panelOpen = true
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  flush()
  panelOpen = false
end

function update()
  -- Daily tasks roll back to open on a date change, even if the panel stays up.
  local day = today()
  if day ~= currentDay then
    currentDay = day
    publishStats()
    render()
  end
  if undoTicks > 0 then
    undoTicks -= 1
    if undoTicks == 0 then
      lastDeleted = nil
    end
    render() -- the countdown label has to move every second
  end
  if dirty then
    idleTicks += 1
    if idleTicks >= AUTOSAVE_IDLE_TICKS then
      flush()
      render()
    end
  end
end

-- ── notes callbacks ──────────────────────────────────────────────────────

function onOpenScratchpad()
  openNote(SCRATCH)
end

function onNewNote()
  newNote()
end

function onEdited(value)
  buffer = value
  idleTicks = 0
  dirty = true
  render() -- the status line carries the live word/char count
end

function onFlushNow(value)
  buffer = value
  dirty = true
  idleTicks = 0
  flush()
  render()
end

function onBack()
  flush()
  view = "list"
  current = nil
  buffer = ""
  pendingNote = nil
  refreshFiles()
  render()
end

function onRename(value)
  if current == nil then
    return
  end
  local name = noctalia.string.trim(value):gsub("/", "")
  if name == "" or name == displayName(current) then
    render()
    return
  end
  local target = name .. SUFFIX
  if noctalia.fileExists(notePath(target)) then
    noctalia.notifyError("Notes", "A note with that name already exists.")
    render()
    return
  end
  flush()
  local ok, err = noctalia.renameFile(notePath(current), notePath(target))
  if not ok then
    noctalia.notifyError("Notes", err or "")
    render()
    return
  end
  local previous = current
  current = target
  if pins[previous] then
    pins[previous] = nil
    pins[target] = true
    savePins()
  end
  refreshFiles()
  render()
end

function onNoteHover(state, key)
  hoveredNote = (state == "true") and key or nil
  render()
end

function onNoteSearchChanged(value)
  searchQuery = value or ""
  -- No rev bump: the field keeps focus (and its caret) while you type.
  render()
end

function onNoteSearchClear()
  searchQuery = ""
  searchRev += 1 -- reseed so the uncontrolled field empties
  render()
end

function onTogglePreview()
  if current == nil then
    return
  end
  flush() -- the preview and the status line both read the saved state
  if previewMode then
    editorRev += 1 -- reseed the uncontrolled input when editing resumes
  end
  previewMode = not previewMode
  render()
end

-- ── todo callbacks ───────────────────────────────────────────────────────

function toggleTodo(id)
  local index = findIndex(id)
  if index == nil then
    return
  end
  local todo = todos[index]
  if todo.type == "daily" then
    -- The date is the switch: stamp today, or clear the stamp.
    if isDone(todo) then
      todo.doneDay = nil
    else
      todo.doneDay = today()
    end
  else
    todo.done = not todo.done
  end
  pendingTodo = nil
  saveTodos()
  render()
end

function deleteTodo(id)
  local index = findIndex(id)
  if index == nil then
    return
  end
  -- Park the task (and where it lived) so the undo strip can put it back.
  lastDeleted = { kind = "todo", todo = table.remove(todos, index), index = index }
  undoTicks = UNDO_TICKS
  pendingTodo = nil
  editingTodo = nil
  pendingDue = nil
  saveTodos()
  render()
end

function onUndoDelete()
  if lastDeleted == nil then
    return
  end
  if lastDeleted.kind == "group" then
    local at = math.min(lastDeleted.groupIndex or (#groups + 1), #groups + 1)
    table.insert(groups, at, lastDeleted.group)
    for _, todo in ipairs(lastDeleted.tasks or {}) do
      table.insert(todos, todo)
    end
  elseif lastDeleted.todo ~= nil then
    local index = math.min(lastDeleted.index or (#todos + 1), #todos + 1)
    table.insert(todos, index, lastDeleted.todo)
  end
  lastDeleted = nil
  undoTicks = 0
  saveTodos()
  render()
end

-- scope is UNGROUPED (0) or a project id. A project add row only shows the
-- input and +; the type comes from the shared default set in the bottom row.
function submitAdd(scope, value)
  -- A button click may hand us an empty key, so fall back to the draft.
  local fallback = addDrafts[scope] or ""
  local title = noctalia.string.trim((value ~= nil and value ~= "") and value or fallback)
  if title == "" then
    render()
    return
  end
  local todo = { id = nextId, title = title, type = addType }
  if addType == "once" then
    todo.done = false
  end
  if scope ~= UNGROUPED then
    todo.group = scope
  end
  table.insert(todos, todo)
  nextId += 1
  addDrafts[scope] = ""
  addRevs[scope] = (addRevs[scope] or 0) + 1 -- reseed the input so it starts empty
  saveTodos()
  render()
end

function onToggleCompleted()
  showCompleted = not showCompleted
  render()
end

function onClearDone()
  local kept = {}
  for _, todo in ipairs(todos) do
    if not isDone(todo) then
      table.insert(kept, todo)
    end
  end
  todos = kept
  pendingTodo = nil
  saveTodos()
  render()
end

function onTodoHover(state, key)
  hoveredTodo = (state == "true") and tonumber(key) or nil
  render()
end

-- Lua patterns have no `|` alternation, so each shape is matched on its own.
-- Returns gid (number), place ("before" | "after" | "end"), anchor (number|nil).
local function parseMoveValue(value, currentGid)
  local gid = currentGid
  local body = value or ""
  local prefixed = string.match(body, "^g:(%d+):(.+)$")
  if prefixed ~= nil then
    gid = tonumber(prefixed)
    body = string.match(body, "^g:%d+:(.+)$") or ""
  end
  if body == "end" then
    return gid, "end", nil
  end
  local anchor = string.match(body, "^before:(%d+)$")
  if anchor ~= nil then
    return gid, "before", tonumber(anchor)
  end
  anchor = string.match(body, "^after:(%d+)$")
  if anchor ~= nil then
    return gid, "after", tonumber(anchor)
  end
  return gid, nil, nil
end

-- Drag-and-drop move: the host hands us the dragged id (payload "t:<id>") and
-- the zone's value. Values name the destination project, so a drop can also
-- change project:
--   "g:<gid>:before:<id>"  "g:<gid>:after:<id>"  "g:<gid>:end"
-- The legacy "before:<id>" / "after:<id>" / "end" keep the task in its project.
function onReorderTodo(payload, value)
  local id = tonumber(payload) or tonumber(string.match(payload or "", "^t:(%d+)$"))
  local from = id ~= nil and findIndex(id) or nil
  if from == nil then
    render()
    return
  end
  local todo = todos[from]

  local targetGid, place, anchor = parseMoveValue(value, todo.group or UNGROUPED)
  if place == nil then
    render()
    return
  end
  if targetGid ~= UNGROUPED and findGroupIndex(targetGid) == nil then
    targetGid = UNGROUPED -- the project vanished between drag and drop
  end
  if anchor ~= nil and anchor == id then
    -- Dropped beside itself: the task already sits there, leave the list alone.
    render()
    return
  end
  table.remove(todos, from)
  todo.group = targetGid ~= UNGROUPED and targetGid or nil
  local target = #todos + 1
  if anchor ~= nil then
    local anchorIndex = findIndex(anchor)
    if anchorIndex ~= nil then
      target = place == "before" and anchorIndex or (anchorIndex + 1)
    end
  end
  table.insert(todos, target, todo)
  pendingTodo = nil
  render() -- model on screen first, then persist
  saveTodos()
end

-- Project reorder: payload "g:<id>", value "group-before:<id>" / "group-after:<id>".
function onReorderGroup(payload, value)
  local id = tonumber(string.match(payload or "", "^g:(%d+)$")) or tonumber(payload)
  local from = id ~= nil and findGroupIndex(id) or nil
  if from == nil then
    render()
    return
  end
  local beforeId = string.match(value or "", "^group%-before:(%d+)$")
  local afterId = string.match(value or "", "^group%-after:(%d+)$")
  local place = beforeId ~= nil and "before" or (afterId ~= nil and "after" or nil)
  local anchor = tonumber(beforeId or afterId)
  if place == nil or anchor == nil or anchor == id or findGroupIndex(anchor) == nil then
    render()
    return
  end
  local group = table.remove(groups, from)
  -- Re-resolve the anchor: removing the dragged header shifted indices.
  local anchorIndex = findGroupIndex(anchor)
  local to = place == "before" and anchorIndex or (anchorIndex + 1)
  table.insert(groups, to, group)
  saveTodos()
  render()
end

-- Project lifecycle. Like the inline editors below, these are globals because
-- they are referenced from closures built in the UI section above.
function onNewGroup()
  local group = { id = nextId, title = "New project", collapsed = false }
  nextId += 1
  table.insert(groups, group)
  saveTodos()
  beginGroupEdit(group.id)
end

function beginGroupEdit(gid)
  if findGroupIndex(gid) == nil then
    return
  end
  editingGroup = gid
  pendingGroup = nil
  editingTodo = nil
  pendingDue = nil
  pendingTodo = nil
  groupDraft = groupTitle(gid) or ""
  groupRev += 1 -- fresh key: the uncontrolled input seeds and takes focus
  render()
end

function commitGroupEdit(gid, value)
  local index = findGroupIndex(gid)
  if index == nil then
    editingGroup = nil
    render()
    return
  end
  local title = noctalia.string.trim((value ~= nil and value ~= "") and value or groupDraft)
  if title ~= "" then
    -- Empty text simply cancels: a project must keep a name.
    groups[index].title = title
    saveTodos()
  end
  editingGroup = nil
  render()
end

function toggleGroupCollapse(gid)
  local index = findGroupIndex(gid)
  if index == nil then
    return
  end
  groups[index].collapsed = not groups[index].collapsed
  saveTodos()
  render()
end

-- Deleting a project deletes its tasks with it; both go on the undo strip, so
-- one tap brings the project and all of its tasks back.
function deleteGroup(gid)
  local index = findGroupIndex(gid)
  if index == nil then
    return
  end
  local group = table.remove(groups, index)
  local removed = {}
  for i = #todos, 1, -1 do
    if todos[i].group == gid then
      table.insert(removed, 1, table.remove(todos, i))
    end
  end
  lastDeleted = { kind = "group", group = group, groupIndex = index, tasks = removed }
  undoTicks = UNDO_TICKS
  pendingGroup = nil
  editingGroup = nil
  saveTodos()
  render()
end

-- Move a task to another project (or to the ungrouped section, gid UNGROUPED).
function moveTodoToGroup(id, gid)
  local index = findIndex(id)
  if index == nil then
    return
  end
  if gid ~= UNGROUPED and findGroupIndex(gid) == nil then
    return
  end
  local todo = table.remove(todos, index)
  todo.group = gid ~= UNGROUPED and gid or nil
  table.insert(todos, todo) -- appended, so it lands last in the target project
  saveTodos()
  render()
end

-- ── inline edit / due / menu actions ─────────────────────────────────────
--
-- All globals: they are called from closures built much earlier in the file,
-- and globals resolve at call time so saveTodos/findIndex (locals defined
-- above this section) stay visible.

function beginTodoEdit(id)
  local index = findIndex(id)
  if index == nil then
    return
  end
  editingTodo = id
  pendingDue = nil
  pendingTodo = nil
  editingGroup = nil
  pendingGroup = nil
  editDraft = todos[index].title
  editRev += 1 -- fresh key: the uncontrolled input seeds and takes focus
  render()
end

function commitTodoEdit(id, value)
  local index = findIndex(id)
  if index == nil then
    editingTodo = nil
    render()
    return
  end
  local title = noctalia.string.trim((value ~= nil and value ~= "") and value or editDraft)
  if title ~= "" then
    -- Empty text simply cancels: a task must keep a title.
    todos[index].title = title
    saveTodos()
  end
  editingTodo = nil
  render()
end

function beginTodoDue(id)
  local index = findIndex(id)
  if index == nil then
    return
  end
  pendingDue = id
  editingTodo = nil
  pendingTodo = nil
  dueDraft = todos[index].due or ""
  dueRev += 1
  render()
end

function commitTodoDue(id, value)
  local index = findIndex(id)
  if index == nil then
    pendingDue = nil
    render()
    return
  end
  local raw = value ~= nil and value or dueDraft
  local todo = todos[index]
  local due, err = parseDue(raw, todo.type)
  if due == nil and err ~= nil then
    noctalia.notifyError("To-Do", err)
    return -- keep the input open so the text can be corrected
  end
  todo.due = due -- nil clears the due time
  pendingDue = nil
  saveTodos()
  render()
end

-- Menu actions resolve against the live list every time: the panel may have
-- re-rendered (or the list changed) between opening the menu and clicking.
function onTodoMenuAction(actionId, context)
  local id = tonumber(context)
  if id == nil then
    return
  end
  if actionId == "edit" then
    beginTodoEdit(id)
  elseif actionId == "due" then
    beginTodoDue(id)
  elseif actionId == "up" then
    moveTodo(id, -1)
  elseif actionId == "down" then
    moveTodo(id, 1)
  elseif actionId == "top" then
    moveTodo(id, "top")
  elseif actionId == "bottom" then
    moveTodo(id, "bottom")
  elseif actionId == "duplicate" then
    duplicateTodo(id)
  elseif actionId == "delete" then
    deleteTodo(id)
  elseif actionId:sub(1, 5) == "move:" then
    moveTodoToGroup(id, tonumber(actionId:sub(6)) or UNGROUPED)
  end
end

-- target: -1 / 1 (nudge), "top", or "bottom". Scoped to the task's own
-- project: the visible order is that project's slice of the flat array, so
-- moving shuffles the task within its project (or the ungrouped section).
function moveTodo(id, target)
  local from = findIndex(id)
  if from == nil then
    return
  end
  local todo = todos[from]
  local siblings = tasksInGroup(todo.group or UNGROUPED)
  local position = nil
  for i, other in ipairs(siblings) do
    if other.id == id then
      position = i
    end
  end
  if position == nil then
    render()
    return
  end
  local to
  if target == "top" then
    to = 1
  elseif target == "bottom" then
    to = #siblings
  elseif type(target) == "number" then
    to = math.max(1, math.min(#siblings, position + target))
  end
  if to == nil or to == position then
    render()
    return
  end
  -- Rebuild the project order, then splice the task back into the flat array
  -- right after its new predecessor (nil = first of the project).
  local order = {}
  for i, other in ipairs(siblings) do
    if i ~= position then
      table.insert(order, other)
    end
  end
  table.insert(order, to, todo)
  local anchor = order[to - 1]
  table.remove(todos, from)
  if anchor ~= nil then
    local anchorIndex = findIndex(anchor.id)
    table.insert(todos, anchorIndex ~= nil and (anchorIndex + 1) or (#todos + 1), todo)
  else
    table.insert(todos, 1, todo)
  end
  saveTodos()
  render()
end

function duplicateTodo(id)
  local index = findIndex(id)
  if index == nil then
    return
  end
  local source = todos[index]
  -- A copy starts open even when the original is done; the due time carries
  -- over since it describes the same work, and it stays in the same project.
  local copy = { id = nextId, title = source.title, type = source.type }
  if copy.type == "once" then
    copy.done = false
  end
  if source.due ~= nil then
    copy.due = source.due
  end
  if source.group ~= nil then
    copy.group = source.group
  end
  nextId += 1
  table.insert(todos, index + 1, copy)
  saveTodos()
  render()
end

-- ── shared callbacks ─────────────────────────────────────────────────────

function onClosePanel()
  panel.close()
end

function onUiHover(state, key)
  hoveredBtn = (state == "true") and key or nil
  render()
end

-- ── shell IPC ────────────────────────────────────────────────────────────
-- noctalia msg plugin riciolus/notes-todo:panel all <event> [payload]
--
-- `add` and `add-daily` insert a task from outside the panel (opencode, a
-- script, a keybind). While the panel is closed the in-memory list only
-- reflects its last open, so the handler re-reads todos.json first - an
-- external add must never resurrect old tasks or drop new ones. While the
-- panel is open the list is live, so the row is inserted and rendered in
-- place without touching pending note edits.
--
-- `reload` re-reads todos.json and the notes directory while the panel is
-- open, for writers that fall back to editing those files directly. Nothing
-- to do when it is closed: onOpen() reads everything anyway.
function onIpc(event, payload)
  if event == "add" or event == "add-daily" then
    local title = noctalia.string.trim(payload or "")
    if title == "" then
      return
    end
    if not panelOpen then
      loadTodos()
    end
    local todo = { id = nextId, title = title, type = event == "add-daily" and "daily" or "once" }
    if todo.type == "once" then
      todo.done = false
    end
    nextId += 1
    table.insert(todos, todo)
    saveTodos()
    if panelOpen then
      render()
    end
  elseif event == "reload" and panelOpen then
    loadTodos()
    refreshFiles()
    publishStats()
    render()
  end
end
