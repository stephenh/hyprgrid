# Waybar: per-monitor task descriptions

This is the waybar half of hyprgrid. It shows, **on each monitor's bar**, the description of the
workspace that monitor is currently displaying:

- A monitor on a **home workspace** shows that column's own label — `1 → IDE`, `2 → terminal`,
  `3 → personal browser`.
- A monitor on a **grid workspace** shows the **active task's** description — `a → skills`,
  `b → hyprgrid` — the same on every monitor, because the grid moves in lock-step.

The description is keyed so the two cases share one store: a grid workspace keys on its **tag letter**
(shared across columns), a home workspace keys on its **own number** (per-column label). See `key_for`
in `hypr-ws-desc`.

## Files

| File | Installs to | Purpose |
|---|---|---|
| `hypr-ws-desc` | `~/.local/bin/hypr-ws-desc` | Reads/writes descriptions; `show <MON>` prints the description for the workspace on monitor `<MON>`. |
| `workspace-descriptions.default.json` | `~/.config/hypr/workspace-descriptions.default.json` | Git-tracked defaults for the **home** columns; seeded into the runtime store on login. |
| `config.jsonc` | `~/.config/waybar/config.jsonc` | One waybar bar **per monitor**, each passing its own monitor name to `hypr-ws-desc show`. |
| `shared.jsonc` | `~/.config/waybar/shared.jsonc` | The bar each per-monitor block includes. A **minimal example** here (workspaces + description); on a real setup it's your own full bar. |

The runtime store lives at `~/.local/state/hypr/workspace-descriptions.json` (ephemeral; reset from the
defaults on login via `hypr-ws-desc seed`). Grid-tag descriptions (`a`, `b`, …) are added there at
runtime as you name tasks with `Super+D`, and are renumbered by the grid's `reconcile_tags` (which shells
out to `hypr-ws-desc remap OLD=NEW …`).

## Why one bar per monitor

A waybar `custom` module can't tell which monitor its bar is on, so a single global module would read the
*focused* workspace and print the same description on every monitor. Instead, `config.jsonc` is an **array
of bars** — one per output — and each bar overrides `custom/workspace-description` to pass its own monitor
name (`hypr-ws-desc show DP-2`). Every bar `include`s `shared.jsonc` — a relative include waybar resolves
from `~/.config/waybar/` — so the full module set is defined once, in your own bar.

The grid refreshes all bars on any workspace change: `workspace-grid.lua` runs `pkill -RTMIN+11 waybar`,
and the module listens on `signal: 11`.

## Tag ordering

Set **`sort-by: "name"`** on your `hyprland/workspaces` module so a column's tags display in tag order
(`3, 3a, 3b`). Grid workspaces are *named* workspaces whose negative ids are handed out in creation order,
so the usual `sort-by: "number"` orders same-column tags by *when they were created* — visit task `b`
before task `a` and the bar shows `3b` before `3a`. Sorting by name keeps them alphabetical.

> Trade-off: a two-digit home column (`10`, i.e. `Super+0`) then string-sorts before single-digit columns
> that share its monitor (`10` before `2a`). Harmless unless that column sits next to grid tags.

## Wiring it in

1. Install the script and defaults:
   ```sh
   cp waybar/hypr-ws-desc ~/.local/bin/ && chmod +x ~/.local/bin/hypr-ws-desc
   cp waybar/workspace-descriptions.default.json ~/.config/hypr/
   ```
2. Put the per-monitor bars in place, plus the `shared.jsonc` they include. Either **keep your own bar**
   (recommended — you keep your clock, tray, etc.):
   ```sh
   mv ~/.config/waybar/config.jsonc ~/.config/waybar/shared.jsonc   # your existing bar
   cp waybar/config.jsonc ~/.config/waybar/config.jsonc             # the per-monitor array
   ```
   …then give that `shared.jsonc` a `hyprland/workspaces` module (with `sort-by: "name"`) and a default
   `custom/workspace-description` (`"exec": "$HOME/.local/bin/hypr-ws-desc show"`) in `modules-left`. Or
   **start from the minimal example** (`waybar/shared.jsonc`, just those two modules):
   ```sh
   cp waybar/config.jsonc waybar/shared.jsonc ~/.config/waybar/
   ```
3. Set the `output` names to your monitors — one bar block each (`hyprctl monitors -j | jq -r '.[].name'`).
   The `include` is a relative `"shared.jsonc"` that waybar resolves from `~/.config/waybar/`, so there's no
   path to edit.
4. `omarchy restart waybar` (or `pkill waybar; waybar &`).

> `omarchy refresh waybar` resets `config.jsonc` back to the stock single-bar config — re-apply this
> template if you ever run it.
