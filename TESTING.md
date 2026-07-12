# Testing hyprgrid

The grid (`workspace-grid.lua`) is developed and tested against a **fake Hyprland written in Lua**, so the
real script can be driven through user scenarios and asserted on with zero risk to any running session.
(This exists because testing on the live session repeatedly caused real damage — lost windows, duplicate
workspaces. See the "golden rule" in [CLAUDE.md](CLAUDE.md).)

## Run

```sh
cd ~/other/hyprgrid
lua run.lua                        # all tests/*.lua   (lua 5.4/5.5 or luajit)
lua run.lua tests/navigation.lua   # one file
```

## Layout

```
workspace-grid.lua          the grid itself (kept byte-for-byte in sync with ~/.config/hypr/workspace-grid.lua)
stub/hyprland.lua           StubHyprland: a fake `hl`/`o` API over an in-memory compositor model
harness.lua                 test framework + helpers (boot the grid, press keys, open/close windows, assert)
run.lua                     runner
tests/
  hyprland_behaviors.lua    the learned Hyprland behaviors, as tests (guards the stub's fidelity)
  navigation.lua            row navigation stays within a column; all 8 tags reachable
  multimonitor.lua          move-column-across-monitors, split-healing
  compaction.lua            empty-row squeeze + description shift, incl. the duplicate-workspace regression
```

## How the fake works

`stub/hyprland.lua` keeps an in-memory model — monitors (each shows one active workspace), workspaces
(name, id, monitor, window count, persistent flag), windows, and per-tag descriptions — and implements the
slice of the `hl`/`o` API the grid uses (`get_workspaces`, `get_monitors`, `dispatch`,
`dsp.focus/workspace.move/workspace.rename/window.move`, `workspace_rule`, `bind`, `on`, `timer`, `o.bind`, …).

A test resets it, `loadfile`s the real grid script (so its binds/handlers register), then drives it:

- `H.press("SUPER + CTRL + J")` — invoke the callback bound to those keys
- `H.open("2a")` / `H.close(addr)` — add/remove a window, firing `window.open` / `window.destroy`
- `H.close_all_on("2a")` — empty a workspace; `H.set_desc("b","beta")` / `H.desc("a")` — read/write descriptions
- `H.add_mon("DP-3", 7680)` / `H.rm_mon(...)` — simulate monitor hotplug / resume
- `H.timers()` — fire the debounced heal timer
- assertions: `H.expect_active`, `H.expect_focused`, `H.expect_no_duplicates`, `H.expect_windows`, `H.expect_absent`, …

## The behaviors it reproduces (each a bug we hit live)

These live as tests in `tests/hyprland_behaviors.lua` — the stub is only useful insofar as they hold:

- A monitor always shows one workspace; the focused monitor's is the global active workspace.
- **Empty, non-persistent workspaces are disposed the instant they stop being visible** (fires `workspace.removed`).
- **Focusing a workspace that doesn't exist creates it** on the focused monitor.
- **Renaming onto an existing name produces a duplicate** — the "two `2a` workspaces" disaster.
- **Renaming drops the (name-keyed) persistent rule**, so renaming an *empty* workspace disposes it; a
  *windowed* one survives (its window follows).
- `workspace_rule{persistent=true}` creates the workspace if missing; `{persistent=false}` disposes it if
  empty and not visible.
- A negative number is a *relative* workspace selector, not an id (so a specific duplicate can't be targeted
  by its negative id).

## Deliberate non-fidelity

The stub is **synchronous and deterministic**. Real Hyprland (0.55 / Aquamarine) has async focus/event races
we can't reproduce; several live bugs were race artifacts. This harness tests the grid's *logic* — packing,
renumber, persistence, which column/row/monitor gets chosen — not timing. Treat green as "the logic is
right," still smoke-test a risky change on real windows, and when a new real behavior turns up, add it to
`tests/hyprland_behaviors.lua` first.

## Row-wise tag compaction (built here, tested, live)

`reconcile_tags` implements it: when a tag row is empty in every column, it's squeezed out and the higher tags
renumber down across all columns, with the shared per-tag descriptions shifting to match. The duplicate-`2a`
collision that destroyed the live session is reproduced in `tests/compaction.lua` ("compacting the tag you're
VIEWING") and prevented — before renaming, every monitor is parked on its home column so no empty cell is on
screen to collide with a rename target. The description shift shells out to `hypr-ws-desc remap OLD=NEW …`
(a subcommand added to `~/.local/bin/hypr-ws-desc`).

## Why not a real headless Hyprland in Docker (what we tried)

The original plan was docker-compose running a headless Hyprland with fake monitors. It doesn't work cleanly:
Hyprland 0.55 uses the **Aquamarine** backend, which insists on either real KMS hardware or a modern,
exactly-version-matched parent compositor.

| Attempt | Outcome |
|---|---|
| DRM backend on the host GPU | Would open KMS on `card1` and **fight the live session over the displays** — unsafe, ruled out. |
| `seatd` + DRM | Seat opens but is VT-bound; can't open the KMS device inside a container. |
| Nested in Weston (pixman) | Aquamarine's Wayland backend: *"Missing protocols"* (no `dmabuf`). |
| Nested in Weston (GL, render node only) | Protocol **version mismatch** — Hyprland wants `wl_compositor` v6, Weston offers v5. |
| Nested in sway | Wouldn't launch in the container. |

There is no `AQ_BACKENDS`-style "headless-only" switch; the headless backend only comes up as a fallback
output inside a backend that already started, and a compositor-in-compositor stack that *did* start would be
fragile (breaks on any Arch/Hyprland/wlroots bump). So we dropped it for the Lua stub. If true end-to-end
coverage is ever wanted, the most promising path is a host with the `vkms` (virtual KMS) kernel module loaded.
