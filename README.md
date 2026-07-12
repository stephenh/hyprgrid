# hyprgrid — native Hyprland workspaces for juggling many agents

![hyprgrid: four columns (Zed, Terminal, Browser, Logs) across task rows a–d; each cell is its own
workspace (1a, 2b, 3d…), rows are sparse, and the focus band slides between tasks in lock-step across every
column](docs/grid.gif)

Multi-tasking with agents involves "way more windows" than traditional window management.

I.e. pre-agents, I worked on _one thing at a time_ 😅, and so Hyprland's numbered `1-9` workspaces to manage my ~5-6 windows (IDE on `1`, a few terminals on `2`, a browser or two on `3`) were plenty!

But now driving agents across 5 tasks simultaneously, we go from "about 6" windows to manage -> `6 x 5 = 30` windows 🤯.

This is a very common problem, and often solved with tmux -- but:

1. tmux can only drive terminals -- what about my IDEs and browser windows?
2. tmux requires another set of key binds to do tmux window/pane management.

Instead, hyprgrid teaches Hyprland how to drive _lots_ of workspaces.

Specifically we create a "grid" of many workspaces:

* Columns in the grid are your tools -- the IDEs are column `1`, the terminals are column `2`
* Rows in the grid are tasks, with single letter abbreviations -- `a` is working updating skills, `b` is work task one, `c` is work task two, etc.

Each workspace in then grid is then a column number + task tag:

- `1a` is "the IDE for task a"
- `2a` is "the terminal(s) for task a"
- `3a` is "the browser(s)" for task a"
- etc.

The killer feature of hyprgrid is providing key binds & Lua routines to:

1. Stay on task -- if I'm working on task `b`, any `super+1/2/3` keybind moves to the same task's `1b/2b/3b` workspace
2. Switch tasks -- if I switch to task `c`, all workspaces move together, so `1a` on Monitor 1 and `2a` on Monitor 2 would both move to `1b` and `2b` at the same time.

## Why not tmux

- **Real windows, not just terminals.** tmux panes only hold terminals. A hyprgrid task is native Hyprland
  workspaces, so it can tie together your editor GUI, a browser, a PDF viewer — anything — right next to its
  terminals.
- **One set of binds, not two.** tmux bolts a second, prefix-key window-management layer on top of your
  compositor's. hyprgrid uses a single system — Hyprland's own binds — for splitting, moving, and switching.
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

The grid is complex enough — lock-step, persistent tags, split-healing, row compaction — that editing the
*live* session to test it kept causing real damage. So it's developed against a **fake Hyprland, in Lua**,
with zero risk to any running session:

```sh
cd ~/other/hyprgrid && lua run.lua      # runs the real grid against the stub (lua 5.4/5.5 or luajit)
```

See **[TESTING.md](TESTING.md)** for how the fake works, the Hyprland behaviors it reproduces, and the
"why not a headless Hyprland in Docker" write-up. See **[CLAUDE.md](CLAUDE.md)** for the change workflow
(the golden rule: never debug the grid on the live session — reproduce it in the harness first).
