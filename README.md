# hyprgrid — use native Hyprland workspaces to juggle many agents

![hyprgrid: four columns (Zed, Terminal, Browser, Logs) across task rows a–d; each cell is its own
workspace (1a, 2b, 3d…), rows are sparse, and the focus band slides between tasks in lock-step across every
column](docs/grid.gif)

Multi-tasking with agents involves "way more windows" than traditional window management.

I.e. pre-agents, I worked on _one thing at a time_ 😅, and so Hyprland's numbered `1-9` workspaces to manage my ~5-6 windows were plenty! I would have an IDE on `1`, a few terminals on `2`, a browser or two on `3`, all good.

But now driving agents across 5 tasks simultaneously, we go from "about 6" windows to manage -> `6 x 5 = 30` windows to manage 🤯.

This is a common problem, and often solved with tmux--but:

1. tmux can only drive terminals--what about my IDEs and browser windows?
2. tmux requires another set of key binds to do tmux window/pane management.

Instead, hyprgrid teaches Hyprland how to drive _lots_ of workspaces.

Specifically we create a "grid" of many workspaces (see the animated gif above):

* Columns in the grid are your tools -- the IDEs are column `1`, the terminals are column `2`
* Rows in the grid are tasks, with single letter abbreviations -- `a` is working updating skills, `b` is work task one, `c` is work task two, etc.
* Each "cell" in a grid is a workspace dedicated to that "tool x task" combination
  - `1a` is "the IDE for task a"
  - `1b` is "the IDE for task b"
  - `2a` is "the terminal(s) for task a"
  - `2b` is "the terminal(s) for task b"
  - etc.

The killer features of hyprgrid are key binds & Lua routines to:

1. Stay on task -- if I'm working on task `b`, any `super+1/2/3` keybind moves to "that column/tool" (i.e. `super+1` moves to column `1` but picks the `1b` task workspace in that column)
2. Switch tasks -- if I switch to task `c`, all columns/tools move together, so `1b` on Monitor 1 and `2b` on Monitor 2 would both move to `1c` and `2c` at the same time (i.e. show task `c`s IDE & terminal simultaneously)

## Why not tmux

- **Real windows, not just terminals.** tmux panes only hold terminals. A hyprgrid task is multiple native Hyprland
  workspaces, so it can manage your editor GUI, a browser, a PDF viewer — anything — right next to its terminals.
- **One set of binds.** tmux requires a second, prefix-key window-management layer on top of your
  compositor's binds. hyprgrid uses a single system — Hyprland — for splitting, moving, and switching.
  Nothing archaic to memorize twice, no OS-vs-tmux bind collisions.

## What the grid gives you

- **Lock-step task switching** across every monitor at once (columns not in the grid are left alone).
- **Self-compacting tasks:** empty a task's row and it's squeezed out; the higher tasks renumber down to stay
  contiguous (`c→b`, `d→c`) across all columns simultaneously — and each task's **description rides along**
  with it.
- **Split-healing:** if a resume or monitor hotplug scatters a column's workspaces, they rejoin their monitor.
- **Move a whole task/column across monitors**, and **move a single window between tasks**.
- Per-task **descriptions** in waybar via `~/.local/bin/hypr-ws-desc`.

`workspace-grid.lua` is the whole implementation. It lives in `~/.config/hypr/` and is kept byte-for-byte in
sync with the copy in this repo.

## Install

hyprgrid runs on **Hyprland's native Lua config**. The task descriptions also use `jq` and waybar. Omarchy ships all three.

**1. The grid.** Drop the script in and load it from your Lua entrypoint:

```sh
cp workspace-grid.lua ~/.config/hypr/
```
```lua
-- in ~/.config/hypr/hyprland.lua
require("hypr.workspace-grid")
```

`hyprctl reload`, and the [keybinds](#keybinds) below are live. The number of tasks is the single knob at
the top of the script — `MAX_ROWS = 9` gives tags `a..h` (8 tasks); bump it for more.

**2. Descriptions in waybar.** The per-monitor task labels are a small separate piece — the `hypr-ws-desc`
script, a defaults file, and a one-bar-per-monitor waybar config. See **[waybar/README.md](waybar/README.md)**
for the wiring.

**3. Agent-done alerts (optional).** Make a task's workspace **pulse in waybar** when a Claude Code or
opencode agent finishes in an unfocused window (terminal bell → Hyprland urgent). See
**[notify/README.md](notify/README.md)**.

### Workspace defaults

- **Columns are just the standard numbered workspaces.** Home columns `1..9` are Hyprland/Omarchy's default
  `Super+1..9` workspaces — hyprgrid only adds the vertical (tag) axis on top.
- **Default column labels** live in `waybar/workspace-descriptions.default.json` — git-tracked, shared
  across machines, and seeded into the runtime store on login (`hypr-ws-desc seed`). Edit it to set your own:

  | Workspace | Default label |
  |---|---|
  | `1` | IDE |
  | `2` | terminal |
  | `3` | personal browser |
  | `4` | work browser |
  | `5` | debug browser |
  | `7` | code reviews |
  | `8` | slack |
  | `0` | roam |

- **Task (tag) descriptions** — `a = skills`, `b = hyprgrid` — aren't defaults: you set them per task with
  `Super+D`, and the grid renumbers them for you as tasks compact.

## Keybinds

| Keys | Action |
|---|---|
| `Super+Ctrl+J` / `Super+Ctrl+K` | Next / previous **task** (all monitors, lock-step) |
| `Super+Ctrl+1..9` | Jump to home / task `a..h` |
| `Super+1..0` | Switch a monitor to column `1..10` (staying on the current task) |
| `Super+Ctrl+Shift+J` / `…+K` | Move the focused window **down / up a task** |
| `Super+Ctrl+L` / `Super+Ctrl+H` | Walk to the next / previous workspace in grid order |
| `Super+Shift+O` / `Super+Shift+Y` | Move the whole column to the monitor on the right / left |
| `Super+D` | Set the current task's description |

## Developing & testing

The grid is complex enough that we develop & regression test against a **fake Hyprland, in Lua**,
with zero risk to any running session:

```sh
cd ~/other/hyprgrid && lua run.lua      # runs the real grid against the stub (lua 5.4/5.5 or luajit)
```

See **[TESTING.md](TESTING.md)** for how the fake works, the Hyprland behaviors it reproduces, and the
"why not a headless Hyprland in Docker" write-up. See **[CLAUDE.md](CLAUDE.md)** for the change workflow
(the golden rule: never debug the grid on the live session — reproduce it in the harness first).
