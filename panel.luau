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
local SCRATCH = "scratch" .. SUFFIX

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
local todos = {} -- { { id, title, type, done?, doneDay?, due? } }
local nextId = 1
local showCompleted = true
local addDraft = ""
local addType = "once" -- type stamped on the next submitted task
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
local addRev = 0 -- bumped to reseed the (uncontrolled) add input
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

local function loadTodos()
  todos = {}
  nextId = 1
  local raw = noctalia.readFile(todosPath)
  if raw == nil or raw == "" then
    return
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    return
  end
  for _, item in ipairs(decoded) do
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
      table.insert(todos, {
        id = id,
        title = item.title,
        -- Anything written before types existed is a one-time task.
        type = kind,
        done = item.done == true,
        doneDay = type(item.doneDay) == "string" and item.doneDay or nil,
        due = due,
      })
      if id >= nextId then
        nextId = id + 1
      end
    end
  end
end

local function saveTodos()
  -- Write an explicit shape: daily tasks carry doneDay and no done flag.
  local out = {}
  for _, todo in ipairs(todos) do
    local row = { id = todo.id, title = todo.title, due = todo.due }
    if todo.type == "daily" then
      row.type = "daily"
      row.doneDay = todo.doneDay
    else
      row.type = "once"
      row.done = todo.done == true
    end
    table.insert(out, row)
  end
  local ok, err = noctalia.writeFile(todosPath, noctalia.json.encode(out))
  if not ok then
    noctalia.notifyError("To-Do", err or "Could not save tasks")
    return
  end
  publishStats()
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
local function openTodoMenu(id)
  local index = findIndex(id)
  if index == nil then
    return
  end
  local todo = todos[index]
  local ok = panel.openContextMenu({
    items = {
      { kind = "header", label = "Task" },
      { id = "edit", label = "Edit title" },
      { id = "due", label = todo.due ~= nil and "Change due time…" or "Set due time…" },
      { id = "up", label = "Move up", enabled = index > 1 },
      { id = "down", label = "Move down", enabled = index < #todos },
      { id = "top", label = "Move to top", enabled = index > 1 },
      { id = "bottom", label = "Move to bottom", enabled = index < #todos },
      { kind = "separator" },
      { id = "duplicate", label = "Duplicate" },
      { id = "delete", label = "Delete" },
    },
    onActivate = "onTodoMenuAction",
    context = id,
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
      payload = tostring(id),
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

-- A thin insertion zone between todo rows. Values are id-anchored
-- ("before:<id>" / "after:<id>") so the target stays correct even when
-- completed rows are filtered out of the list.
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
  local lastVisible = nil
  for _, todo in ipairs(todos) do
    if showCompleted or not isDone(todo) then
      table.insert(rows, todoGap("before:" .. todo.id))
      table.insert(rows, todoRow(todo))
      lastVisible = todo.id
    end
  end
  if #rows == 0 then
    -- An empty list stays a valid drop target so a task can be dragged back in.
    table.insert(rows, ui.dropZone({
      key = "todo-empty",
      accepts = { DRAG_TYPE },
      value = "end",
      onDrop = "onReorderTodo",
      flexGrow = 1,
      align = "center",
      justify = "center",
    }, {
      ui.label({ text = "Nothing here yet - type below and press Enter.", color = "on_surface_variant", fontSize = 12 }),
    }))
  else
    table.insert(rows, todoGap("after:" .. lastVisible))
  end
  local headerChildren = {
    ui.label({ text = "To-Do", fontSize = 14, fontWeight = "bold", flexGrow = 1, color = "on_surface" }),
    ui.label({
      text = string.format("%d of %d done · %d open", done, open + done, open),
      fontSize = 11,
      color = "on_surface_variant",
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
    ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = "todo-add-" .. addRev,
        value = "",
        placeholder = addType == "daily" and "Add a daily task, press Enter…" or "Add a task, press Enter…",
        flexGrow = 1,
        controlSize = "sm",
        onChange = "onAddChanged",
        onSubmit = "onAddSubmit",
      }),
      hbtn({
        key = "type-once",
        text = "Once",
        fontSize = 11,
        padding = 9,
        height = 32,
        selected = addType == "once",
        fill = addType == "once" and "primary/0.2" or nil,
        color = addType == "once" and "primary" or "on_surface_variant",
        border = "primary",
        tooltip = "Finish once, then stay until Clear done",
        onClick = function()
          addType = "once"
          render()
        end,
      }),
      hbtn({
        key = "type-daily",
        text = "Daily",
        fontSize = 11,
        padding = 9,
        height = 32,
        selected = addType == "daily",
        fill = addType == "daily" and "primary/0.2" or nil,
        color = addType == "daily" and "primary" or "on_surface_variant",
        border = "primary",
        tooltip = "Unchecks itself when the day changes",
        onClick = function()
          addType = "daily"
          render()
        end,
      }),
      hbtn({
        key = "todo-add",
        glyph = "plus",
        fill = "primary",
        color = "on_primary",
        height = 32,
        tooltip = "Add task",
        onClick = "onAddSubmit",
      }),
    }),
    -- gap 1: the 3px insertion zones between rows carry most of the spacing,
    -- so the list keeps roughly its old density while idle.
    ui.scroll({ flexGrow = 1, gap = 1 }, rows),
  }
  -- Undo strip: the last deleted task stays restorable for a few seconds.
  if lastDeleted ~= nil and undoTicks > 0 and lastDeleted.todo ~= nil then
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
      ui.glyph({ name = "trash", size = 14, color = "primary" }),
      ui.label({
        text = 'Deleted "' .. lastDeleted.todo.title .. '"',
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
        tooltip = "Bring the task back",
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
  editingTodo = nil
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
  lastDeleted = { todo = table.remove(todos, index), index = index }
  undoTicks = UNDO_TICKS
  pendingTodo = nil
  editingTodo = nil
  pendingDue = nil
  saveTodos()
  render()
end

function onUndoDelete()
  if lastDeleted == nil or lastDeleted.todo == nil then
    return
  end
  local index = math.min(lastDeleted.index or (#todos + 1), #todos + 1)
  table.insert(todos, index, lastDeleted.todo)
  lastDeleted = nil
  undoTicks = 0
  saveTodos()
  render()
end

function onAddChanged(value)
  addDraft = value or ""
end

function onAddSubmit(value)
  -- A button click may hand us an empty key, so fall back to the draft.
  local title = noctalia.string.trim((value ~= nil and value ~= "") and value or addDraft)
  if title == "" then
    render()
    return
  end
  local todo = { id = nextId, title = title, type = addType }
  if addType == "once" then
    todo.done = false
  end
  table.insert(todos, todo)
  nextId += 1
  addDraft = ""
  addRev += 1 -- reseed the input so it starts empty again
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

-- Drag-and-drop reorder: the host hands us the dragged id (payload) and the
-- zone's value ("before:<id>", "after:<id>" or "end"). The anchor is resolved
-- after the removal, so dropping next to the row the task came from is a no-op.
function onReorderTodo(payload, value)
  local id = tonumber(payload)
  local from = id ~= nil and findIndex(id) or nil
  if from == nil then
    render()
    return
  end
  local todo = table.remove(todos, from)
  local place, anchorId = string.match(value, "^(before|after):(%d+)$")
  if place ~= nil and tonumber(anchorId) == id then
    -- Dropped beside itself: the task already sits there, leave the list alone.
    table.insert(todos, from, todo)
    render()
    return
  end
  local target = #todos + 1
  if place ~= nil then
    local anchor = findIndex(tonumber(anchorId))
    if anchor ~= nil then
      target = place == "before" and anchor or (anchor + 1)
    end
  end
  table.insert(todos, target, todo)
  pendingTodo = nil
  render() -- model on screen first, then persist
  saveTodos()
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
  end
end

-- target: -1 / 1 (nudge), "top", or "bottom". Index math happens after the
-- removal, so nudging into the end of the list lands where you expect.
function moveTodo(id, target)
  local from = findIndex(id)
  if from == nil then
    return
  end
  local to
  if target == "top" then
    to = 1
  elseif target == "bottom" then
    to = #todos
  elseif type(target) == "number" then
    to = math.max(1, math.min(#todos, from + target))
  end
  if to == nil or to == from then
    render()
    return
  end
  local todo = table.remove(todos, from)
  table.insert(todos, to, todo)
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
  -- over since it describes the same work.
  local copy = { id = nextId, title = source.title, type = source.type }
  if copy.type == "once" then
    copy.done = false
  end
  if source.due ~= nil then
    copy.due = source.due
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
