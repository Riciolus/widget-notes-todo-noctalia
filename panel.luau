--!nonstrict
-- Notes on the left, to-do list on the right, in one panel.
--
-- Notes are .md files in <plugin data>/notes and the tasks live in
-- <plugin data>/todos.json. Tasks are one-time or daily; a daily task is done
-- only while its doneDay matches today, so it resets itself at midnight. The
-- note editor autosaves after a short pause in typing, on navigation, and on
-- panel close.

local AUTOSAVE_IDLE_TICKS = 2 -- 1s panel ticks with no edits before a flush
local SUFFIX = ".md"
local SCRATCH = "scratch" .. SUFFIX

local dataDir = noctalia.pluginDataDir()
local notesDir = dataDir .. "/notes"
local todosPath = dataDir .. "/todos.json"

-- Notes state
local files = {}
local view = "list" -- "list" | "editor"
local current = nil -- filename while the editor is open
local buffer = ""
local loadedContent = "" -- what the file held when we last read/wrote it
local editorRev = 0 -- bumped to reseed the editor input after external changes
local dirty = false
local idleTicks = 0

-- Todo state
local todos = {} -- { { id, title, type, done?, doneDay? } }
local nextId = 1
local showCompleted = true
local addDraft = ""
local addType = "once" -- type stamped on the next submitted task
local currentDay = "" -- local YYYY-MM-DD, watched for the daily reset

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

local function pendingCount()
  local n = 0
  for _, todo in ipairs(todos) do
    if not isDone(todo) then
      n += 1
    end
  end
  return n
end

local function publishCount()
  noctalia.state.set("pendingCount", pendingCount())
end

local function findIndex(id)
  for index, todo in ipairs(todos) do
    if todo.id == id then
      return index
    end
  end
  return nil
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
  -- Most recently edited first.
  local mtimes = {}
  for _, name in ipairs(files) do
    local info = noctalia.fileInfo(notePath(name))
    mtimes[name] = info ~= nil and info.mtime or 0
  end
  table.sort(files, function(a, b)
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
      table.insert(todos, {
        id = id,
        title = item.title,
        -- Anything written before types existed is a one-time task.
        type = item.type == "daily" and "daily" or "once",
        done = item.done == true,
        doneDay = type(item.doneDay) == "string" and item.doneDay or nil,
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
    if todo.type == "daily" then
      table.insert(out, { id = todo.id, title = todo.title, type = "daily", doneDay = todo.doneDay })
    else
      table.insert(out, { id = todo.id, title = todo.title, type = "once", done = todo.done == true })
    end
  end
  local ok, err = noctalia.writeFile(todosPath, noctalia.json.encode(out))
  if not ok then
    noctalia.notifyError("To-Do", err or "Could not save tasks")
    return
  end
  publishCount()
end

-- ── confirm-delete controls ──────────────────────────────────────────────

local function confirmControls(prefix, onConfirm)
  return {
    ui.label({ text = "Delete?", color = "error", fontSize = 12 }),
    hbtn({
      key = prefix .. "-confirm-yes",
      glyph = "check",
      fill = "primary",
      color = "on_primary",
      tooltip = "Yes, delete",
      onClick = onConfirm,
    }),
    hbtn({
      key = prefix .. "-confirm-no",
      glyph = "close",
      tooltip = "Cancel",
      onClick = function()
        pendingNote = nil
        pendingTodo = nil
        render()
      end,
    }),
  }
end

-- ── notes UI ─────────────────────────────────────────────────────────────

local function noteRow(file)
  local isHovered = hoveredNote == file
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
  }
  if pendingNote == file then
    for _, node in ipairs(confirmControls("note", function()
      deleteNote(file)
    end)) do
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
  for _, file in ipairs(files) do
    table.insert(rows, noteRow(file))
  end
  if #files == 0 then
    table.insert(rows, ui.label({ text = "No notes yet - hit + to make one.", color = "on_surface_variant", fontSize = 12 }))
  end
  return ui.scroll({ flexGrow = 1, gap = 4 }, rows)
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
    end)) do
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
  }
  for _, node in ipairs(trailing) do
    table.insert(children, node)
  end
  return ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, {
    ui.row({ gap = 6, align = "center" }, children),
    ui.input({
      -- The rev reseeds the (uncontrolled) editor when the file changed under us.
      key = "editor-" .. current .. "-" .. editorRev,
      value = buffer,
      multiline = true,
      focus = true,
      flexGrow = 1,
      placeholder = "Write something…",
      onChange = "onEdited",
      onSubmit = "onFlushNow",
    }),
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

local function todoRow(todo)
  local id = todo.id
  local isHovered = hoveredTodo == id
  local done = isDone(todo)
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
  table.insert(inner, ui.label({
    text = todo.title,
    flexGrow = 1,
    maxLines = 2,
    color = done and "on_surface_variant" or "on_surface",
  }))
  local children = {
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
      onClick = function()
        toggleTodo(id)
      end,
    }, inner),
  }
  if pendingTodo == id then
    for _, node in ipairs(confirmControls("todo", function()
      deleteTodo(id)
    end)) do
      table.insert(children, node)
    end
  else
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
  for _, todo in ipairs(todos) do
    if showCompleted or not isDone(todo) then
      table.insert(rows, todoRow(todo))
    end
  end
  if #rows == 0 then
    table.insert(rows, ui.label({ text = "Nothing here yet - type below and press Enter.", color = "on_surface_variant", fontSize = 12 }))
  end
  local headerChildren = {
    ui.label({ text = "To-Do", fontSize = 14, fontWeight = "bold", flexGrow = 1, color = "on_surface" }),
    ui.label({ text = open .. " open", fontSize = 11, color = "on_surface_variant" }),
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
  return ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, {
    ui.row({ align = "center", gap = 6 }, headerChildren),
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
    ui.scroll({ flexGrow = 1, gap = 4 }, rows),
  })
end

-- ── root ─────────────────────────────────────────────────────────────────

render = function()
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch", padding = 14 }, {
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
  refreshFiles()
  pendingNote = nil
  pendingTodo = nil
  currentDay = today()
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  flush()
end

function update()
  -- Daily tasks roll back to open on a date change, even if the panel stays up.
  local day = today()
  if day ~= currentDay then
    currentDay = day
    publishCount()
    render()
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
  current = target
  refreshFiles()
  render()
end

function onNoteHover(state, key)
  hoveredNote = (state == "true") and key or nil
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
  table.remove(todos, index)
  pendingTodo = nil
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

-- ── shared callbacks ─────────────────────────────────────────────────────

function onClosePanel()
  panel.close()
end

function onUiHover(state, key)
  hoveredBtn = (state == "true") and key or nil
  render()
end
