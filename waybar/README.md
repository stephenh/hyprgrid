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

The runtime store lives at `~/.local/state/hypr/workspace-descriptions.json` (ephemeral; reset from the
defaults on login via `hypr-ws-desc seed`). Grid-tag descriptions (`a`, `b`, …) are added there at
runtime as you name tasks with `Super+D`, and are renumbered by the grid's `reconcile_tags` (which shells
out to `hypr-ws-desc remap OLD=NEW …`).

## Why one bar per monitor

A waybar `custom` module can't tell which monitor its bar is on, so a single global module would read the
*focused* workspace and print the same description on every monitor. Instead, `config.jsonc` is an **array
of bars** — one per output — and each bar overrides `custom/workspace-description` to pass its own monitor
name (`hypr-ws-desc show DP-2`). Every bar `include`s your existing single-bar config as `shared.jsonc`, so
the full module set is defined once.

The grid refreshes all bars on any workspace change: `workspace-grid.lua` runs `pkill -RTMIN+11 waybar`,
and the module listens on `signal: 11`.

## Wiring it in

1. Install the script and defaults:
   ```sh
   cp waybar/hypr-ws-desc ~/.local/bin/ && chmod +x ~/.local/bin/hypr-ws-desc
   cp waybar/workspace-descriptions.default.json ~/.config/hypr/
   ```
2. Move your **current** waybar `config.jsonc` aside as `shared.jsonc`, and make sure it defines a default
   `custom/workspace-description` module (`"exec": "$HOME/.local/bin/hypr-ws-desc show"`) somewhere in
   `modules-left`:
   ```sh
   mv ~/.config/waybar/config.jsonc ~/.config/waybar/shared.jsonc
   cp waybar/config.jsonc ~/.config/waybar/config.jsonc
   ```
3. Edit `~/.config/waybar/config.jsonc` — it's a template. **Adjust for your machine:**
   - the `output` names to your monitors (`hyprctl monitors -j | jq -r '.[].name'`), one bar block each;
   - the absolute `include` path (`/home/<you>/.config/waybar/shared.jsonc`).
4. `omarchy restart waybar` (or `pkill waybar; waybar &`).

> `omarchy refresh waybar` resets `config.jsonc` back to the stock single-bar config — re-apply this
> template if you ever run it.
