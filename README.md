# hyprgrid — native Hyprland workspaces for juggling many agents across many tasks

Running a dozen coding agents at once, each chewing on a different task, is miserable on a tmux-shaped desk:
every task collapses into a wall of terminal panes, and you end up fluent in two overlapping
window-management languages at the same time — your compositor's and tmux's. **hyprgrid** puts each *task*
on its own set of **native Hyprland workspaces** instead, so a task can own a real IDE window, a browser,
and its terminals together, and you drive all of it with the window-manager keys you already know.

## The model

Picture a grid:

- **Columns** are your monitors / roles — the numbered home workspaces `1..9`. Each monitor sits in a column
  (e.g. `1` = editor screen, `2` = terminals, `3` = browser/personal).
- **Tags** (rows `a..h`) are your **tasks**. A tag spans every column, so tag `a` is one task's slice on all
  monitors, tag `b` the next task's, and so on. Each tag carries a **description** — the task's name
  (`skills`, `bug-one`) — shown in waybar.
- **One keystroke switches the whole task, everywhere.** `Super+Ctrl+J/K` walks every monitor to the same tag
  in lock-step: flip to tag `a` and your editor monitor shows `1a`, terminals monitor `2a`, browser monitor
  `3a` — the entire desktop reconfigures to that task at once. `Super+Ctrl+1..9` jump straight to a task.

So: spin up an agent per task, give each task a tag, and hop between them instantly — every hop bringing that
task's full multi-window, multi-monitor layout with it.

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
