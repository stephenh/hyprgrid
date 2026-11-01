"""Desktop menus and SSH commands for the same task lifecycle."""

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from core import Manager, OpenCode, Settings, Store, TaskError, task_environment, task_name
from desktop import Desktop, pick, text_input


def main():
    """Dispatch user operations without requiring a graphical session over SSH."""
    parser = argparse.ArgumentParser(description="Manage hyprgrid jj task workspaces")
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list", help="List tasks (including archived tasks)")
    listing.add_argument("--json", action="store_true")
    commands.add_parser("repos", help="List discovered jj repositories")
    auto_archive = commands.add_parser("archive-empty", help="Archive a desktop task if its row is empty")
    auto_archive.add_argument("task")
    new = commands.add_parser("new", help="Create and prepare a jj task")
    new.add_argument("--repo")
    new.add_argument("--name")
    new.add_argument("--desktop", action="store_true")
    for name in ("attach", "open", "shell", "restore", "archive", "delete", "rename", "snooze", "acknowledge"):
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
    menu = commands.add_parser("menu", help="Omarchy-native task actions")
    menu.add_argument("action", choices=["new", "switch", "snooze", "archive", "restore", "actions", "rename"])
    menu.add_argument("--task")
    watch = commands.add_parser("watch", help="Publish OpenCode activity for the bar and pickers")
    watch.add_argument("--once", action="store_true")
    args = parser.parse_args()
    store = Store()
    settings = Settings()
    executable = str(Path(__file__).resolve().parent / "hyprgrid-task")
    desktop = Desktop(store, executable) if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") else None
    manager = Manager(store, settings, desktop=desktop)
    try:
        if args.command == "watch":
            watch_tasks(store, manager.agent, args.once)
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
            desktop_menu(manager, args.action, args.task)
        elif args.command == "new":
            repo = args.repo or choose_repo(settings)
            name = args.name or (text_input("Task name") if repo else None)
            if repo and name:
                if args.desktop and not desktop:
                    raise TaskError("--desktop requires a Hyprland session")
                with store.lock():
                    task = manager.create(repo, name, args.desktop)
                    if args.desktop:
                        desktop.open(task)
                if not args.desktop:
                    print(task["id"])
        else:
            task_id = args.task or choose_task(store, archived=args.command == "restore")
            if task_id:
                execute_action(manager, args.command, task_id, args)
    except (TaskError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"hyprgrid-task: {error}", file=sys.stderr)
        if args.command in ("menu", "archive-empty"):
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
        if action == "archive-empty" and task_id not in store.read():
            return
        task = store.get(task_id)
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
            if task["state"] != "active":
                if getattr(args, "active_only", False):
                    raise TaskError("Task is no longer active")
                manager.restore(task)
            if action == "open":
                if not manager.desktop:
                    raise TaskError("Use attach to open a task in this SSH terminal")
                manager.desktop.open(task)
                return
            manager.agent.ensure_session(task, store)
        elif action == "restore":
            if args.desktop and not manager.desktop:
                raise TaskError("--desktop requires a Hyprland session")
            manager.restore(task, args.desktop)
            if args.desktop:
                manager.desktop.open(task)
            return
        elif action == "archive":
            # The command may be running in a terminal that this archive will close.
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            manager.archive(task)
            return
        elif action == "delete":
            if not args.yes and input(f'Delete {task["name"]} and {task["path"]}? [y/N] ').lower() != "y":
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
        elif action == "snooze":
            if args.minutes < 0:
                raise TaskError("Snooze duration cannot be negative")
            task["snoozed_until"] = time.time() + args.minutes * 60 if args.minutes else 0
            store.save(task)
            return
    # Same explicit session on desktop and SSH. No --standalone and no last-session guessing.
    os.chdir(task["path"])
    env = task_environment(task)
    command = [os.environ.get("SHELL", "/bin/bash")] if action == "shell" else ["opencode", "--session", task["session"], task["path"]]
    os.execvpe(command[0], command, env)


def desktop_menu(manager, action, task_id):
    """Gather input before locking so an abandoned menu never blocks other operations."""
    store = manager.store
    if action == "new":
        repo = choose_repo(manager.settings, graphical=True)
        name = text_input("Task name", graphical=True) if repo else None
        if not name:
            return
        with store.lock():
            task = manager.create(repo, name, desktop=True)
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
    if action == "actions":
        choices = [(name, label, "") for name, label in (
            ("open", "Open agent"), ("shell", "New terminal"), ("rename", "Rename"),
            ("snooze", "Snooze"), ("archive", "Archive"), ("delete", "Delete task and workspace"))]
        action = pick(task["name"], choices, graphical=True)
        if not action:
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
        if pick("Delete task and checkout?", [("no", "Cancel", ""),
                ("yes", f'Delete {task["name"]}', task["path"])], graphical=True) != "yes":
            return
    with store.lock():
        task = store.get(task_id)
        if action == "restore":
            manager.restore(task, desktop=True)
            manager.desktop.open(task)
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
        subtitle = f'{location} · {Path(task["repo"]).name} · {status} · {task["id"]}'
        result.append((task["id"], task["name"], subtitle))
    return result


def choose_task(store, graphical=False, archived=False):
    """Choose a task through the appropriate UI for this connection."""
    return pick("Archived tasks" if archived else "Tasks", task_choices(store, archived), graphical)


def choose_repo(settings, graphical=False):
    """Refresh shallow discovery on each invocation."""
    return pick("Repository", [(str(path), path.name, str(path.parent))
                               for path in settings.repositories()], graphical)


def watch_tasks(store, agent, once=False):
    """Refresh semantic activity without holding the lifecycle lock across API requests.

    The bar reads snapshots and suppresses managed native urgency while snoozed.
    Failed API reads become unknown, never a spurious completed-task signal.
    """
    while True:
        snapshot = store.read()
        updates = {}
        try:
            active = agent.api("get", "/api/session/active")["data"] if snapshot else {}
            for task in snapshot.values():
                if task["state"] == "active":
                    try:
                        updates[task["id"]] = agent.status(task, active)
                    except (TaskError, OSError, ValueError, KeyError, subprocess.SubprocessError):
                        updates[task["id"]] = "unknown"
        except (TaskError, OSError, ValueError, KeyError, subprocess.SubprocessError):
            updates = {key: "unknown" for key, task in snapshot.items() if task["state"] == "active"}
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
