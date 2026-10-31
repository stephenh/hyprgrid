# Task workspaces

`hyprgrid-task` is the shared CLI behind desktop menus and SSH access. It needs
Python 3, jj, and OpenCode V2. Desktop features additionally use Omarchy's menus,
`xdg-terminal-exec`, and the Lua grid adapter. No tmux or Herdr is required.

## Install

Run the tests first, from this repository:

```sh
lua run.lua
python -m unittest discover -s tests -p 'test_*.py'
node --test tests/workspaces.test.js
```

Put `tasks/hyprgrid-task` on PATH (a symlink into this checkout works; the launcher
resolves its adjacent Python files). Create `~/.local/state/hyprgrid/` and an empty
`rows.tsv` there before enabling the desktop adapter. Running `hyprgrid-task list`
initializes `tasks.json`.

Deploy `workspace-grid.lua` and `task-workspaces.lua` to `~/.config/hypr/`, following
the diff/backup workflow in [CLAUDE.md](../CLAUDE.md). Immediately after loading the
grid in `~/.config/hypr/hyprland.lua`, add:

```lua
require("hypr.workspace-grid")
require("hypr.task-workspaces")()
```

Reload Hyprland and check `hyprctl configerrors`. This replaces `Super+T` (OpenWhispr
tap-to-dictate) with the task prefix. Do not drive workspace-move tests on the live
desktop; the user performs those smoke tests.

Deploy the updated `quattro/hyprgrid.workspaces/Workspaces.qml` using the plugin's
diff/backup workflow, then **run `omarchy restart shell`**. The bar reads task names,
activity, and snooze state. A dot after a workspace label means its agent is working.
Managed task attention replaces terminal-bell urgency so snoozing actually suppresses it.

For background activity updates, install `hyprgrid-tasks.service` under
`~/.config/systemd/user/`, then:

```sh
systemctl --user daemon-reload
systemctl --user enable --now hyprgrid-tasks.service
```

The service checks OpenCode activity every three seconds after the previous check
finishes, using the normal authenticated CLI transport. Its PATH supports standard
user binaries and mise shims. Restart it after changing the Python implementation.

## Keyboard

Press and release `Super+T`, then:

| Key | Action |
| --- | --- |
| `a–l` | Jump to that task row, retaining the tool column |
| `Enter` | Active task picker |
| `n` | Choose repo, name the task, prepare it, open OpenCode |
| `s` | Snooze the current task (or unsnooze) |
| `x` | Archive the current task |
| `r` | Restore an archived task and open its agent |
| `Space` | Current-task actions: agent, terminal, rename, snooze, archive, delete |
| `0` | Home row |
| `Escape` | Cancel |

Letter jumps and the desktop task picker also include existing unmanaged rows.
Lifecycle actions apply to tasks created through the manager. Unused letters do not create
rows. Closing the final window across a managed task's whole row auto-archives it:
the agent stops, optional teardown runs, and the slot is released after successful
cleanup. Other windows in the row keep the task active. Setup reservations and
headless tasks are not archived merely for having no windows.
Failed-create and failed-restore tasks also auto-archive on their final window close;
failed archives require an explicit retry.

With the task adapter enabled, all row letters stay fixed, including unmanaged rows.
Archiving `e` leaves `f` at `f`; the next new/restored task claims the first free slot.
The standalone grid without the task adapter retains its original auto-compaction.

`Super+D` renames the managed task for the current row. Its task name is also the
bar's workspace description, so there is no second name to synchronize. On unmanaged
rows and home workspaces, `Super+D` keeps the original workspace-description prompt.
While managed tasks exist, columns 1 (IDE), 2 (terminals), and 3 (browser) participate
even before their first window opens. Other columns join when they have grid windows.
Pass a `columns` map to the Lua adapter to customize the always-participating tools.

## Terminal / SSH

SSH into the desktop as the same user, then:

```sh
hyprgrid-task list
hyprgrid-task attach                 # numbered terminal picker
hyprgrid-task attach <task-id>       # same saved OpenCode conversation
hyprgrid-task new --repo ~/other/hyprgrid --name 'Task picker'
hyprgrid-task restore <task-id>      # setup, no desktop row or window
hyprgrid-task shell <task-id>        # shell with the task's Compose environment
```

Creation prints the task ID in headless mode. `attach` also restores an archived
task when given its ID. The SSH TUI connects to the desktop's shared OpenCode service;
closing the client is not archive. The task manager never stops that shared service.
Interactive disconnect behavior still needs a user smoke test with the installed TUI.

Use `open <id>` or `restore <id> --desktop` locally to show a task on the desktop.
`archive <id>` runs teardown; `delete <id>` also forgets/removes the dedicated jj
workspace, with a confirmation (`--yes` for explicit noninteractive use). Agent
conversation history is retained. `rename <id> --name NAME` and
`snooze <id> --minutes 60` work from either UI; zero minutes clears snooze.

An SSH connection without compositor access can archive headless tasks. Archive a
task that still owns a desktop row from the desktop, where its windows can be closed.

## Repository convention

Repositories are discovered immediately below `~/other` and `~/homebound`. Creation
uses jj's `trunk()` revset (its default-branch convention) at the locally known
revision, not the source checkout's current change. It does not fetch automatically.
If jj cannot resolve one trunk revision, creation fails before making a workspace;
configure the repository's `trunk()` alias/default remote rather than guessing `main`.

Add executable `script/setup` and `script/teardown` to the default branch. Both run
from the task checkout with:

```text
HYPRGRID_TASK_ID=<stable-id>
HYPRGRID_REPO=<source-repository>
HYPRGRID_WORKSPACE=<dedicated-checkout>
COMPOSE_PROJECT_NAME=hyprgrid-<stable-id>
```

For example, a JS repository using Compose might use:

```sh
#!/bin/sh
# script/setup — rerunnable on both create and restore
set -eu
yarn install --immutable
docker compose up -d --wait
# Run this repository's test database migrations/seeding here.
```

```sh
#!/bin/sh
# script/teardown — remove this task's disposable services and volumes
set -eu
docker compose down --volumes --remove-orphans
```

Hooks own repository-specific resource cleanup, including detached processes they
start. Compose must honor project isolation: avoid fixed `container_name`, shared
explicit volume names, and conflicting host ports. External volumes/bind-mounted
files are not removed by Compose down; shared images/caches are deliberately retained.
Manual commands launched via **New terminal** or `hyprgrid-task shell` receive the same
environment. Arbitrary terminals opened outside the manager do not inherit it automatically.

Missing default hooks are silently skipped, including in Compose repositories.
Output from hooks that exist goes to
`~/.local/state/hyprgrid/<task-id>.log`; setup failures retain their checkout and are
retryable through `restore`. Teardown failures keep the row reserved and show
`archive-failed`; fix the hook and retry. Windows receive graceful close requests;
an unsaved editor that remains open prevents archive from completing.

## Optional settings

`~/.config/hyprgrid/tasks.json` can override discovery roots, workspace location, and
hook commands. Commands are argv arrays, not interpolated shell strings:

```json
{
  "repo_roots": ["~/other", "~/homebound"],
  "workspace_root": "~/workspaces",
  "repositories": {
    "/home/stephen/homebound/example": {
      "setup": ["yarn", "setup"],
      "teardown": ["yarn", "teardown"]
    }
  }
}
```

Hook choices are saved at task creation. Names and paths do not change when tasks
are renamed or restored into a different free row. Metadata is atomically stored under
`$XDG_STATE_HOME/hyprgrid` (default `~/.local/state/hyprgrid`); `HYPRGRID_STATE_DIR`
overrides it for isolated testing. The compositor alone writes `rows.tsv`, while the
coordinator serializes lifecycle operations with a lock and publishes `tasks.json`.

No deployment or lifecycle test should operate on real user tasks automatically.
