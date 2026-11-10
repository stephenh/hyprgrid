# Task workspaces

## Goal

Make hyprgrid a Hyprland-first task workspace manager. A task owns a whole grid row:
IDE on `1a`, agent and other terminals on `2a`, browser on `3a`, etc. Support 12 active
rows (`a–l`). No agent orchestration, PR tracking, or desktop-session restoration.

## Task identity and storage

- Give each task a stable ID independent of its name and current row. Restoring into
  another row must not change its identity, checkout path, or agent session association.
- Keep row letters fixed while the task adapter is enabled. Archive frees a slot;
  new/restored tasks claim the first available slot without compacting other rows.
- `Super+T → o` explicitly organizes all surviving rows into consecutive letters,
  preserving order, task identity, descriptions, and each monitor's viewed task.
  First archive active desktop-only tasks with no windows, checkout, or agent session.
  Keep their metadata for restore. Tasks with checkouts, sessions, or setup in progress
  retain their reservations; numeric home workspaces do not renumber. Automatic
  compaction stays disabled afterward.
- Record its name, optional source repository and jj workspace name/path, resumable OpenCode
  session reference, optional active row, and attention/snooze state.
- Keep task metadata outside checkouts. Archived tasks remain discoverable without
  open windows or a grid row.
- A task can be just a named desktop row. Entering `Super+T` on an unmanaged grid
  row registers it while entering the submap, without a checkout or agent session.
  Use its saved description or `Task <letter>`; keep all existing windows in place.
- Always use OpenCode as the managed harness. Other agents, such as Claude, can be
  launched manually in ordinary task terminals and need no harness integration.

## Repositories and environments

- Discover jj repositories immediately under `~/other` and `~/homebound` when opening
  the repo picker. Resolve symlinks and deduplicate; show the parent as picker subtext.
- Create jj workspaces under `~/workspaces/<repo>-<task-slug>-<short-id>/`.
  Qualify duplicate repository names with their discovery root.
- Renaming a task or changing its row does not rename its directory.
- Start new jj workspaces from the repository's default branch.
- Alternatively, register an existing working copy under the discovery roots (or an
  explicit CLI path). Use its current change in place; do not create a jj workspace,
  run environment hooks, or override its Compose project. Archive closes the task's
  windows and stops its managed agent, but leaves checkout services alone. Delete
  removes only the task record, never the borrowed directory or jj workspace.
- Existing-working-copy discovery deduplicates resolved paths, not shared jj repositories.
  Each working copy can belong to only one task, including archived tasks.
- An unmanaged desktop row is promoted in place by `Super+T`, including an empty
  active grid cell. Keep every window and the row's letter; do not open another
  terminal or implicitly adopt existing agent conversations. The compositor assigns
  identity before the next key, and the coordinator publishes metadata asynchronously.
- Attach a working copy later through task actions if wanted. Attachment preserves
  the task's name and runs neither setup nor an agent. Agent/editor actions require
  that association; ordinary terminals use home without it. Existing shells and
  editor projects are not reconfigured.
- Tasks created from existing working copies (including explicit `promote --repo`)
  default to the checkout directory's
  name without a naming prompt. Keep that name until an explicit rename; CLI users
  can override it with `--name` at creation.
- Per-repository settings specify dependency/test setup and environment teardown.
- Creation reports preparing, ready, or setup failure. Archive retains dependencies.

### Environment hooks

Archive must remove task-owned Docker Compose containers and disposable volumes,
not merely stop them. Restore reruns setup to recreate services and test data while
reusing installed dependencies. Delete also runs teardown before removing the checkout.

Use `script/setup` and `script/teardown`, with per-repository command overrides for
existing tooling. Setup must be repeatable on create and restore; teardown must
tolerate an already-stopped environment. Run both from the task checkout with its
stable task ID. Set `COMPOSE_PROJECT_NAME=hyprgrid-<task-id>` using a Compose-valid,
unique task ID; keep it unchanged across task renames and restore.
Pass the same value to task agents and terminals so manually invoked Compose
commands address the same project as the lifecycle hooks.
Compose files must honor that isolation, including volume names and host ports.

Typical teardown is `docker compose down --volumes --remove-orphans`. This removes
project containers, networks, and managed volumes, but not external volumes,
bind-mounted files, shared images, or build caches. Repository hooks handle any
additional task-owned resources; do not use global Docker pruning. A failed teardown
leaves cleanup visibly incomplete rather than reporting successful archive/delete.

## Lifecycle

- **Create:** choose existing working copy or new jj workspace → choose repo/checkout →
  use its directory name for an existing copy, or prompt for a new workspace's task name →
  create/prepare only for a new workspace → launch OpenCode. There is no harness picker.
- **Snooze:** suppress task attention until the chosen time; leave work running.
- **Archive:** stop active task execution and shut down its task-owned environment,
  then release the row. Preserve task metadata, checkout, dependencies, and session
  reference. Closing an agent UI alone does not necessarily stop its execution.
- **Last desktop window closed:** auto-archive when no windows remain anywhere in
  the managed row. Recheck after closure under the lifecycle lock. Keep headless tasks
  and setup reservations active; do not infer closure from an initially empty row.
- **Restore:** reuse the checkout, assign a row for desktop use, and optionally resume
  the agent. Do not restore IDEs, arbitrary shells, browser tabs, or window layouts.
- **Delete:** explicitly remove the task and its dedicated jj workspace. Completion
  is user-directed, not inferred from PRs or a stack of PRs.

Track agent activity separately from task lifecycle and snooze. Existing urgency
indicators are an alert surface, not the authoritative task state.

## Desktop UX

Use Omarchy's existing `omarchy menu select` and `omarchy menu input` primitives for
task/repository pickers, naming, snooze durations, and task actions. Add static entry
points to the Omarchy menu if useful. Start with status snapshots in the picker;
a custom live Quickshell overview is optional later.

`Super+T` replaces OpenWhispr tap-to-dictate, promotes the current unmanaged grid row
if necessary, and enters a one-shot task submap. Home/root workspaces are not promoted:

| Next key | Action |
| --- | --- |
| `a–l` | Jump to task row, preserving column; all monitors follow |
| `Enter` | Task picker |
| `n` | New task |
| `o` | Organize and renumber surviving rows |
| `s` | Snooze current task |
| `x` | Archive current task |
| `r` | Archived-task picker / restore |
| `Space` | Current-task actions, including rename and delete |
| `0` | Home row |
| `Escape` | Cancel |

Release `Super+T` before the next key. Exit the submap after an action and before
opening a menu. An unused task letter exits without creating a task. Show a compact
task-mode hint. Keep existing `Super+Ctrl+J/K` cycling and `Super+number` column jumps.

## SSH access

Tasks and checkouts live on the desktop. From a laptop, SSH into the desktop as the
same user and use a terminal-only task list/picker to attach to a task's saved agent
session. This path must not require Omarchy menus or move/focus desktop workspaces.
Use `hyprgrid-task attach` for a terminal picker, or `hyprgrid-task attach <task-id>`
to select a saved session directly.

OpenCode V2's shared background service owns sessions and tool execution; local TUIs
connect as clients. An SSH-launched TUI should use that same desktop service and
the task's explicit session reference, rather than start a new conversation or a
standalone server. No laptop checkout or exposed network service is needed.

Closing/disconnecting the SSH client is not archive and should leave service-owned
work running. Verify session attachment and disconnect behavior with the installed
OpenCode version. Remote use should not allocate a desktop row; an archived task can
be reactivated headlessly. Keep active/archived state separate from row assignment.

OpenCode's existing service means Herdr/tmux is not required for the managed
workflow. Manually launched agents are outside session attachment and restoration.

Reference: <https://opencode.ai/v2/docs/cli>.

## Implementation boundaries and open details

Build a small task coordinator alongside hyprgrid. Keep navigation and placement in
the grid Lua; put metadata, jj operations, environment setup, and harness integration
outside compositor configuration. Desktop menus and terminal commands share the same
task operations.

The implementation and installation guide is in [tasks/README.md](tasks/README.md).
The coordinator uses OpenCode V2's session/environment APIs and native `--session`
attachment. Archive interrupts the session tree and removes its daemon-owned shell
commands and persistent terminals before running repository teardown for dedicated
workspaces. Existing-working-copy tasks skip location-scoped shell cleanup because
those commands may belong to unrelated sessions; session-owned persistent terminals
are still stopped.

Repository-specific work and manual verification:

- Per-repository dependency/test setup and teardown implementations.
- Graceful window closure and interactive SSH disconnect/reattach smoke tests.

Suggested order: stable task identity and row mapping → 12-row navigation and submap
→ native menus → jj/environment creation → agent state and SSH attachment →
snooze/archive/restore/delete. Test grid changes in the existing harness before live
deployment; leave workspace-move smoke tests to the user.
