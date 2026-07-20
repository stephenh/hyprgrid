# CLAUDE.md — working on hyprgrid

This repo is a Hyprland 2D-workspace-grid (`workspace-grid.lua`) plus a Lua test harness for it. Read
[README.md](README.md) for what the grid is for, and [TESTING.md](TESTING.md) for how the harness works.

## Golden rule: never debug the grid on the live session

Editing `~/.config/hypr/workspace-grid.lua` and driving `hyprctl` to test it has repeatedly destroyed the
live desktop — lost windows, duplicate workspaces, a home workspace renamed away. **Do not do it.** Every
grid change goes through the harness first.

Concretely, when driving `hyprctl` (even for diagnosis), NEVER:
- close/kill windows by class or in bulk (only ever a single, address-verified window you spawned);
- rename or move the user's workspaces to "fix" something;
- target a workspace by a negative id — that's a *relative* selector and will hit the wrong workspace.

## The change workflow

1. Edit `./workspace-grid.lua` (the copy in this repo), not the live one.
2. **Reproduce the desired behavior or bug as a failing test** in `tests/` (use `tests/compaction.lua` as a
   model). Bugs get a regression test *before* the fix.
3. `lua run.lua` until green (also works under `luajit`).
4. If you learned a new *Hyprland* behavior, encode it in `tests/hyprland_behaviors.lua` first — the stub is
   only trustworthy insofar as those hold.
5. Port to live. **FIRST `diff ~/.config/hypr/workspace-grid.lua ./workspace-grid.lua`** — the live file may
   carry edits made outside this repo (e.g. a hand-added `hl.workspace_rule{...}`); fold any such lines into
   `./workspace-grid.lua` *before* overwriting, or the `cp` silently clobbers them. (Diffing only *after*
   the `cp` is useless — it always matches.) Then `cp ./workspace-grid.lua ~/.config/hypr/workspace-grid.lua`,
   `hyprctl reload && hyprctl configerrors` (must be empty), and `diff -q` to confirm byte-identical.
6. Ask the user to smoke-test on real windows before trusting it — the stub is synchronous; real Hyprland's
   focus is async (that gap is where the remaining risk lives).

Do not commit; the user reviews the jujutsu working copy in `~/.config` and `~/.local/bin`. Leave a
`.bak.<epoch>` next to any live file you overwrite.

## Things that bite

- **`stub/hyprland.lua` is deterministic and synchronous.** It models *logic*, not async focus races. A
  green suite means the logic is right, not that live behavior is proven.
- **Descriptions live outside the grid**, in `~/.local/bin/hypr-ws-desc` (a JSON store keyed by tag letter /
  home number). When tags renumber, the grid shells out to `hypr-ws-desc remap OLD=NEW …` to shift them; that
  subcommand must exist for the live grid to work. The stub interprets that same command so tests can assert
  on descriptions.
- **`MAX_ROWS`** (in `workspace-grid.lua`) is the single knob for how many tags exist (`MAX_ROWS = 9` →
  tags `a..h`). Everything else scales off it.
- **Real headless Hyprland in Docker was tried and abandoned** (Aquamarine needs real KMS or a
  version-matched parent compositor) — see TESTING.md. Don't retry it without a reason.
