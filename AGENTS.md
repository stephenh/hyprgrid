# Working on hyprgrid

Read [CLAUDE.md](CLAUDE.md) for the grid development workflow and live-session restrictions.

## Bar plugin changes: verify the running code before diagnosing another bug

The source is `quattro/hyprgrid.workspaces/Workspaces.qml`; the installed copy is
`~/.config/omarchy/plugins/hyprgrid.workspaces/Workspaces.qml`.

- Diff the installed copy against the repo before deploying; preserve unrelated live edits and back up
  the installed file as `Workspaces.qml.bak.<epoch>`.
- Run `node --test tests/workspaces.test.js` for bar event-handler changes. These tests exercise the
  handler, not QML rendering, IPC timing, or whether the running shell loaded the edited file.
- **After deploying QML changes, run `omarchy restart shell` before asking the user to test.**
  File changes and even a “Local plugin changed, reloading” log message do not prove the new code is
  running: Omarchy has reused cached plugin code despite reporting a reload. `hyprctl reload` reloads
  compositor config, not the bar plugin.
- If behavior still disagrees with the code, verify execution with temporary diagnostic output and
  inspect `quickshell log -p /usr/share/omarchy/shell --no-color`. Compare the bar's bound state with
  read-only `hyprctl -j monitors` output before deciding whether state or painting is stale.
- **Do not add timers, retries, or extra event handlers based only on an apparent failed fix.** First
  confirm that the edited code ran, then gather evidence for the proposed cause. Keep the smallest
  verified fix; remove speculative workarounds and temporary diagnostics, then restart the shell again.
- Let the user perform workspace-move smoke tests; do not move their workspaces to reproduce a bug.

### Cross-monitor stale-workspace regression

The verified fix refreshes Quickshell's monitors and workspaces on `moveworkspacev2`,
`changeworkspaceid`, and `workspacev2` on the focused monitor, matching Omarchy's built-in widget.
A 50 ms debounce and an extra `focusedmon` refresh were added while old code was still running.
After a shell restart, the user confirmed the direct refresh works without either workaround.
Do not restore those workarounds without new evidence.
