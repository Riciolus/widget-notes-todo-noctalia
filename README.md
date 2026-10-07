# Notes & To-Do

One panel, two columns: **notes on the left**, **to-do list on the right**.

| Field | Value |
| --- | --- |
| ID | `riciolus/notes-todo` |
| Entries | Bar widget: `main`; panel: `panel`; service: `reminders` |
| Version | `1.4.0` |

## Usage

- Left-click the bar widget to open or close the panel.
- Bind the panel to a compositor key if you want a shortcut:

```sh
noctalia msg panel-toggle riciolus/notes-todo:panel
```

**Notes (left)** — a scratchpad plus dated notes, click a row to edit. Edits
autosave after a one-second pause in typing, when you navigate away, and when
the panel closes. Rename with the title field, delete with the trash button
(second click confirms).

- **Search** — the field above the list matches titles (fuzzy or literal) and
  note bodies, so you can find text without opening each file. The ✕ clears it.
- **Pin** — the pin button on a row keeps a note at the top of the list,
  ahead of the recency order; unpin to drop it back. Pins live in `pins.json`
  and follow a note through a rename.
- **Preview** — *Preview* in the editor header renders the markdown read-only;
  *Edit* returns to the text field.

**To-Do (right)** — pick **Once** or **Daily** next to the add field, type a
task and press Enter (or the + button). Click a row to toggle it done, hide
completed with the eye button, clear them in bulk with *Clear done*. Drag a
row by its grip (☰, far left) onto a highlight between rows to reorder the
list; the order is saved to `todos.json`.

- **One-time** — done stays checked until *Clear done*.
- **Daily** — carries a `calendar-event` badge. Checking it stamps today's
  date; it flips back to open by itself when the date changes (while the panel
  is open, or the next time anything reads the list), so every day starts
  unchecked.
- **Task menu** — right-click the `⋯` button on a row (or left-click it to
  jump straight to renaming) for: edit title, set/change a due time, move
  up / down / to top / to bottom, duplicate, delete. Move up/down/to-top is
  also the keyboard-accessible alternative to dragging.
- **Inline editing** — the title edit and the due-time field each confirm with
  ✓ and cancel with ✕; Escape-side mistakes cost nothing (empty titles are
  ignored rather than wiping the task).
- **Due times** — a daily task takes `HH:MM`, a one-time task
  `YYYY-MM-DD HH:MM`. The stamp shows next to the title and turns red while
  overdue (and not done).
- **Undo** — deleting a task leaves a strip at the bottom of the column for
  six seconds; *Undo* puts it back where it was.
- **Progress** — the header reads `n of m done · k open` above a completion
  bar.

**Bar widget** — shows the completion rail and `open/total` on a horizontal
bar (stacked glyph + ratio on a vertical bar), and lists the first five open
task titles on hover.

**Shell IPC** — other tools (opencode, scripts, keybinds) can drive the panel:

```sh
noctalia msg plugin riciolus/notes-todo:panel all add "buy milk"   # one-time
noctalia msg plugin riciolus/notes-todo:panel all add-daily "gym"  # daily
noctalia msg plugin riciolus/notes-todo:panel all reload           # re-read file state
```

The panel entry stays loaded while the panel is closed, so `add` re-reads
`todos.json` before appending — an external insert never resurrects stale
tasks or drops fresh ones. While the panel is open the row is inserted and
rendered in place. `reload` picks up direct writes to `todos.json` or
`notes/*.md` while the panel is open. A thin wrapper around all of this lives
at `~/.local/bin/noctalia-todo` (`add [--daily]`, `note`, `list`), with an
atomic file fallback for when the shell is unreachable.

**Reminders** — the `reminders` service runs in the background and fires a
desktop notification when a task comes due, at most once per due slot and
within a four-hour grace window.

**Hover** — nothing changes its background on hover; buttons and list rows keep
their fill and only outline themselves with the accent border.

## Storage

Everything lives in the plugin's persistent data directory:

- `notes/*.md` — the notes
- `pins.json` — pinned note filenames
- `todos.json` — the task list (`type`: `once` | `daily`; daily completion is
  the `doneDay` field; `due` holds the optional due time)
- `reminders-notified.json` — which due slots the reminder service already
  fired (capped, oldest entries dropped)

## Development

Local drop-in, hot-reloads on `.luau` edits:

```sh
~/.local/share/noctalia/plugins/notes-todo/
noctalia plugins lint ~/.local/share/noctalia/plugins/notes-todo
noctalia msg plugins enable riciolus/notes-todo
```

## Credits

This plugin was written with AI assistance — designed, implemented, linted and
debugged by [opencode](https://opencode.ai) running the `big-pickle` model
(`opencode/big-pickle`). The human provided the requirements, made the UX calls
(notes left / to-dos right, top-right placement, panel geometry) and verified
the result on screen.
