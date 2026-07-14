# Agent-done alerts

When a coding agent (Claude Code or opencode) finishes a turn and is ready for feedback, this makes the
**workspace it's on pulse in waybar** — as long as that window is unfocused. It's the classic X11 "urgent"
workflow, rebuilt for Wayland/Hyprland, so juggling many agents across the grid you can tell at a glance
which task wants you.

## How it works

Agent finishes → rings its terminal's bell → an **unfocused** Alacritty (Wayland) turns the bell into an
xdg-activation "attention" request → Hyprland (with `misc:focus_on_activate = false`) marks that
**workspace urgent** instead of stealing focus → waybar styles the urgent workspace button
(`#workspaces button.urgent`). Focusing the workspace clears it.

It only fires when the window is **unfocused**, so it never nags while you're looking at it.

## Prerequisites

- **Alacritty** (Wayland urgency on bell, ≥ 0.13) — or another terminal that requests attention on bell.
- **Hyprland** with `misc:focus_on_activate = false` (the default) — marks urgent instead of focusing.
- A waybar `hyprland/workspaces` module — it adds the `.urgent` class to the button automatically.

## Files

| File | Installs to | Purpose |
|---|---|---|
| `hypr-agent-bell` | `~/.local/bin/hypr-agent-bell` | Rings the controlling terminal's bell (the shared trigger). |
| `hypr-agent-bell.js` | `~/.config/opencode/plugins/hypr-agent-bell.js` | opencode plugin — rings on the `session.idle` event. |
| `urgent.css` | paste into `~/.config/waybar/style.css` | Styles the urgent workspace (a pulsing underline). |
| `claude-hooks.json` | merge into `~/.claude/settings.json` | Claude Code `Stop` + `Notification` hooks that run the bell. |

## Install

1. **Bell script:**
   ```sh
   cp notify/hypr-agent-bell ~/.local/bin/ && chmod +x ~/.local/bin/hypr-agent-bell
   ```
2. **Claude Code:** merge the `hooks` block from `claude-hooks.json` into `~/.claude/settings.json` (keep
   your other settings). Open `/hooks` once, or restart, so a running session picks them up.
3. **opencode:**
   ```sh
   mkdir -p ~/.config/opencode/plugins
   cp notify/hypr-agent-bell.js ~/.config/opencode/plugins/
   ```
   Loads on the next opencode start.
4. **waybar:** paste `urgent.css` into `~/.config/waybar/style.css`. With `"reload_style_on_change": true`
   the bar restyles live; otherwise `omarchy restart waybar`.

## Notes

- Claude Code `Stop` = "done responding"; `Notification` = permission prompts / waiting for input. Both are
  "the agent needs you."
- opencode has no direct `session.idle` hook key — the plugin uses the generic `event` hook filtered to
  `event.type === "session.idle"`. The plugin directory is `plugins/` (plural).
- The bell reaches the terminal via its controlling tty (`/dev/tty`); the opencode plugin writes `BEL`
  there directly, the shell script does the same with a parent-tty fallback.
- `urgent.css` uses `@foreground`, so it matches any theme — tweak the color, thickness, or speed to taste.
