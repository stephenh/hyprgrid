#!/usr/bin/env bash

set -euo pipefail

plugin_id="hyprgrid.workspaces"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_dir="$script_dir/$plugin_id"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
target_dir="$config_home/omarchy/plugins/$plugin_id"

for command_name in omarchy-shell omarchy; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command_name" >&2
    exit 1
  fi
done

install -d -m 0755 "$target_dir"
install -m 0644 "$source_dir/manifest.json" "$source_dir/Workspaces.qml" "$target_dir/"

omarchy-shell shell rescanPlugins
omarchy plugin enable "$plugin_id"
omarchy restart shell

printf 'Installed %s to %s\n' "$plugin_id" "$target_dir"
