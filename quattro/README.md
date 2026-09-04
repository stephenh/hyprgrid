# Omarchy Quattro workspace widget

Omarchy Quattro replaced Waybar with the Quickshell-based Omarchy shell. Its stock
`omarchy.workspaces` widget only displays numbered workspace IDs `1..10`; Hyprland gives named
workspaces such as `2a` and `3b` negative IDs, so the stock widget omits hyprgrid cells.

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

It installs or updates the plugin under `$XDG_CONFIG_HOME` (or `~/.config` when unset), asks the running shell
to discover and enable it, and restarts the shell.

To install it manually, copy the plugin into the user-owned Omarchy plugin directory:

```sh
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

## Remove

Disabling the plugin restores `omarchy.workspaces` in the same bar position:

```sh
omarchy plugin disable hyprgrid.workspaces
rm -rf ~/.config/omarchy/plugins/hyprgrid.workspaces
omarchy-shell shell rescanPlugins
omarchy restart shell
```

## Task descriptions

The widget watches `${XDG_STATE_HOME:-$HOME/.local/state}/hypr/workspace-descriptions.json`, the same store
managed by `hypr-ws-desc`. Numbered home workspaces use their number as the description key, while grid
workspaces use their shared task tag (`2a` uses `a`). Tag descriptions therefore follow compaction when the
grid remaps the store. See the [Waybar integration](../waybar/README.md) for the description helper and
defaults.
