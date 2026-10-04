# Omarchy Quattro workspace widget

Omarchy Quattro replaced Waybar with the Quickshell-based Omarchy shell. Its stock
`omarchy.workspaces` widget displays numbered workspaces, but Hyprland gives named workspaces such as
`2a` and `3b` negative IDs, so the stock widget omits hyprgrid cells.

`hyprgrid.workspaces` replaces that widget and:

- displays the live numbered and hyprgrid workspaces assigned to each bar's monitor, including `2a`, `2b`, and `3b`;
- sorts them by column and task (`2`, `2a`, `2b`, `3`);
- keeps the active workspace name visible and uses the bar's active color;
- shows each monitor's active workspace or task description;
- underlines the active workspace on the focused monitor;
- pulses urgent workspaces until they are focused;
- focuses named workspaces correctly when clicked;
- updates when Hyprland creates, removes, or renames a workspace.

Like Waybar, each bar only shows workspaces that currently exist on its monitor.

## Install

Run the installer from the repository root:

```sh
./quattro/install.sh
```

It installs or updates the plugin and global-numbering override under `$XDG_CONFIG_HOME` (or `~/.config`
when unset), reloads and checks Hyprland, asks the running shell to discover and enable the plugin, and
restarts the shell. A different existing numbering override is backed up as `.bak.<epoch>` before replacement.

Omarchy's Lua bootstrap currently searches `~/.config` for user modules. If you set a different
`XDG_CONFIG_HOME`, make sure your Lua module path also searches that directory for the override.

To install it manually, copy the numbering override and plugin into user-owned config directories:

```sh
mkdir -p ~/.config/default/hypr
# Back up an existing override before replacing it.
test ! -e ~/.config/default/hypr/monitor-workspaces.lua || \
  cp -p ~/.config/default/hypr/monitor-workspaces.lua \
    ~/.config/default/hypr/monitor-workspaces.lua.bak.$(date +%s)
cp quattro/default/hypr/monitor-workspaces.lua ~/.config/default/hypr/
hyprctl reload
hyprctl configerrors # Must be empty before continuing.

mkdir -p ~/.config/omarchy/plugins/hyprgrid.workspaces
cp quattro/hyprgrid.workspaces/manifest.json quattro/hyprgrid.workspaces/Workspaces.qml \
  ~/.config/omarchy/plugins/hyprgrid.workspaces/
```

Ask the running shell to discover and enable it, then restart the shell:

```sh
omarchy-shell shell rescanPlugins
omarchy plugin enable hyprgrid.workspaces
omarchy restart shell
```

The manifest's `clonedFrom: "omarchy.workspaces"` metadata makes Omarchy replace the stock workspace
widget in its current bar position. The explicit restart is important: Quattro can retain the already
instantiated stock widget after a hot plugin rescan.

To update an existing installation, run `./quattro/install.sh` again.

## Global numbering versus Omarchy's per-monitor workspaces

The Omarchy update installed on **2026-10-20** introduced `default.hypr.monitor-workspaces`. It gives each
monitor ten slots backed by different Hyprland IDs: `1..10`, `11..20`, `21..30`, and so on. The stock widget
labels those slots `1..10`, while its move-window bindings translate slot 7 on the second monitor into ID 17.
On reload or hotplug, the module can also renumber existing workspaces into the monitor's block.
This is Omarchy policy implemented in Lua, not a Hyprland flag for independent per-monitor namespaces;
Hyprland's workspace IDs remain global.

hyprgrid uses **global columns**: `7` must mean the same workspace on every monitor. Its `Super+N` override
alone is not enough: the stock `Super+Shift+N` and silent move bindings still use per-monitor slots, and
automatic renumbering remains active. Symptoms include windows unexpectedly appearing on `11`, `14`,
`17`, or `18`, instead of `1`, `4`, `7`, or `8`.

`default/hypr/monitor-workspaces.lua` is a small replacement for that module, not a copy of Omarchy's
implementation. Omarchy's bootstrap searches the user config before its packaged defaults and clears this
module's cache on reload, so installing it at `~/.config/default/hypr/monitor-workspaces.lua` restores global
focus/move actions without registering automatic renumbering handlers. No packaged files are edited.

This **does not limit Hyprland to ten workspaces**. Numbered home columns, named tags such as `2a` and `2b`,
and explicitly requested workspace numbers above ten remain available. The widget shows actual workspace
names rather than hiding the mismatch behind local slot labels.

The installer does **not** move or merge existing windows. If the update already renumbered them, install
the override first, then check each workspace's windows and intended destination before repairing it.
Do not blindly subtract ten: the destination may already exist on another monitor.

## Remove

Disabling the plugin restores `omarchy.workspaces` in the same bar position:

```sh
omarchy plugin disable hyprgrid.workspaces
rm -rf ~/.config/omarchy/plugins/hyprgrid.workspaces
omarchy-shell shell rescanPlugins
omarchy restart shell
```

The numbering override is separate from the widget. Leave it installed if you still use hyprgrid. To
return to Omarchy's per-monitor numbering after removing the grid, remove only the override and reload:

```sh
rm ~/.config/default/hypr/monitor-workspaces.lua
hyprctl reload
hyprctl configerrors
```

That reload can renumber existing workspaces again.

## Task descriptions

The widget watches `${XDG_STATE_HOME:-$HOME/.local/state}/hypr/workspace-descriptions.json`, the same store
managed by `hypr-ws-desc`. Numbered home workspaces use their number as the description key, while grid
workspaces use their shared task tag (`2a` uses `a`). Tag descriptions therefore follow compaction when the
grid remaps the store. See the [Waybar integration](../waybar/README.md) for the description helper and
defaults.
