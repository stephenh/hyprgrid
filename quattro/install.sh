#!/usr/bin/env bash

set -euo pipefail

plugin_id="hyprgrid.workspaces"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_dir="$script_dir/$plugin_id"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
target_dir="$config_home/omarchy/plugins/$plugin_id"
workspace_override="$config_home/default/hypr/monitor-workspaces.lua"

for command_name in omarchy-shell omarchy hyprctl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command_name" >&2
    exit 1
  fi
done

# The widget alone cannot stop Omarchy from translating 7 into 17 on monitor 2.
# Shadow its workspace module before reloading; never edit the packaged copy.
install -d -m 0755 "$(dirname -- "$workspace_override")"
if [[ -e "$workspace_override" ]] && ! cmp -s "$script_dir/default/hypr/monitor-workspaces.lua" "$workspace_override"; then
  cp -p -- "$workspace_override" "$workspace_override.bak.$(date +%s)"
fi
install -m 0644 "$script_dir/default/hypr/monitor-workspaces.lua" "$workspace_override"

hyprctl reload
config_errors="$(hyprctl configerrors)"
if [[ -n "${config_errors//[[:space:]]/}" ]]; then
  printf 'Hyprland configuration errors:\n%s\n' "$config_errors" >&2
  exit 1
fi

install -d -m 0755 "$target_dir"
install -m 0644 "$source_dir/manifest.json" "$source_dir/Workspaces.qml" "$target_dir/"

omarchy-shell shell rescanPlugins
omarchy plugin enable "$plugin_id"
omarchy restart shell

printf 'Installed %s to %s\n' "$plugin_id" "$target_dir"
printf 'Installed global workspace numbering override to %s\n' "$workspace_override"
