"""Desktop menus and SSH commands for the same task lifecycle."""

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from core import Manager, OpenCode, Settings, Store, TaskError, owns_checkout, require_checkout, task_directory, task_environment, task_name
from desktop import Desktop, chromium_profiles, pick, text_input


def main():
    """Dispatch user operations without requiring a graphical session over SSH."""
    parser = argparse.ArgumentParser(description="Manage hyprgrid jj task workspaces")
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list", help="List tasks (including archived tasks)")
    listing.add_argument("--json", action="store_true")
    commands.add_parser("repos", help="List discovered jj repositories")
    commands.add_parser("organize", help="Archive empty desktop-only tasks, then close gaps in row order")
    auto_archive = commands.add_parser("archive-empty", help="Archive a desktop task if its row is empty")
    auto_archive.add_argument("task")
    ensure = commands.add_parser("ensure-task", help="Publish metadata for a compositor-assigned task")
    ensure.add_argument("task")
    new = commands.add_parser("new", help="Create and prepare a jj task")
    new.add_argument("--repo")
    new.add_argument("--name", help="Task name; existing copies default to their directory name")
    new.add_argument("--desktop", action="store_true")
    new.add_argument("--existing", action="store_true", help="Use --repo's existing checkout without setup or checkout cleanup")
    promote = commands.add_parser("promote", help="Make an existing desktop row a task without moving its windows")
    promote.add_argument("--repo")
    promote.add_argument("--name", help="Task name; defaults to the working-copy directory name")
    promote.add_argument("--row", choices=list("abcdefghijkl"), help="Existing row letter; defaults to the current row")
    for name in ("attach", "open", "shell", "restore", "archive", "delete", "rename", "snooze", "acknowledge", "set-checkout"):
        command = commands.add_parser(name)
        command.add_argument("task", nargs="?")
        if name in ("attach", "shell"):
            command.add_argument("--active-only", action="store_true", help=argparse.SUPPRESS)
        if name == "restore":
            command.add_argument("--desktop", action="store_true")
        if name == "snooze":
            command.add_argument("--minutes", type=int, default=60)
        if name == "rename":
            command.add_argument("--name")
        if name == "delete":
            command.add_argument("--yes", action="store_true")
        if name == "set-checkout":
            command.add_argument("--repo", required=True)
    menu = commands.add_parser("menu", help="Omarchy-native task actions")
    menu.add_argument("action", choices=["new", "switch", "snooze", "archive", "restore", "actions", "rename", "browser"])
    menu.add_argument("--task")
    menu.add_argument("--window", help=argparse.SUPPRESS)
    watch = commands.add_parser("watch", help="Publish OpenCode activity for the bar and pickers")
    watch.add_argument("--once", action="store_true")
    args = parser.parse_args()
    store = Store()
    settings = Settings()
    launcher = Path(__file__).resolve().parent / "hyprgrid-task"
    if not launcher.is_file():
        launcher = Path(__file__).resolve().parents[2] / "bin/hyprgrid-task"
    executable = str(launcher)
    desktop = Desktop(store, executable) if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") else None
    manager = Manager(store, settings, desktop=desktop)
    try:
        if args.command == "watch":
            watch_tasks(store, manager.agent, args.once)
        elif args.command == "organize":
            with store.lock():
                manager.organize()
        elif args.command == "ensure-task":
            with store.lock():
                # A fast archive/delete can release the row before this queued prefix runs.
                if args.task in store.rows():
                    manager.ensure_task(args.task)
        elif args.command == "repos":
            print("\n".join(map(str, settings.repositories())))
        elif args.command == "list":
            if args.json:
                print(json.dumps({"tasks": store.read(), "rows": store.rows()}, indent=2))
            else:
                for key, label, subtitle in task_choices(store):
                    print(f"{key}\t{label}\t{subtitle}")
        elif args.command == "menu":
            if not desktop:
                raise TaskError("Desktop menus require a Hyprland session; use attach over SSH")
            desktop_menu(manager, args.action, args.task, window=args.window)
        elif args.command in ("new", "promote"):
            promoting = args.command == "promote"
            if promoting and not desktop:
                raise TaskError("Promotion requires a Hyprland desktop session")
            window = desktop.promotion_window(args.row) if promoting else None
            existing = promoting or args.existing
            on_desktop = promoting or args.desktop
            repo = args.repo or choose_repo(settings, existing=existing)
            name = args.name
            if repo and not existing and not name:
                name = text_input("Task name")
            if repo and (existing or name):
                if on_desktop and not desktop:
                    raise TaskError("--desktop requires a Hyprland session")
                with store.lock():
                    task = manager.create(repo, name, on_desktop, existing=existing, adopt_window=window)
                    if on_desktop and not promoting:
                        desktop.open(task)
                if promoting or not on_desktop:
                    print(task["id"])
        else:
            task_id = args.task or choose_task(store, archived=args.command == "restore")
            if task_id:
                execute_action(manager, args.command, task_id, args)
    except (TaskError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"hyprgrid-task: {error}", file=sys.stderr)
        if args.command in ("menu", "archive-empty", "ensure-task", "organize"):
            notify("Task operation failed", str(error))
        return 1
    except (KeyboardInterrupt, EOFError):
        return 130
    return 0


def execute_action(manager, action, task_id, args):
    """Lock mutations, but release the lock before attaching an interactive client."""
    store = manager.store
    with store.lock():
        # A queued close event can arrive after an explicit delete completed.
        if action == "archive-empty" and task_id not in store.read() and task_id not in store.rows():
            return
        task = manager.ensure_task(task_id)
        if action == "archive-empty":
            manager.archive_if_empty(task)
            return
        if action == "acknowledge":
            task["acknowledged"] = time.time() * 1000
            if task.get("activity") == "ready":
                task["activity"] = "idle"
            store.save(task)
            return
        if action in ("attach", "shell", "open"):
            if action != "shell":
                require_checkout(task)
            if task["state"] != "active":
                if getattr(args, "active_only", False):
                    raise TaskError("Task is no longer active")
                manager.restore(task)
            if action == "open":
                if not manager.desktop:
                    raise TaskError("Use attach to open a task in this SSH terminal")
                manager.desktop.open(task)
                return
            if action != "shell":
                manager.agent.ensure_session(task, store)
        elif action == "restore":
            if args.desktop and not manager.desktop:
                raise TaskError("--desktop requires a Hyprland session")
            manager.restore(task, args.desktop)
            if args.desktop:
                manager.desktop.open(task, shell=not task.get("path"))
            return
        elif action == "archive":
            # The command may be running in a terminal that this archive will close.
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            manager.archive(task)
            return
        elif action == "delete":
            target = f'task {task["name"]}'
            if task.get("path"):
                target = f'{task["name"]} and {task["path"]}' if owns_checkout(task) else f'task {task["name"]} (keep {task["path"]})'
            if not args.yes and input(f'Delete {target}? [y/N] ').lower() != "y":
                return
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            manager.delete(task)
            return
        elif action == "rename":
            name = args.name or text_input("Task name")
            if name:
                task["name"] = task_name(name)
                store.save(task)
            return
        elif action == "set-checkout":
            manager.attach_checkout(task, args.repo)
            return
        elif action == "snooze":
            if args.minutes < 0:
                raise TaskError("Snooze duration cannot be negative")
            task["snoozed_until"] = time.time() + args.minutes * 60 if args.minutes else 0
            store.save(task)
            return
    # Same explicit session on desktop and SSH. No --standalone and no last-session guessing.
    os.chdir(task_directory(task))
    env = task_environment(task)
    command = [os.environ.get("SHELL", "/bin/bash")] if action == "shell" else ["opencode", "--session", task["session"], task["path"]]
    os.execvpe(command[0], command, env)


def desktop_menu(manager, action, task_id, window=None):
    """Gather input before locking so an abandoned menu never blocks other operations."""
    store = manager.store
    if task_id:
        with store.lock():
            manager.ensure_task(task_id)
    if action == "actions" and not task_id:
        window = window or manager.desktop.promotion_window()
        repo = choose_repo(manager.settings, graphical=True, existing=True)
        if repo:
            with store.lock():
                manager.create(repo, desktop=True, existing=True, adopt_window=window)
        return
    if action == "browser":
        profile = pick("New browser window", chromium_profiles(), graphical=True)
        if profile is not None:
            with store.lock():
                task = store.get(task_id) if task_id else None
                manager.desktop.open_browser(profile, task)
        return
    if action == "new":
        mode = pick("Task checkout", [
            ("existing", "Existing working copy", "Use current work; leave checkout and services alone"),
            ("dedicated", "New jj workspace", "Isolated checkout from trunk; run setup and teardown"),
        ], graphical=True)
        if not mode:
            return
        repo = choose_repo(manager.settings, graphical=True, existing=mode == "existing")
        if not repo:
            return
        name = None if mode == "existing" else text_input("Task name", graphical=True)
        if mode != "existing" and not name:
            return
        with store.lock():
            task = manager.create(repo, name, desktop=True, existing=mode == "existing")
            manager.desktop.open(task)
        return
    if action == "switch":
        choices = task_choices(store, archived=False) + manager.desktop.unmanaged_choices()
        task_id = pick("Tasks", choices, graphical=True)
        if task_id and task_id.startswith("window:"):
            manager.desktop.jump_window_row(task_id.removeprefix("window:"))
            return
    elif action == "restore":
        task_id = choose_task(store, graphical=True, archived=True)
    if not task_id:
        if action not in ("switch", "restore"):
            raise TaskError("The current row is not a managed task")
        return
    task = store.get(task_id)
    delete_label = "Delete task"
    if owns_checkout(task):
        delete_label = "Delete task and workspace"
    elif task.get("path"):
        delete_label = "Delete task (keep working copy)"
    if action == "actions":
        choices = [(name, label, "") for name, label in (
            ("shell", "New terminal"), ("browser", "New browser window"), ("rename", "Rename"),
            ("snooze", "Snooze"), ("archive", "Archive"), ("delete", delete_label))]
        if task.get("path"):
            choices = [("open", "Open agent", ""), ("zed", "Zed", "")] + choices
        else:
            choices.insert(0, ("set-checkout", "Attach working copy", "Optional; used for agent and editor launches"))
        action = pick(task["name"], choices, graphical=True)
        if not action:
            return
        if action == "browser":
            desktop_menu(manager, action, task_id)
            return
    value = None
    if action == "snooze":
        value = pick("Snooze", [("15", "15 minutes", ""), ("60", "1 hour", ""),
                                ("1440", "24 hours", ""), ("0", "Unsnooze", "")], graphical=True)
        if value is None:
            return
    elif action == "rename":
        value = text_input("Task name", graphical=True)
        if not value:
            return
    elif action == "delete":
        if pick(delete_label + "?", [("no", "Cancel", ""),
                ("yes", f'Delete {task["name"]}', task.get("path") or "")], graphical=True) != "yes":
            return
    elif action == "set-checkout":
        value = choose_repo(manager.settings, graphical=True, existing=True)
        if not value:
            return
    with store.lock():
        task = store.get(task_id)
        if action == "restore":
            manager.restore(task, desktop=True)
            manager.desktop.open(task, shell=not task.get("path"))
        elif action == "switch":
            manager.desktop.reserve(task)
            manager.desktop.jump(task)
            task["acknowledged"] = time.time() * 1000
            store.save(task)
        elif action in ("open", "shell"):
            if task["state"] != "active":
                manager.restore(task, desktop=True)
            manager.desktop.open(task, shell=action == "shell")
        elif action == "archive":
            manager.archive(task)
        elif action == "delete":
            manager.delete(task)
        elif action == "zed":
            manager.desktop.open_zed(task)
        elif action == "set-checkout":
            manager.attach_checkout(task, value)
        elif action == "rename":
            task["name"] = task_name(value)
            store.save(task)
        elif action == "snooze":
            task["snoozed_until"] = time.time() + int(value) * 60 if int(value) else 0
            store.save(task)


def task_choices(store, archived=None):
    """Keep stable IDs in picker subtext; duplicate task titles remain selectable."""
    rows = store.rows()
    tasks = sorted(store.read().values(), key=lambda task: (rows.get(task["id"], 99), task["created"]))
    result = []
    for task in tasks:
        if archived is not None and (task["state"] == "archived") != archived:
            continue
        row = rows.get(task["id"])
        location = chr(ord("a") + row - 2) if row else "headless"
        status = task["state"] if task["state"] != "active" else task.get("activity", "unknown")
        if task.get("snoozed_until", 0) > time.time():
            status += " · snoozed"
        checkout = "no working copy"
        if task.get("path"):
            checkout = task["path"] if task.get("checkout_mode") == "existing" else Path(task["repo"]).name
        subtitle = f'{location} · {checkout} · {status} · {task["id"]}'
        result.append((task["id"], task["name"], subtitle))
    return result


def choose_task(store, graphical=False, archived=False):
    """Choose a task through the appropriate UI for this connection."""
    return pick("Archived tasks" if archived else "Tasks", task_choices(store, archived), graphical)


def choose_repo(settings, graphical=False, existing=False):
    """Refresh shallow discovery on each invocation."""
    paths = settings.working_copies() if existing else settings.repositories()
    return pick("Working copy" if existing else "Repository",
                [(str(path), path.name, str(path.parent)) for path in paths], graphical)


def watch_tasks(store, agent, once=False):
    """Refresh semantic activity without holding the lifecycle lock across API requests.

    The bar reads snapshots and suppresses managed native urgency while snoozed.
    Failed API reads become unknown, never a spurious completed-task signal.
    """
    while True:
        snapshot = store.read()
        sessions = [task for task in snapshot.values() if task["state"] == "active" and task.get("session")]
        updates = {}
        try:
            active = agent.api("get", "/api/session/active")["data"] if sessions else {}
            for task in sessions:
                try:
                    updates[task["id"]] = agent.status(task, active)
                except (TaskError, OSError, ValueError, KeyError, subprocess.SubprocessError):
                    updates[task["id"]] = "unknown"
        except (TaskError, OSError, ValueError, KeyError, subprocess.SubprocessError):
            updates = {task["id"]: "unknown" for task in sessions}
        with store.lock():
            for key, status in updates.items():
                current = store.read().get(key)
                if (current and current["state"] == "active"
                        and current.get("session") == snapshot[key].get("session")
                        and current.get("acknowledged") == snapshot[key].get("acknowledged")):
                    if current.get("activity") != status:
                        current["activity"] = status
                        store.save(current)
        if once:
            return
        time.sleep(3)


def notify(title, body):
    """Surface failed background operations through the desktop notifier."""
    subprocess.run(["notify-send", "--app-name=hyprgrid", "--", title, body], check=False)


if __name__ == "__main__":
    sys.exit(main())
