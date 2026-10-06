# Notes & To-Do

One panel, two columns: **notes on the left**, **to-do list on the right**.

| Field | Value |
| --- | --- |
| ID | `riciolus/notes-todo` |
| Entries | Bar widget: `main`; panel: `panel` |

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

**To-Do (right)** — pick **Once** or **Daily** next to the add field, type a
task and press Enter (or the + button). Click a row to toggle it done, hide
completed with the eye button, clear them in bulk with *Clear done*.

- **One-time** — done stays checked until *Clear done*.
- **Daily** — carries a `calendar-event` badge. Checking it stamps today's
  date; it flips back to open by itself when the date changes (while the panel
  is open, or the next time anything reads the list), so every day starts
  unchecked.

**Hover** — nothing changes its background on hover; buttons and list rows keep
their fill and only outline themselves with the accent border.

## Storage

Everything lives in the plugin's persistent data directory:

- `notes/*.md` — the notes
- `todos.json` — the task list (`type`: `once` | `daily`; daily completion is
  the `doneDay` field)

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
