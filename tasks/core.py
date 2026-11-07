"""Persistent jj tasks, independent of the desktop and its current row labels."""

from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import uuid
from urllib.parse import urlencode


class TaskError(RuntimeError):
    """An operation failed and can be reported directly to the user."""


class Store:
    """Atomically publish state; serialize lifecycle operations across desktop and SSH."""

    def __init__(self, path=None):
        self.path = Path(path or os.environ.get("HYPRGRID_STATE_DIR") or
                         Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "hyprgrid")
        self.path.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.file = self.path / "tasks.json"
        with self.lock():
            if not self.file.exists():
                atomic_json(self.file, {"version": 1, "tasks": {}})

    @contextmanager
    def lock(self):
        """Keep hook execution and task mutation exclusive, without blocking readers."""
        with (self.path / "tasks.lock").open("a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            yield

    def read(self):
        """Read the last complete snapshot, including while a setup hook is running."""
        if not self.file.exists():
            return {}
        payload = json.loads(self.file.read_text())
        if payload.get("version") != 1:
            raise TaskError("Unsupported task registry version")
        return payload["tasks"]

    def save(self, task):
        """Replace one task without overwriting another task's latest state."""
        tasks = self.read()
        tasks[task["id"]] = task
        atomic_json(self.file, {"version": 1, "tasks": tasks})

    def remove(self, task_id):
        """Forget a task only after its resources have been removed."""
        tasks = self.read()
        del tasks[task_id]
        atomic_json(self.file, {"version": 1, "tasks": tasks})

    def get(self, task_id):
        """Resolve an exact stable ID, never a mutable name or row."""
        try:
            return self.read()[task_id]
        except KeyError:
            raise TaskError(f"Unknown task: {task_id}") from None

    def rows(self):
        """Read the compositor-owned assignment snapshot."""
        path = self.path / "rows.tsv"
        if not path.exists():
            return {}
        return {parts[0]: int(parts[1]) for line in path.read_text().splitlines()
                if (parts := line.split("\t")) and len(parts) == 2}


class Settings:
    """Small optional JSON settings; repository commands are argv arrays."""

    def __init__(self, values=None):
        if values is None:
            path = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "hyprgrid/tasks.json"
            values = json.loads(path.read_text()) if path.exists() else {}
        self.roots = [Path(p).expanduser().resolve() for p in values.get("repo_roots", ["~/other", "~/homebound"])]
        self.workspaces = Path(values.get("workspace_root", "~/workspaces")).expanduser().resolve()
        self.repos = values.get("repositories", {})

    def repositories(self):
        """Discover immediate jj children and collapse symlink/workspace aliases."""
        found = {}
        for path in self.working_copies():
            found.setdefault(repo_identity(path), path)
        return list(found.values())

    def working_copies(self):
        """Offer each existing checkout, even when several share one jj repository."""
        found = {}
        for root in self.roots:
            if not root.is_dir():
                continue
            for child in sorted(root.iterdir()):
                if (child / ".jj/repo").exists():
                    path = child.resolve()
                    found.setdefault(path, path)
        return list(found.values())

    def hooks(self, repo):
        """Resolve hook overrides once so later global edits do not change a task's contract."""
        settings = self.repos.get(str(repo), {})
        return {name: command_array(settings.get(name, [f"script/{name}"]))
                for name in ("setup", "teardown")}


class OpenCode:
    """Use V2's authenticated CLI transport to the user's shared service."""

    def api(self, method, path, body=None, cwd=None):
        """Return the API payload, allowing successful no-content responses."""
        command = ["opencode", "api", method, path]
        if body is not None:
            command += ["--data", json.dumps(body)]
        output = run(command, cwd=cwd, timeout=30)
        return json.loads(output) if output.strip() else None

    def ensure_session(self, task, store):
        """Persist identity before setting environment so failed setup can resume safely."""
        if not task.get("session"):
            result = self.api("post", "/api/session", {
                "title": task["name"], "location": {"directory": task["path"]},
            }, cwd=task["path"])
            task["session"] = result["data"]["id"]
            store.save(task)
        # The background daemon does not inherit the launching terminal's environment.
        self.api("put", f'/api/session/{task["session"]}/environment',
                 {"variables": task_environment(task)}, cwd=task["path"])

    def interrupt(self, task):
        """Stop the conversation tree and its daemon-owned processes before teardown."""
        if not task.get("session"):
            return
        family = self.family(task["session"])
        for session in family:
            self.api("post", f"/api/session/{session}/interrupt?resume=false")
        # Detached shell tools and persistent terminals can outlive a session turn.
        # Shell commands are location-scoped, not session-scoped. A borrowed checkout
        # can also contain unrelated sessions, so only dedicated checkouts own these.
        if task.get("checkout_mode") != "existing":
            query = urlencode({"location[directory]": task["path"]})
            for shell in self.api("get", "/api/shell?" + query)["data"]:
                self.api("delete", f'/api/shell/{shell["id"]}?' + query)
        for session in family:
            for terminal in self.api("get", f"/api/experimental/session/{session}/terminal")["data"]:
                self.api("delete", f'/api/experimental/persistent-pty/{terminal["id"]}')
        active = self.api("get", "/api/session/active")["data"]
        if any(session in active for session in family):
            raise TaskError("Agent execution is still stopping; retry archive")

    def family(self, session):
        """Include descendants even if an agent moved a child to another directory."""
        family = [session]
        for parent in family:
            cursor = None
            while True:
                query = {"parentID": parent, "limit": "100"}
                if cursor:
                    query["cursor"] = cursor
                result = self.api("get", "/api/session?" + urlencode(query))
                family.extend(child["id"] for child in result["data"] if child["id"] not in family)
                cursor = result.get("cursor", {}).get("next")
                if not cursor:
                    break
        return family

    def status(self, task, active):
        """Distinguish attention from activity; an inactive session is not task completion."""
        session = task.get("session")
        if not session:
            return "unknown"
        family = self.family(session)
        for member in family:
            permissions = self.api("get", f"/api/session/{member}/permission")["data"]
            forms = self.api("get", f"/api/session/{member}/form")["data"]
            if permissions or forms:
                return "needs-input"
        if any(member in active for member in family):
            return "working"
        info = self.api("get", f"/api/session/{session}")["data"]
        if info.get("outcome") == "failed":
            return "error"
        times = info["time"]
        if times.get("idle", 0) > max(times.get("viewed", 0), task.get("acknowledged", 0)):
            return "ready"
        return "idle"


class Manager:
    """Lifecycle operations; callers hold Store.lock during mutations."""

    def __init__(self, store, settings, agent=None, desktop=None):
        self.store = store
        self.settings = settings
        self.agent = agent or OpenCode()
        self.desktop = desktop

    def create(self, repo, name=None, desktop=False, existing=False, adopt_window=None):
        """Create an isolated working copy or wrap an existing checkout without owning it.

        Publish preparing state first. Failures leave the checkout and diagnostics
        available to retry with restore or remove with delete. Without an explicit
        name, use the selected working copy's directory name.
        """
        if adopt_window and (not existing or not desktop or not self.desktop):
            raise TaskError("Promotion requires an existing working copy and a desktop session")
        repo = Path(repo).expanduser().resolve()
        if not (repo / ".jj/repo").exists():
            raise TaskError(f"Not a jj repository: {repo}")
        name = task_name(repo.name if name is None else name)
        task_id = uuid.uuid4().hex[:12]
        base = None
        path = repo
        if existing:
            for task in self.store.read().values():
                if Path(task["path"]).resolve() == repo:
                    raise TaskError(f'Checkout already belongs to task {task["name"]} ({task["id"]}); open or restore it')
        else:
            base = run(["jj", "--ignore-working-copy", "log", "-r", "trunk()", "--no-graph", "-T", "commit_id"], cwd=repo).strip()
            if not re.fullmatch(r"[0-9a-f]{40,64}", base):
                raise TaskError("trunk() must resolve to one default-branch revision")
            repo_label = repo.name
            if sum(path.name == repo.name for path in self.settings.repositories()) > 1:
                repo_label = f"{repo.parent.name}-{repo.name}"
            self.settings.workspaces.mkdir(parents=True, exist_ok=True)
            path = self.settings.workspaces / f"{slug(repo_label)}-{slug(name)}-{task_id}" / repo.name
        task = {"id": task_id, "name": name, "repo": str(repo), "path": str(path),
                "checkout_mode": "existing" if existing else "dedicated",
                "repo_identity": str(repo_identity(repo)),
                "workspace": None if existing else f"hyprgrid-{task_id}", "base": base, "session": None,
                "state": "preparing", "activity": "unknown", "snoozed_until": 0,
                "created": time.time(), "hooks": {} if existing else self.settings.hooks(repo)}
        self.store.save(task)
        try:
            if desktop:
                if adopt_window:
                    self.desktop.adopt(task, adopt_window)
                else:
                    self.desktop.reserve(task)
            if not existing:
                path.parent.mkdir(parents=True, exist_ok=True)
                run(["jj", "workspace", "add", "--name", task["workspace"], "-r", base, str(path)], cwd=repo)
                task["checkout_created"] = True
                self.store.save(task)
            self.prepare(task)
        except Exception as error:
            self.fail(task, "create", error)
            raise
        return task

    def prepare(self, task):
        """Run repeatable setup and bind the managed OpenCode conversation."""
        task.update(state="preparing", error=None)
        self.store.save(task)
        self.hook(task, "setup")
        self.agent.ensure_session(task, self.store)
        task.update(state="active", activity="idle", error=None)
        self.store.save(task)

    def restore(self, task, desktop=False):
        """Reactivate in place; remote restore never allocates a desktop row."""
        try:
            if desktop:
                self.desktop.reserve(task)
            if not Path(task["path"]).exists():
                if task.get("checkout_created") or task.get("checkout_mode") == "existing":
                    raise TaskError("Task checkout is missing; recover it before restoring this task")
                Path(task["path"]).parent.mkdir(parents=True, exist_ok=True)
                run(["jj", "workspace", "add", "--name", task["workspace"], "-r", task["base"], task["path"]], cwd=task["repo"])
                task["checkout_created"] = True
                self.store.save(task)
            expected_repo = task.get("repo_identity", str(repo_identity(Path(task["repo"]))))
            if str(repo_identity(Path(task["path"]))) != expected_repo:
                raise TaskError("Task checkout no longer belongs to its source repository")
            self.prepare(task)
        except Exception as error:
            self.fail(task, "restore", error)
            raise
        return task

    def archive_if_empty(self, task):
        """Handle a final-window closure after rechecking current lifecycle and desktop state."""
        # Failed setup still owns a row; failed archive needs an explicit retry, not another close event.
        if (task["state"] not in ("active", "create-failed", "restore-failed") or not self.desktop
                or task["id"] not in self.store.rows() or self.desktop.clients(task)):
            return
        # A delayed close event must never close a newly opened window itself.
        self.archive(task, close_windows=False)

    def archive(self, task, close_windows=True):
        """Only report archived after interruption, window closure, and teardown succeed."""
        task.update(state="archiving", error=None)
        self.store.save(task)
        try:
            self.agent.interrupt(task)
            if task["id"] in self.store.rows():
                if not self.desktop:
                    raise TaskError("This task has desktop windows; archive it from the desktop")
                if close_windows:
                    self.desktop.close(task)
            if Path(task["path"]).exists():
                self.hook(task, "teardown")
            if task["id"] in self.store.rows():
                self.desktop.release(task)
            task.update(state="archived", activity="idle", snoozed_until=0, error=None)
            self.store.save(task)
        except Exception as error:
            self.fail(task, "archive", error)
            raise

    def delete(self, task):
        """Remove only a verified dedicated workspace; retain the agent's conversation."""
        if task.get("checkout_mode") == "existing":
            self.archive(task)
            self.store.remove(task["id"])
            return
        path = Path(task["path"])
        nested = path.name == Path(task["repo"]).name and path.parent.name.endswith("-" + task["id"])
        if path.is_symlink() or (nested and path.parent.is_symlink()) or not (nested or path.name.endswith("-" + task["id"])):
            raise TaskError("Task checkout path no longer identifies its dedicated workspace")
        if path.exists() and repo_identity(path) != repo_identity(Path(task["repo"])):
            raise TaskError("Task checkout belongs to a different repository")
        self.archive(task)
        try:
            # Snapshot the final working copy before forgetting it; jj retains its change.
            if path.exists() and not task.get("workspace_forgotten"):
                run(["jj", "status"], cwd=path)
            names = run(["jj", "workspace", "list", "-T", 'name ++ "\\n"'], cwd=task["repo"]).splitlines()
            if task["workspace"] in names:
                run(["jj", "workspace", "forget", task["workspace"]], cwd=task["repo"])
            task["workspace_forgotten"] = True
            self.store.save(task)
            if path.exists():
                shutil.rmtree(path)
            # Only remove an empty container; files placed beside the checkout belong to the user.
            if nested and path.parent.exists() and not any(path.parent.iterdir()):
                path.parent.rmdir()
            self.store.remove(task["id"])
        except Exception as error:
            self.fail(task, "delete", error)
            raise

    def hook(self, task, name):
        """Log hook output outside the checkout so failures remain inspectable after cleanup."""
        # Existing checkouts keep their own environment, including any running services.
        if task.get("checkout_mode") == "existing":
            return
        command = task["hooks"][name]
        cwd = Path(task["path"])
        if command == [f"script/{name}"] and not (cwd / command[0]).exists():
            # Hooks are opt-in, including for repositories with Compose services.
            return
        log = self.store.path / f'{task["id"]}.log'
        with log.open("a") as output:
            output.write(f"\n[{time.ctime()}] {name}\n")
            output.flush()
            result = subprocess.run(command, cwd=cwd, env=task_environment(task),
                                    stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            raise TaskError(f"{name} failed ({result.returncode}); see {log}")

    def fail(self, task, phase, error):
        """Retain the resources and exact failed phase for retry and inspection."""
        task.update(state=f"{phase}-failed", error=str(error))
        self.store.save(task)


def task_environment(task):
    """Apply task identity to hooks, shells, and the server-side agent environment."""
    environment = {**os.environ, "HYPRGRID_TASK_ID": task["id"], "HYPRGRID_REPO": task["repo"],
                   "HYPRGRID_WORKSPACE": task["path"]}
    if task.get("checkout_mode") != "existing":
        environment["COMPOSE_PROJECT_NAME"] = f'hyprgrid-{task["id"]}'
    return environment


def repo_identity(path):
    """Resolve jj's shared repository pointer without invoking a snapshotting command."""
    marker = Path(path) / ".jj/repo"
    if marker.is_file():
        return (marker.parent / marker.read_text().strip()).resolve()
    return marker.resolve()


def task_name(value):
    """Keep display names single-line so picker results remain unambiguous."""
    value = value.strip()
    if not value or len(value) > 120 or any(ord(char) < 32 for char in value):
        raise TaskError("Task names must be 1–120 characters on one line")
    return value


def slug(value):
    """Keep paths readable without using mutable names as machine identifiers."""
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")[:48] or "task"


def command_array(value):
    """Do not interpret repository config values as interpolated shell commands."""
    if not isinstance(value, list) or not value or not all(isinstance(item, str) and item for item in value):
        raise TaskError("Commands must be nonempty JSON arrays of strings")
    return value


def atomic_json(path, value):
    """Publish complete snapshots to readers without taking their locks."""
    descriptor, name = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".")
    try:
        with os.fdopen(descriptor, "w") as file:
            json.dump(value, file, indent=2)
            file.write("\n")
            file.flush()
            os.fsync(file.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def run(command, cwd=None, timeout=60):
    """Run a bounded subprocess and preserve its useful error output."""
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise TaskError(result.stderr.strip() or result.stdout.strip() or f"{command[0]} failed")
    return result.stdout
