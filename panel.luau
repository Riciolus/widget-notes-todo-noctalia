--!nonstrict
-- Notes on the left, to-do list on the right, in one panel.
--
-- Notes are .md files in <plugin data>/notes and the tasks live in
-- <plugin data>/todos.json. The note editor autosaves after a short pause in
-- typing, on navigation, and on panel close.

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
local todos = {} -- { { id, title, done } }
local nextId = 1
local showCompleted = true
local addDraft = ""

-- Shared UI state
local hoveredNote = nil
local hoveredTodo = nil
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

local function pendingCount()
  local n = 0
  for _, todo in ipairs(todos) do
    if not todo.done then
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
      table.insert(todos, { id = id, title = item.title, done = item.done == true })
      if id >= nextId then
        nextId = id + 1
      end
    end
  end
end

local function saveTodos()
  local ok, err = noctalia.writeFile(todosPath, noctalia.json.encode(todos))
  if not ok then
    noctalia.notifyError("To-Do", err or "Could not save tasks")
    return
  end
  publishCount()
end

-- ── confirm-delete controls ──────────────────────────────────────────────

local function confirmControls(onConfirm)
  return {
    ui.label({ text = "Delete?", color = "error", fontSize = 12 }),
    ui.button({ glyph = "check", variant = "primary", onClick = onConfirm }),
    ui.button({
      glyph = "close",
      variant = "ghost",
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
      fill = isHovered and "tertiary" or "surface",
      radius = 6 * cornerRadiusScale,
      onHover = "onNoteHover",
      onClick = function()
        openNote(file)
      end,
    }, {
      ui.label({ text = displayName(file), maxLines = 1, flexGrow = 1, color = "on_surface" }),
    }),
  }
  if pendingNote == file then
    for _, node in ipairs(confirmControls(function()
      deleteNote(file)
    end)) do
      table.insert(children, node)
    end
  else
    table.insert(children, ui.button({
      glyph = "trash",
      variant = "ghost",
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
        fill = scratchHovered and "tertiary" or "surface",
        radius = 6 * cornerRadiusScale,
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
    for _, node in ipairs(confirmControls(function()
      deleteNote(current)
    end)) do
      table.insert(trailing, node)
    end
  else
    table.insert(trailing, ui.button({
      glyph = "trash",
      variant = "ghost",
      onClick = function()
        pendingNote = current
        render()
      end,
    }))
  end
  local children = {
    ui.button({ glyph = "arrow-left", variant = "ghost", onClick = "onBack" }),
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
      ui.button({ key = "note-new", glyph = "plus", variant = "primary", onClick = "onNewNote" }),
    }),
    isEditor and notesEditorView() or notesListView(),
  })
end

-- ── todo UI ──────────────────────────────────────────────────────────────

local function todoRow(todo)
  local id = todo.id
  local isHovered = hoveredTodo == id
  local children = {
    ui.row({
      key = tostring(id),
      flexGrow = 1,
      gap = 8,
      align = "center",
      padding = 7,
      paddingH = 10,
      fill = isHovered and "tertiary" or "surface",
      radius = 6 * cornerRadiusScale,
      onHover = "onTodoHover",
      onClick = function()
        toggleTodo(id)
      end,
    }, {
      ui.glyph({
        name = todo.done and "square-check" or "square",
        size = 16,
        color = todo.done and "primary" or "on_surface_variant",
      }),
      ui.label({
        text = todo.title,
        flexGrow = 1,
        maxLines = 2,
        color = todo.done and "on_surface_variant" or "on_surface",
      }),
    }),
  }
  if pendingTodo == id then
    for _, node in ipairs(confirmControls(function()
      deleteTodo(id)
    end)) do
      table.insert(children, node)
    end
  else
    table.insert(children, ui.button({
      glyph = "trash",
      variant = "ghost",
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
    if todo.done then
      done += 1
    else
      open += 1
    end
  end
  local rows = {}
  for _, todo in ipairs(todos) do
    if showCompleted or not todo.done then
      table.insert(rows, todoRow(todo))
    end
  end
  if #rows == 0 then
    table.insert(rows, ui.label({ text = "Nothing here yet - type below and press Enter.", color = "on_surface_variant", fontSize = 12 }))
  end
  local headerChildren = {
    ui.label({ text = "To-Do", fontSize = 14, fontWeight = "bold", flexGrow = 1, color = "on_surface" }),
    ui.label({ text = open .. " open", fontSize = 11, color = "on_surface_variant" }),
    ui.button({
      key = "todo-show-completed",
      glyph = showCompleted and "eye" or "eye-off",
      variant = "ghost",
      onClick = "onToggleCompleted",
    }),
  }
  if done > 0 then
    table.insert(headerChildren, ui.button({
      key = "todo-clear",
      text = "Clear done",
      variant = "ghost",
      controlSize = "sm",
      onClick = "onClearDone",
    }))
  end
  return ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, {
    ui.row({ align = "center", gap = 6 }, headerChildren),
    ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = "todo-add-" .. addRev,
        value = "",
        placeholder = "Add a task, press Enter…",
        flexGrow = 1,
        controlSize = "sm",
        onChange = "onAddChanged",
        onSubmit = "onAddSubmit",
      }),
      ui.button({ glyph = "plus", variant = "primary", controlSize = "sm", onClick = "onAddSubmit" }),
    }),
    ui.scroll({ flexGrow = 1, gap = 4 }, rows),
  })
end

-- ── root ─────────────────────────────────────────────────────────────────

render = function()
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch", padding = 14 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = "Notes & To-Do", fontSize = 16, fontWeight = "bold", flexGrow = 1, color = "on_surface" }),
      ui.button({ key = "header-close", glyph = "close", variant = "ghost", onClick = "onClosePanel" }),
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
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  flush()
end

function update()
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
  todos[index].done = not todos[index].done
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
  local title = noctalia.string.trim(value ~= nil and value or addDraft)
  if title == "" then
    render()
    return
  end
  table.insert(todos, { id = nextId, title = title, done = false })
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
    if not todo.done then
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
