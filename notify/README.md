# Agent attention alerts

When a coding agent (Claude Code or OpenCode) finishes a turn or needs input, this makes the
**workspace it's on pulse in the Omarchy bar or Waybar** — as long as that window is unfocused. It's the classic X11 "urgent"
workflow, rebuilt for Wayland/Hyprland, so juggling many agents across the grid you can tell at a glance
which task wants you.

## How it works

Agent finishes → rings its terminal's bell → an **unfocused** Alacritty (Wayland) turns the bell into an
xdg-activation "attention" request → Hyprland (with `misc:focus_on_activate = false`) marks that
**workspace urgent** instead of stealing focus → the Omarchy workspace widget or Waybar highlights it.
Focusing the workspace clears it.

OpenCode V2's bell runs in the TUI, not its terminal-less background service. It listens for
`permission.asked`, `form.created`, `session.execution.failed`, and `session.execution.succeeded`.
Only the current session family or a session in an open terminal tab can ring that terminal.

It only fires when the window is **unfocused**, so it never nags while you're looking at it.

## Prerequisites

- **Alacritty** (Wayland urgency on bell, ≥ 0.13) — or another terminal that requests attention on bell.
- **Hyprland** with `misc:focus_on_activate = false` (the default) — marks urgent instead of focusing.
- The Omarchy `hyprgrid.workspaces` widget, or a Waybar `hyprland/workspaces` module.

## Files

| File | Installs to | Purpose |
|---|---|---|
| `hypr-agent-bell` | `~/.local/bin/hypr-agent-bell` | Rings the controlling terminal's bell (the shared trigger). |
| `opencode/hypr-agent-bell/index.js` | `~/.config/opencode/plugins/hypr-agent-bell/index.js` | OpenCode V2 server entrypoint; discovers the adjacent TUI part. |
| `opencode/hypr-agent-bell/tui.js` | `~/.config/opencode/plugins/hypr-agent-bell/tui.js` | OpenCode V2 terminal-local attention bell. |
| `hypr-agent-bell.js` | `~/.config/opencode/plugins/hypr-agent-bell.js` | Optional legacy OpenCode V1 `session.idle` plugin; do not install alongside V2. |
| `urgent.css` | paste into `~/.config/waybar/style.css` | Styles the urgent workspace (a pulsing underline). |
| `claude-hooks.json` | merge into `~/.claude/settings.json` | Claude Code `Stop` + `Notification` hooks that run the bell. |

## Install

1. **Bell script:**
   ```sh
   cp notify/hypr-agent-bell ~/.local/bin/ && chmod +x ~/.local/bin/hypr-agent-bell
   ```
2. **Claude Code:** merge the `hooks` block from `claude-hooks.json` into `~/.claude/settings.json` (keep
   your other settings). Open `/hooks` once, or restart, so a running session picks them up.
3. **OpenCode V2:** back up differing installed files before updating:
    ```sh
    mkdir -p ~/.config/opencode/plugins/hypr-agent-bell
    cp notify/opencode/hypr-agent-bell/index.js notify/opencode/hypr-agent-bell/tui.js \
      ~/.config/opencode/plugins/hypr-agent-bell/
    ```
    Move an existing legacy `~/.config/opencode/plugins/hypr-agent-bell.js` out of the plugins directory
    before enabling V2; keep a backup outside that directory. OpenCode watches plugin changes;
    `/reload` forces a reload.
4. **Waybar only:** paste `urgent.css` into `~/.config/waybar/style.css`. With `"reload_style_on_change": true`
    the bar restyles live; otherwise `omarchy restart waybar`.
    Omarchy's workspace widget already handles urgent workspaces.

For OpenCode V1 only, install `notify/hypr-agent-bell.js` instead of the V2 directory.

## Test

```sh
node --test tests/agent_bell.test.js
```

These tests execute the TUI plugin logic with an in-memory event source and terminal writer.
They cover session filtering, open tabs, cleanup, and unavailable terminals, not OpenCode discovery
or real terminal urgency.

## Notes

- Claude Code `Stop` = "done responding"; `Notification` = permission prompts / waiting for input. Both are
  "the agent needs you."
- The legacy OpenCode V1 plugin uses its generic `event` hook filtered to `session.idle`; the V2 plugin
  uses typed TUI events. The plugin directory is `plugins/` (plural).
- The bell reaches the terminal via its controlling tty (`/dev/tty`); the opencode plugin writes `BEL`
  there directly, the shell script does the same with a parent-tty fallback.
- `urgent.css` uses `@foreground`, so it matches any theme — tweak the color, thickness, or speed to taste.
