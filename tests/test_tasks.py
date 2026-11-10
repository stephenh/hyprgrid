"""Exercise lifecycle boundaries with real jj workspaces and real repository hooks."""

import json
from contextlib import redirect_stdout
import ctypes
import ctypes.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tasks"))
from core import Manager, OpenCode, Settings, Store, TaskError, task_environment
from desktop import Desktop, chromium_profiles, lua_string, menu_rows, task_terminal_command, task_terminal_launch, task_app_id
from cli import desktop_menu, execute_action, main, task_choices, watch_tasks


class SessionService:
    """In-memory session resource for lifecycle tests; no terminal or model is started."""

    def __init__(self):
        self.sessions = {}

    def ensure_session(self, task, store):
        if not task.get("session"):
            task["session"] = "ses_" + task["id"]
            store.save(task)
        self.sessions[task["session"]] = {"environment": task_environment(task), "running": True}

    def interrupt(self, task):
        if task.get("session"):
            self.sessions[task["session"]]["running"] = False


class DesktopState:
    """In-memory row windows with the same reservation snapshot as the compositor."""

    def __init__(self, store, task, windows=None):
        self.store = store
        self.windows = windows or []
        (store.path / "rows.tsv").write_text(task["id"] + "\t6\n")

    def clients(self, task):
        """Return surviving windows in this test's task row."""
        return self.windows

    def release(self, task):
        """Keep the same refusal to release an occupied row as the Lua adapter."""
        if self.windows:
            raise TaskError("Task still has open windows")
        (self.store.path / "rows.tsv").write_text("")

    def close(self, task):
        """Model windows accepting their graceful close requests."""
        self.windows.clear()


class ShellService(OpenCode):
    """Keep location-scoped shell state behind the real agent interruption code."""

    def __init__(self):
        self.shells = [{"id": "existing-shell"}]

    def api(self, method, path, body=None, cwd=None):
        """Expose only the API resources used while stopping this test's session."""
        if method == "get" and path.startswith("/api/shell?"):
            return {"data": list(self.shells)}
        if method == "delete" and path.startswith("/api/shell/existing-shell?"):
            self.shells.clear()
            return None
        if method == "get" and (path.startswith("/api/session?") or path.endswith("/terminal") or path == "/api/session/active"):
            return {"data": []}
        if method == "post" and path.endswith("/interrupt?resume=false"):
            return None
        raise AssertionError(f"Unexpected API request: {method} {path}")


class PromotionDesktop:
    """Keep a promoted row in the same coordinator snapshot as the compositor."""

    def __init__(self, store):
        self.store = store

    def adopt(self, task, address):
        """Associate the test's existing row without launching or moving windows."""
        if address != "0x123":
            raise TaskError("Promotion window is missing")
        (self.store.path / "rows.tsv").write_text(task["id"] + "\t4\n")

    def promotion_window(self, letter=None):
        """Resolve the test's existing row before any menu input."""
        if letter != "c":
            raise TaskError("Expected promotion of row c")
        return "0x123"


class TaskLauncher:
    """Keep task-creation menu tests from launching windows or touching the compositor."""

    def open(self, task):
        """No windows are launched by this menu test."""

    def reserve(self, task):
        """No compositor row is allocated by this menu test."""


class OrganizingDesktop:
    """Keep row windows and compositor-owned reservations behind the desktop boundary."""

    def __init__(self, store, windows=None):
        self.store = store
        self.windows = {"late": ["0x123"]} if windows is None else windows
        self.layout_problem = None

    def check_layout(self):
        """Model the read-only preflight that prevents pruning a damaged grid."""
        if self.layout_problem:
            raise TaskError(self.layout_problem)

    def clients(self, task):
        """Return every surviving window belonging to the task's row."""
        return self.windows.get(task["id"], [])

    def release(self, task):
        """Release only empty rows, without changing other tasks' reservations."""
        if self.clients(task):
            raise TaskError("Task still has open windows")
        rows = self.store.rows()
        del rows[task["id"]]
        (self.store.path / "rows.tsv").write_text("".join(f"{task_id}\t{row}\n" for task_id, row in rows.items()))

    def organize(self):
        """Pack the remaining reservations in their original row order."""
        rows = self.store.rows()
        tasks = sorted(rows, key=rows.get)
        (self.store.path / "rows.tsv").write_text("".join(f"{task_id}\t{row}\n" for row, task_id in enumerate(tasks, 2)))


class TaskWorkspacesTest(unittest.TestCase):
    def setUp(self):
        """Create an isolated repo with dependency and disposable-service stand-ins."""
        self.temp = tempfile.TemporaryDirectory(prefix="hyprgrid-test-", dir="/tmp/opencode")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.environment = patch.dict(os.environ, {
            "HOME": str(self.root), "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_STATE_HOME": str(self.root / "xdg-state"),
            "JJ_CONFIG": "", "JJ_USER": "Test", "JJ_EMAIL": "test@example.com",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.repo = self.root / "other/repo"
        (self.repo / "script").mkdir(parents=True)
        setup = self.repo / "script/setup"
        setup.write_text('#!/bin/sh\nset -eu\nmkdir -p node_modules\necho "$COMPOSE_PROJECT_NAME" > service\necho "$HYPRGRID_TASK_ID" > task-id\n')
        setup.chmod(0o755)
        teardown = self.repo / "script/teardown"
        teardown.write_text('#!/bin/sh\nset -eu\nrm -f service\n')
        teardown.chmod(0o755)
        self.command("git", "init", "-b", "main")
        self.command("git", "add", ".")
        self.command("git", "commit", "-m", "Initial")
        self.command("jj", "git", "init", "--colocate")
        self.command("jj", "config", "set", "--repo", 'revset-aliases."trunk()"', "main")
        self.store = Store(self.root / "state")
        self.settings = Settings({"repo_roots": [str(self.root / "other"), str(self.root / "homebound")],
                                  "workspace_root": str(self.root / "workspaces")})
        self.agent = SessionService()
        self.manager = Manager(self.store, self.settings, agent=self.agent)

    def command(self, *args, cwd=None):
        """Run the real VCS against this test's repository only."""
        result = subprocess.run(args, cwd=cwd or self.repo, capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout.strip()

    def test_creation_uses_default_branch_not_source_working_copy(self):
        # Given an uncommitted file in the source checkout.
        (self.repo / "source-only").write_text("unfinished")
        # When creating an isolated task.
        task = self.manager.create(self.repo, "Invoice rounding")
        # Then the source-only change is absent from the new workspace.
        self.assertFalse((Path(task["path"]) / "source-only").exists())

    def test_setup_receives_stable_compose_identity(self):
        # Given a repository whose setup records its Compose project.
        # When creating a task.
        task = self.manager.create(self.repo, "Invoice rounding")
        # Then setup uses the stable task ID.
        self.assertEqual((Path(task["path"]) / "service").read_text().strip(), "hyprgrid-" + task["id"])

    def test_archive_removes_services(self):
        # Given a running task environment.
        task = self.manager.create(self.repo, "Invoice rounding")
        # When archiving it.
        self.manager.archive(task)
        # Then teardown removes its disposable service state.
        self.assertFalse((Path(task["path"]) / "service").exists())

    def test_archive_retains_dependencies(self):
        # Given installed dependencies in a task.
        task = self.manager.create(self.repo, "Invoice rounding")
        # When archiving it.
        self.manager.archive(task)
        # Then its dependencies remain for restore.
        self.assertTrue((Path(task["path"]) / "node_modules").is_dir())

    def test_restore_reuses_agent_conversation(self):
        # Given an archived task with a saved conversation.
        task = self.manager.create(self.repo, "Invoice rounding")
        session = task["session"]
        self.manager.archive(task)
        # When restoring it headlessly.
        self.manager.restore(self.store.get(task["id"]))
        # Then the conversation identity is unchanged.
        self.assertEqual(self.store.get(task["id"])["session"], session)

    def test_restore_recreates_services(self):
        # Given an archived task whose disposable service state was removed.
        task = self.manager.create(self.repo, "Invoice rounding")
        self.manager.archive(task)
        # When restoring it.
        self.manager.restore(task)
        # Then setup recreates the service under the same project name.
        self.assertEqual((Path(task["path"]) / "service").read_text().strip(), "hyprgrid-" + task["id"])

    def test_failed_teardown_is_not_reported_as_archived(self):
        # Given a task whose teardown cannot finish.
        task = self.manager.create(self.repo, "Invoice rounding")
        (Path(task["path"]) / "script/teardown").write_text("#!/bin/sh\nexit 7\n")
        # When archiving it.
        try:
            self.manager.archive(task)
        except TaskError:
            pass
        # Then the task retains a visible failure state.
        self.assertEqual(self.store.get(task["id"])["state"], "archive-failed")

    def test_delete_forgets_only_the_dedicated_workspace(self):
        # Given a managed jj workspace alongside the original checkout.
        task = self.manager.create(self.repo, "Invoice rounding")
        # When deleting the task.
        self.manager.delete(task)
        # Then jj retains only the original workspace.
        self.assertEqual(self.command("jj", "workspace", "list", "-T", 'name ++ "\\n"'), "default")

    def test_duplicate_names_have_distinct_checkout_paths(self):
        # Given an existing task.
        first = self.manager.create(self.repo, "Same name")
        # When creating another with the same display name.
        second = self.manager.create(self.repo, "Same name")
        # Then their checkouts do not collide.
        self.assertNotEqual(first["path"], second["path"])

    def test_repository_discovery_deduplicates_symlinks(self):
        # Given two paths to the same repository.
        (self.root / "other/alias").symlink_to(self.repo)
        # When discovering repositories.
        repositories = self.settings.repositories()
        # Then it is offered once.
        self.assertEqual(repositories, [self.repo])

    def test_task_rename_does_not_change_compose_identity(self):
        # Given a task with a Compose project.
        task = self.manager.create(self.repo, "Original")
        project = task_environment(task)["COMPOSE_PROJECT_NAME"]
        # When its display name changes.
        task["name"] = "Renamed"
        # Then the Compose project is unchanged.
        self.assertEqual(task_environment(task)["COMPOSE_PROJECT_NAME"], project)

    def test_lua_arguments_are_data_even_with_quotes_and_unicode(self):
        # Given an arbitrary label containing Lua syntax and non-ASCII text.
        value = '"; error("bad"); -- café'
        # When round-tripping through the actual Lua parser.
        result = subprocess.run(["lua", "-e", "io.write(" + lua_string(value) + ")"], capture_output=True, text=True)
        # Then the value is printed literally.
        self.assertEqual(result.stdout, value)

    def test_menu_actions_match_omarchys_label_only_result(self):
        # Given action rows without subtitles.
        choices = [("snooze", "Snooze", ""), ("archive", "Archive", "")]
        # When preparing the native picker's result lookup.
        rows = menu_rows(choices)
        # Then its label-only return value resolves to the action.
        self.assertEqual(rows.get("Snooze"), "snooze")

    def test_restore_skips_missing_setup_in_compose_repository(self):
        # Given an archived task.
        task = self.manager.create(self.repo, "Optional setup")
        self.manager.archive(task)
        # And a Compose checkout without the optional setup hook.
        checkout = Path(task["path"])
        (checkout / "compose.yaml").write_text("services: {}\n")
        (checkout / "script/setup").unlink()
        # When restoring the task.
        self.manager.restore(task)
        # Then it becomes active without requiring setup.
        self.assertEqual(self.store.get(task["id"])["state"], "active")

    def test_archive_skips_missing_teardown_in_compose_repository(self):
        # Given an active task.
        task = self.manager.create(self.repo, "Optional teardown")
        # And a Compose checkout without the optional teardown hook.
        checkout = Path(task["path"])
        (checkout / "compose.yaml").write_text("services: {}\n")
        (checkout / "script/teardown").unlink()
        # When archiving the task.
        self.manager.archive(task)
        # Then it is archived without requiring teardown.
        self.assertEqual(self.store.get(task["id"])["state"], "archived")

    def test_unmanaged_picker_uses_saved_workspace_description(self):
        # Given the description shared with the bar for unmanaged row d.
        path = Path(os.environ["XDG_STATE_HOME"]) / "hypr/workspace-descriptions.json"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({"d": "hyprgrid"}))
        # And a compositor window in that row.
        clients = [{"address": "0x123", "workspace": {"name": "2d"}, "title": "Terminal"}]
        # When the picker projects that compositor snapshot.
        with patch("desktop.run", return_value=json.dumps(clients)):
            choices = Desktop(self.store, "hyprgrid-task").unmanaged_choices()
        # Then it shows the saved name with the row retained in its subtitle.
        self.assertEqual(choices, [("window:0x123", "hyprgrid", "Existing row d · Terminal")])

    def test_auto_archive_releases_an_empty_desktop_task(self):
        # Given an active task whose final desktop window has closed.
        task = self.manager.create(self.repo, "Last window")
        self.manager.desktop = DesktopState(self.store, task)
        # When the deferred closure reaches the coordinator.
        self.manager.archive_if_empty(task)
        # Then the task is archived and its row is available again.
        self.assertEqual(self.store.get(task["id"])["state"], "archived")
        self.assertEqual(self.store.rows(), {})

    def test_auto_archive_rechecks_windows_before_stopping_a_task(self):
        # Given a task with a window opened after its closure event was queued.
        task = self.manager.create(self.repo, "Reopened window")
        self.manager.desktop = DesktopState(self.store, task, [{"address": "0x123"}])
        # When the stale closure reaches the coordinator.
        self.manager.archive_if_empty(task)
        # Then the active task is left alone.
        self.assertEqual(self.store.get(task["id"])["state"], "active")

    def test_auto_archive_leaves_preparing_tasks_alone(self):
        # Given a reserved task still preparing its environment.
        task = self.manager.create(self.repo, "Preparing")
        self.manager.desktop = DesktopState(self.store, task)
        task["state"] = "preparing"
        self.store.save(task)
        # When a closure is reported before setup completes.
        self.manager.archive_if_empty(task)
        # Then the task remains preparing.
        self.assertEqual(self.store.get(task["id"])["state"], "preparing")

    def test_auto_archive_includes_failed_creation(self):
        # Given a failed-create task whose final window has closed.
        task = self.manager.create(self.repo, "Failed creation")
        self.manager.desktop = DesktopState(self.store, task)
        task["state"] = "create-failed"
        self.store.save(task)
        # When the closure reaches the coordinator.
        self.manager.archive_if_empty(task)
        # Then the failed task is archived too.
        self.assertEqual(self.store.get(task["id"])["state"], "archived")

    def test_auto_archive_includes_failed_restore(self):
        # Given a failed-restore task whose final window has closed.
        task = self.manager.create(self.repo, "Failed restore")
        self.manager.desktop = DesktopState(self.store, task)
        task["state"] = "restore-failed"
        self.store.save(task)
        # When the closure reaches the coordinator.
        self.manager.archive_if_empty(task)
        # Then the failed task is archived too.
        self.assertEqual(self.store.get(task["id"])["state"], "archived")

    def test_agent_terminal_retains_a_shell_parent_for_cwd_inheritance(self):
        # Given a launcher that reports the process Omarchy would inspect.
        launcher = self.root / "agent launcher"
        launcher.write_text(f"#!{sys.executable}\nimport os\nprint(os.readlink(f'/proc/{{os.getppid()}}/exe'))\n")
        launcher.chmod(0o755)
        # When the task terminal launches its agent command.
        result = subprocess.run(task_terminal_command(str(launcher), "task123"),
                                cwd=self.root, capture_output=True, text=True, check=True)
        # Then the terminal's direct child remains a recognized shell, not the agent.
        self.assertEqual(result.stdout.strip(), str(Path("/bin/bash").resolve()))

    def test_task_app_id_is_accepted_by_gtk(self):
        # Given GTK's actual application-ID validator, also used by Ghostty.
        library = ctypes.util.find_library("gio-2.0")
        if not library:
            self.skipTest("GLib is not installed")
        gio = ctypes.CDLL(library)
        gio.g_application_id_is_valid.argtypes = [ctypes.c_char_p]
        gio.g_application_id_is_valid.restype = ctypes.c_int
        # When validating a task ID beginning with a digit.
        valid = gio.g_application_id_is_valid(task_app_id("81e982a8c759").encode())
        # Then GTK accepts it instead of falling back to the default Ghostty class.
        self.assertEqual(valid, 1)

    def test_browser_profile_picker_keeps_same_named_profiles_distinct(self):
        # Given two Chromium profiles with the same display name.
        path = Path(os.environ["XDG_CONFIG_HOME"]) / "chromium/Local State"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({"profile": {"info_cache": {
            "Default": {"name": "Personal"}, "Profile 1": {"name": "Personal"},
        }}}))
        # When reading choices and decoding Omarchy's selection of the second profile.
        rows = menu_rows(chromium_profiles())
        # Then the directory identity survives the duplicate label.
        self.assertEqual(rows["Personal\tProfile 1"], "Profile 1")


    def test_checkout_has_a_clean_repo_basename(self):
        # Given a repository and a task name.
        task = self.manager.create(self.repo, "Invoice rounding")
        # When resolving the task checkout.
        path = Path(task["path"])
        # Then its basename is only the repository name.
        self.assertEqual(path.name, self.repo.name)

    def test_delete_removes_empty_task_container(self):
        # Given a task checkout nested in its dedicated container.
        task = self.manager.create(self.repo, "Invoice rounding")
        container = Path(task["path"]).parent
        # When deleting the task.
        self.manager.delete(task)
        # Then its empty container is also removed.
        self.assertFalse(container.exists())


    def test_desktop_shell_uses_terminal_default_command(self):
        # Given a task and a terminal launcher that reports its received arguments.
        task = {"id": "abc123", "repo": str(self.repo), "path": str(self.root / "checkout")}
        launcher = self.root / "xdg-terminal-exec"
        launcher.write_text(f"#!{sys.executable}\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n")
        launcher.chmod(0o755)
        # When opening a desktop shell through the real command chain.
        with patch.dict(os.environ, {"PATH": str(self.root) + ":" + os.environ["PATH"]}):
            result = subprocess.run(task_terminal_launch("hyprgrid-task", task, shell=True),
                                    capture_output=True, text=True, check=True)
        # Then only terminal options are supplied, allowing its configured shell to start.
        self.assertEqual(json.loads(result.stdout), ["--app-id=org.hyprgrid.taskabc123", f'--dir={task["path"]}'])

    def test_existing_task_uses_the_original_working_copy(self):
        # Given unfinished work in an existing checkout.
        (self.repo / "source-only").write_text("unfinished")
        # When creating a task around that checkout.
        task = self.manager.create(self.repo, "Existing work", existing=True)
        # Then the task uses that exact working copy.
        self.assertEqual(Path(task["path"]), self.repo)

    def test_existing_task_does_not_create_a_jj_workspace(self):
        # Given an existing checkout.
        # When creating a task around it.
        self.manager.create(self.repo, "Existing work", existing=True)
        # Then jj still has only the original workspace.
        self.assertEqual(self.command("jj", "workspace", "list", "-T", 'name ++ "\\n"'), "default")

    def test_existing_task_does_not_require_trunk(self):
        # Given a checkout without a resolvable default branch.
        self.command("jj", "config", "set", "--repo", 'revset-aliases."trunk()"', "missing_branch")
        # When creating a task around its current work.
        task = self.manager.create(self.repo, "Existing work", existing=True)
        # Then it becomes active without resolving trunk().
        self.assertEqual(task["state"], "active")

    def test_existing_task_skips_setup(self):
        # Given a checkout with a setup hook that would create a service.
        # When creating a task around it.
        self.manager.create(self.repo, "Existing work", existing=True)
        # Then the hook has not started a new environment.
        self.assertFalse((self.repo / "service").exists())

    def test_existing_task_archive_keeps_services(self):
        # Given a checkout with an already-running service.
        (self.repo / "service").write_text("existing service")
        # And a task around that checkout.
        task = self.manager.create(self.repo, "Existing work", existing=True)
        # When archiving the task.
        self.manager.archive(task)
        # Then teardown has not removed the existing service.
        self.assertEqual((self.repo / "service").read_text(), "existing service")

    def test_existing_task_preserves_inherited_compose_project(self):
        # Given an existing checkout using its normal Compose project name.
        task = self.manager.create(self.repo, "Existing work", existing=True)
        # And an explicit project inherited from the user's environment.
        with patch.dict(os.environ, {"COMPOSE_PROJECT_NAME": "existing-project"}):
            # When preparing a task terminal's environment.
            environment = task_environment(task)
        # Then the project name is not replaced with a task-owned project.
        self.assertEqual(environment["COMPOSE_PROJECT_NAME"], "existing-project")

    def test_existing_task_does_not_inject_a_compose_project(self):
        # Given an existing-checkout task without an explicit Compose project name.
        task = self.manager.create(self.repo, "Existing work", existing=True)
        # When preparing its environment with no inherited project name.
        with patch.dict(os.environ, {}, clear=True):
            environment = task_environment(task)
        # Then Compose can use the checkout's normal project selection.
        self.assertNotIn("COMPOSE_PROJECT_NAME", environment)

    def test_existing_task_delete_preserves_uncommitted_work(self):
        # Given unfinished work in a task's borrowed checkout.
        task = self.manager.create(self.repo, "Existing work", existing=True)
        (self.repo / "source-only").write_text("unfinished")
        # When deleting the task.
        self.manager.delete(task)
        # Then the checkout and its unfinished work remain intact.
        self.assertEqual((self.repo / "source-only").read_text(), "unfinished")

    def test_existing_task_delete_preserves_jj_workspace(self):
        # Given a task using an existing jj workspace.
        task = self.manager.create(self.repo, "Existing work", existing=True)
        # When deleting the task.
        self.manager.delete(task)
        # Then the original jj workspace remains registered.
        self.assertEqual(self.command("jj", "workspace", "list", "-T", 'name ++ "\\n"'), "default")

    def test_existing_task_delete_removes_its_record(self):
        # Given a task around an existing checkout.
        task = self.manager.create(self.repo, "Existing work", existing=True)
        # When deleting the task.
        self.manager.delete(task)
        # Then the task is no longer registered.
        self.assertEqual(self.store.read(), {})

    def test_existing_task_restore_reuses_the_conversation(self):
        # Given an archived existing-checkout task.
        task = self.manager.create(self.repo, "Existing work", existing=True)
        session = task["session"]
        self.manager.archive(task)
        # When restoring the saved record.
        self.manager.restore(self.store.get(task["id"]))
        # Then it keeps the same conversation.
        self.assertEqual(self.store.get(task["id"])["session"], session)

    def test_existing_task_restore_skips_setup(self):
        # Given an archived existing-checkout task with setup available.
        task = self.manager.create(self.repo, "Existing work", existing=True)
        self.manager.archive(task)
        # When restoring it.
        self.manager.restore(task)
        # Then the user's environment is not prepared again.
        self.assertFalse((self.repo / "service").exists())

    def test_existing_task_restore_does_not_recreate_a_missing_checkout(self):
        # Given an archived task whose checkout was moved outside the manager.
        task = self.manager.create(self.repo, "Existing work", existing=True)
        self.manager.archive(task)
        self.repo.rename(self.repo.with_name("moved"))
        # When restoring it.
        # Then it reports the missing checkout rather than creating a replacement.
        with self.assertRaisesRegex(TaskError, "missing"):
            self.manager.restore(task)

    def test_existing_task_rejects_an_already_registered_checkout_alias(self):
        # Given an archived task around a checkout.
        task = self.manager.create(self.repo, "Existing work", existing=True)
        self.manager.archive(task)
        # And another path to the same working copy.
        alias = self.root / "other/alias"
        alias.symlink_to(self.repo)
        # When trying to register it again.
        # Then the user is directed to reuse the existing task.
        with self.assertRaisesRegex(TaskError, "already.*task"):
            self.manager.create(alias, "Duplicate", existing=True)

    def test_working_copy_discovery_keeps_distinct_jj_workspaces(self):
        # Given another existing working copy of the same repository.
        other = self.root / "homebound/other-copy"
        other.parent.mkdir()
        self.command("jj", "workspace", "add", "--name", "other", str(other))
        # And an alias to the original checkout.
        (self.root / "other/alias").symlink_to(self.repo)
        # When discovering existing working copies.
        copies = self.settings.working_copies()
        # Then both distinct copies are selectable, but the alias is not duplicated.
        self.assertEqual(copies, [self.repo, other])

    def test_existing_task_cli_flag(self):
        # Given isolated state and an in-memory session service.
        with patch.dict(os.environ, {"HYPRGRID_STATE_DIR": str(self.store.path)}), \
                patch("core.OpenCode", return_value=self.agent), \
                patch("sys.argv", ["hyprgrid-task", "new", "--existing", "--repo", str(self.repo), "--name", "Existing work"]), \
                redirect_stdout(io.StringIO()):
            # When creating an existing-checkout task through the CLI.
            result = main()
        # Then the command accepts the mode and completes.
        self.assertEqual(result, 0)

    def test_desktop_new_task_offers_existing_working_copy(self):
        # Given a desktop task-creation menu selecting existing work and then its checkout.
        self.manager.desktop = TaskLauncher()
        with patch("cli.pick", side_effect=["existing", str(self.repo)]), \
                patch("cli.text_input", side_effect=AssertionError("Existing copies do not need a name prompt")):
            # When completing the desktop creation flow.
            desktop_menu(self.manager, "new", None)
        # Then the created task uses the selected checkout, not a new workspace.
        self.assertEqual([task["path"] for task in self.store.read().values()], [str(self.repo)])

    def test_existing_task_interrupt_preserves_location_scoped_shells(self):
        # Given an existing-checkout task sharing its location with another session's shell.
        task = self.manager.create(self.repo, "Existing work", existing=True)
        service = ShellService()
        # When interrupting the task's agent session.
        service.interrupt(task)
        # Then the unrelated location-scoped shell survives.
        self.assertEqual(service.shells, [{"id": "existing-shell"}])

    def test_legacy_dedicated_task_interrupt_still_cleans_up_shells(self):
        # Given a dedicated task saved before checkout modes were introduced.
        task = self.manager.create(self.repo, "Dedicated work")
        del task["checkout_mode"]
        # And a detached shell in its task-owned location.
        service = ShellService()
        # When interrupting the task's agent session.
        service.interrupt(task)
        # Then the task-owned shell is removed as before.
        self.assertEqual(service.shells, [])

    def test_legacy_dedicated_task_delete_still_removes_checkout(self):
        # Given a dedicated task saved before checkout modes were introduced.
        task = self.manager.create(self.repo, "Dedicated work")
        del task["checkout_mode"]
        del task["repo_identity"]
        self.store.save(task)
        # When deleting its saved record.
        self.manager.delete(self.store.get(task["id"]))
        # Then its dedicated checkout is removed as before.
        self.assertFalse(Path(task["path"]).exists())

    def test_promotion_registers_the_existing_row(self):
        # Given an unmanaged desktop row and an existing checkout.
        self.manager.desktop = PromotionDesktop(self.store)
        # When creating a managed task from that row.
        task = self.manager.create(self.repo, "Promoted work", desktop=True, existing=True, adopt_window="0x123")
        # Then the task claims the existing row rather than reserving a new one.
        self.assertEqual(self.store.rows(), {task["id"]: 4})

    def test_promotion_requires_existing_checkout_mode(self):
        # Given an unmanaged desktop row.
        self.manager.desktop = PromotionDesktop(self.store)
        # When trying to promote it with a new dedicated checkout.
        # Then the existing work is not silently redirected to a different working copy.
        with self.assertRaisesRegex(TaskError, "existing"):
            self.manager.create(self.repo, "Promoted work", desktop=True, adopt_window="0x123")

    def test_desktop_actions_promote_an_unmanaged_row_without_opening_a_new_agent(self):
        # Given an unmanaged row captured before opening its task-actions menu.
        self.manager.desktop = PromotionDesktop(self.store)
        # And a user choosing only the existing checkout, with no separate promotion step.
        with patch("cli.pick", side_effect=[str(self.repo)]), \
                patch("cli.text_input", side_effect=AssertionError("Promotion does not need a name prompt")):
            # When completing the task-actions flow.
            desktop_menu(self.manager, "actions", None, window="0x123")
        # Then the managed task stays associated with the captured row.
        task = next(iter(self.store.read().values()))
        self.assertEqual(self.store.rows(), {task["id"]: 4})

    def test_promotion_row_selection_captures_a_window_not_focus(self):
        # Given a terminal in the requested row and other windows elsewhere.
        clients = [
            {"address": "0x456", "workspace": {"name": "2a"}},
            {"address": "0x123", "workspace": {"name": "3c"}},
        ]
        # When resolving row c before any prompts open.
        with patch("desktop.run", return_value=json.dumps(clients)):
            address = Desktop(self.store, "hyprgrid-task").promotion_window("c")
        # Then promotion will identify a window from the selected row.
        self.assertEqual(address, "0x123")

    def test_promotion_cli_registers_the_selected_row(self):
        # Given a desktop row and isolated CLI state.
        desktop = PromotionDesktop(self.store)
        with patch.dict(os.environ, {"HYPRGRID_STATE_DIR": str(self.store.path), "HYPRLAND_INSTANCE_SIGNATURE": "test"}), \
                patch("cli.Desktop", return_value=desktop), \
                patch("core.OpenCode", return_value=self.agent), \
                patch("sys.argv", ["hyprgrid-task", "promote", "--row", "c", "--repo", str(self.repo), "--name", "Promoted work"]), \
                redirect_stdout(io.StringIO()):
            # When promoting through the CLI.
            main()
        # Then the selected row is assigned to the new task.
        task = next(iter(self.store.read().values()))
        self.assertEqual(self.store.rows(), {task["id"]: 4})

    def test_automatic_promotion_can_cancel_the_checkout_picker(self):
        # Given an unmanaged row and a canceled checkout picker.
        self.manager.desktop = PromotionDesktop(self.store)
        with patch("cli.pick", return_value=None):
            # When opening its task actions.
            desktop_menu(self.manager, "actions", None, window="0x123")
        # Then the row has not become a managed task.
        self.assertEqual(self.store.read(), {})

    def test_managed_row_actions_still_offer_rename(self):
        # Given an existing managed task.
        task = self.manager.create(self.repo, "Original name", existing=True)
        # And a user choosing rename from its normal actions menu.
        with patch("cli.pick", return_value="rename"), \
                patch("cli.text_input", return_value="Renamed task"):
            # When opening task actions for the managed row.
            desktop_menu(self.manager, "actions", task["id"])
        # Then its normal rename action still works, without promotion prompts.
        self.assertEqual(self.store.get(task["id"])["name"], "Renamed task")

    def test_default_task_name_uses_the_working_copy_directory_not_the_source_repo(self):
        # Given a second working copy with a different directory name from its source repository.
        checkout = self.root / "homebound/graphql-service-2"
        checkout.parent.mkdir()
        self.command("jj", "workspace", "add", "--name", "second", str(checkout))
        # When registering it without an explicit name.
        task = self.manager.create(checkout, existing=True)
        # Then its task name matches the selected working copy's directory.
        self.assertEqual(task["name"], "graphql-service-2")

    def test_default_task_name_can_be_overridden(self):
        # Given a working copy and an explicit task name.
        # When registering it with that name.
        task = self.manager.create(self.repo, "Custom task name", existing=True)
        # Then the explicit name is kept instead of the directory name.
        self.assertEqual(task["name"], "Custom task name")

    def test_desktop_existing_copy_defaults_its_task_name(self):
        # Given an existing checkout selected in the new-task menu.
        self.manager.desktop = TaskLauncher()
        with patch("cli.pick", side_effect=["existing", str(self.repo)]), \
                patch("cli.text_input", side_effect=AssertionError("Unexpected name prompt")):
            # When creating the task without another prompt.
            desktop_menu(self.manager, "new", None)
        # Then the saved task uses the checkout directory name.
        self.assertEqual(next(iter(self.store.read().values()))["name"], self.repo.name)

    def test_desktop_promotion_defaults_its_task_name(self):
        # Given an unmanaged row and a selected checkout.
        self.manager.desktop = PromotionDesktop(self.store)
        with patch("cli.pick", return_value=str(self.repo)), \
                patch("cli.text_input", side_effect=AssertionError("Unexpected name prompt")):
            # When promoting the row without another prompt.
            desktop_menu(self.manager, "actions", None, window="0x123")
        # Then the saved task uses the checkout directory name.
        self.assertEqual(next(iter(self.store.read().values()))["name"], self.repo.name)

    def test_existing_copy_cli_defaults_its_task_name(self):
        # Given isolated CLI state and no explicit --name.
        with patch.dict(os.environ, {"HYPRGRID_STATE_DIR": str(self.store.path)}), \
                patch("core.OpenCode", return_value=self.agent), \
                patch("sys.argv", ["hyprgrid-task", "new", "--existing", "--repo", str(self.repo)]), \
                patch("cli.text_input", side_effect=AssertionError("Unexpected name prompt")), \
                redirect_stdout(io.StringIO()):
            # When creating a task around an existing checkout.
            main()
        # Then the saved task uses the checkout directory name.
        self.assertEqual(next(iter(self.store.read().values()))["name"], self.repo.name)

    def test_new_dedicated_workspace_still_uses_its_entered_task_name(self):
        # Given a new dedicated workspace selected in the task-creation menu.
        self.manager.desktop = TaskLauncher()
        # And an explicitly entered task name.
        with patch("cli.pick", side_effect=["dedicated", str(self.repo)]), \
                patch("cli.text_input", return_value="Invoice rounding"):
            # When creating its isolated workspace.
            desktop_menu(self.manager, "new", None)
        # Then the dedicated task keeps its entered name.
        self.assertEqual(next(iter(self.store.read().values()))["name"], "Invoice rounding")

    def test_auto_promoted_task_does_not_have_a_checkout(self):
        # Given a row assigned by the compositor before the background command runs.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        # When the coordinator publishes its metadata.
        task = self.manager.ensure_task("row123")
        # Then the working copy is optional.
        self.assertIsNone(task["path"])

    def test_auto_promoted_task_does_not_create_an_agent_session(self):
        # Given a newly assigned desktop row.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        # When publishing its metadata.
        self.manager.ensure_task("row123")
        # Then no managed agent has been created.
        self.assertEqual(self.agent.sessions, {})

    def test_auto_promoted_task_uses_the_existing_row_description(self):
        # Given an existing row description and a new task assignment.
        descriptions = Path(os.environ["XDG_STATE_HOME"]) / "hypr/workspace-descriptions.json"
        descriptions.parent.mkdir(parents=True)
        descriptions.write_text(json.dumps({"b": "Release planning"}))
        # And the compositor's row reservation.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        # When publishing metadata.
        task = self.manager.ensure_task("row123")
        # Then the task keeps the existing row name.
        self.assertEqual(task["name"], "Release planning")

    def test_auto_promoted_task_defaults_to_the_row_letter(self):
        # Given a new task reservation without a saved description.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        # When publishing metadata.
        task = self.manager.ensure_task("row123")
        # Then it has a useful name without prompting.
        self.assertEqual(task["name"], "Task b")

    def test_auto_promoted_task_can_be_archived_without_a_checkout(self):
        # Given an automatically promoted row whose final window has closed.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        task = self.manager.ensure_task("row123")
        self.manager.desktop = DesktopState(self.store, task)
        # When its lifecycle operation runs.
        self.manager.archive_if_empty(task)
        # Then the task is archived without needing a working copy or teardown.
        self.assertEqual(self.store.get(task["id"])["state"], "archived")

    def test_delayed_prefix_registration_does_not_reactivate_an_archived_task(self):
        # Given an archive action that won the race with the prefix's background command.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        task = self.manager.ensure_task("row123")
        self.manager.desktop = DesktopState(self.store, task)
        self.manager.archive(task)
        # When the delayed prefix command resolves the same task ID.
        self.manager.ensure_task("row123")
        # Then archive remains authoritative.
        self.assertEqual(self.store.get("row123")["state"], "archived")

    def test_auto_promoted_task_restore_does_not_create_a_session(self):
        # Given an archived task with no working copy.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        task = self.manager.ensure_task("row123")
        self.manager.desktop = DesktopState(self.store, task)
        self.manager.archive(task)
        # When restoring it headlessly.
        self.manager.restore(task)
        # Then its agent remains optional.
        self.assertEqual(self.agent.sessions, {})

    def test_auto_promoted_task_delete_only_removes_its_record(self):
        # Given a basic task whose windows have closed.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        task = self.manager.ensure_task("row123")
        self.manager.desktop = DesktopState(self.store, task)
        # When deleting the task.
        self.manager.delete(task)
        # Then it is forgotten without a checkout cleanup operation.
        self.assertEqual(self.store.read(), {})

    def test_working_copy_can_be_attached_to_a_basic_task_later(self):
        # Given a basic task with no checkout.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        task = self.manager.ensure_task("row123")
        # When choosing a working copy for future managed launches.
        self.manager.attach_checkout(task, self.repo)
        # Then the selected directory is saved on the same task.
        self.assertEqual(self.store.get("row123")["path"], str(self.repo))

    def test_attaching_a_working_copy_does_not_start_an_agent(self):
        # Given a basic task and a repository with setup hooks.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        task = self.manager.ensure_task("row123")
        # When attaching the existing checkout.
        self.manager.attach_checkout(task, self.repo)
        # Then attachment alone does not launch an agent.
        self.assertEqual(self.agent.sessions, {})

    def test_task_picker_supports_tasks_without_a_working_copy(self):
        # Given a named task with no working copy.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        self.manager.ensure_task("row123")
        # When listing tasks.
        choices = task_choices(self.store)
        # Then its row and lack of a working copy are visible.
        self.assertEqual(choices, [("row123", "Task b", "b · no working copy · idle · row123")])

    def test_pathless_task_terminal_starts_in_home(self):
        # Given a task without a working copy.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        task = self.manager.ensure_task("row123")
        # When building its ordinary terminal launch.
        command = task_terminal_launch("hyprgrid-task", task, shell=True)
        # Then it uses the user's home directory, not an invented checkout.
        self.assertEqual(command[-1], "--dir=" + str(Path.home()))

    def test_pathless_task_environment_does_not_include_null_checkout_values(self):
        # Given a task without a working copy.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        task = self.manager.ensure_task("row123")
        # When constructing an otherwise empty terminal environment.
        with patch.dict(os.environ, {}, clear=True):
            environment = task_environment(task)
        # Then only the task identity is added.
        self.assertEqual(environment, {"HYPRGRID_TASK_ID": "row123"})

    def test_pathless_tasks_do_not_contact_opencode_during_activity_checks(self):
        # Given a basic task with no session.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        self.manager.ensure_task("row123")
        # And a service that must not be contacted just to manage a desktop row.
        with patch.object(self.manager.agent, "api", create=True, side_effect=AssertionError("Unexpected API request")):
            # When checking activity once.
            watch_tasks(self.store, self.manager.agent, once=True)
        # Then it remains idle rather than reporting an unknown agent state.
        self.assertEqual(self.store.get("row123")["activity"], "idle")

    def test_attaching_a_working_copy_does_not_run_setup(self):
        # Given a basic task and a checkout with an available setup hook.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        task = self.manager.ensure_task("row123")
        # When attaching that checkout.
        self.manager.attach_checkout(task, self.repo)
        # Then setup has not started the checkout's service.
        self.assertFalse((self.repo / "service").exists())

    def test_working_copy_attachment_preserves_the_task_name(self):
        # Given a basic task with a chosen name.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        task = self.manager.ensure_task("row123")
        task["name"] = "Release planning"
        self.store.save(task)
        # When attaching a checkout with a different directory name.
        self.manager.attach_checkout(task, self.repo)
        # Then attachment does not rename the task.
        self.assertEqual(self.store.get("row123")["name"], "Release planning")

    def test_auto_archive_can_arrive_before_the_prefix_metadata_command(self):
        # Given a compositor-assigned task whose final window closed before Python initialized it.
        self.manager.desktop = DesktopState(self.store, {"id": "row123"})
        # When the closure action reaches the coordinator first.
        execute_action(self.manager, "archive-empty", "row123", None)
        # Then it both initializes and archives that task, rather than leaking the row.
        self.assertEqual(self.store.get("row123")["state"], "archived")

    def test_actions_can_attach_a_checkout_before_prefix_metadata_finishes(self):
        # Given a task ID already assigned by the compositor, but no saved task metadata yet.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        # And an immediate action to attach a checkout.
        with patch("cli.pick", side_effect=["set-checkout", str(self.repo)]):
            # When opening task actions ahead of the prefix's background command.
            desktop_menu(self.manager, "actions", "row123")
        # Then the checkout is attached to the same task identity.
        self.assertEqual(self.store.get("row123")["path"], str(self.repo))

    def test_agent_launch_requires_a_working_copy(self):
        # Given a basic task with no associated working copy.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        task = self.manager.ensure_task("row123")
        # When requesting its first agent session.
        # Then it reports the missing association instead of guessing a directory.
        with self.assertRaisesRegex(TaskError, "Attach a working copy"):
            OpenCode().ensure_session(task, self.store)

    def test_attached_checkout_cannot_already_belong_to_another_task(self):
        # Given a checkout registered to another task.
        self.manager.create(self.repo, existing=True)
        # And a new basic task.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        task = self.manager.ensure_task("row123")
        # When selecting that same checkout for the basic task.
        # Then ownership is not duplicated.
        with self.assertRaisesRegex(TaskError, "already belongs"):
            self.manager.attach_checkout(task, self.repo)

    def test_delayed_prefix_command_does_not_recreate_a_deleted_task(self):
        # Given a promoted task that was deleted before the prefix's background command ran.
        (self.store.path / "rows.tsv").write_text("row123\t3\n")
        task = self.manager.ensure_task("row123")
        self.manager.desktop = DesktopState(self.store, task)
        self.manager.delete(task)
        # When the delayed registration command arrives.
        with patch.dict(os.environ, {"HYPRGRID_STATE_DIR": str(self.store.path)}), \
                patch("sys.argv", ["hyprgrid-task", "ensure-task", "row123"]):
            main()
        # Then it leaves the task deleted instead of reserving another row.
        self.assertEqual(self.store.read(), {})

    def test_organize_initializes_pending_task_names_before_renumbering(self):
        # Given a promoted row whose saved description has not yet become task metadata.
        descriptions = Path(os.environ["XDG_STATE_HOME"]) / "hypr/workspace-descriptions.json"
        descriptions.parent.mkdir(parents=True)
        descriptions.write_text(json.dumps({"i": "Release planning"}))
        # And a queued prefix for row i.
        (self.store.path / "rows.tsv").write_text("late\t10\n")
        self.manager.desktop = OrganizingDesktop(self.store)
        # When organize runs ahead of the prefix's metadata command.
        self.manager.organize()
        # Then the task name came from its original row, not its new letter.
        self.assertEqual(self.store.get("late")["name"], "Release planning")

    def test_organize_cli_updates_the_compositor_owned_row_snapshot(self):
        # Given an isolated desktop and a sparse row.
        (self.store.path / "rows.tsv").write_text("late\t10\n")
        desktop = OrganizingDesktop(self.store)
        # When the organize command is dispatched.
        with patch.dict(os.environ, {"HYPRGRID_STATE_DIR": str(self.store.path), "HYPRLAND_INSTANCE_SIGNATURE": "test"}), \
                patch("cli.Desktop", return_value=desktop), \
                patch("sys.argv", ["hyprgrid-task", "organize"]):
            main()
        # Then the same task identity has the compacted row.
        self.assertEqual(self.store.rows(), {"late": 2})

    def test_organize_archives_empty_desktop_only_tasks(self):
        # Given an empty desktop task without a checkout or agent session.
        (self.store.path / "rows.tsv").write_text("empty\t4\n")
        self.manager.ensure_task("empty")
        self.manager.desktop = OrganizingDesktop(self.store, windows={})
        # When explicitly organizing.
        self.manager.organize()
        # Then the task is archived, retaining its metadata for restore.
        self.assertEqual(self.store.get("empty")["state"], "archived")

    def test_organize_reclaims_the_empty_task_slot_before_compacting(self):
        # Given an empty c reservation between populated b and d tasks.
        (self.store.path / "rows.tsv").write_text("first\t2\nsecond\t3\nempty\t4\nsurvivor\t5\n")
        self.manager.desktop = OrganizingDesktop(self.store, windows={
            "first": ["0x123"], "second": ["0x234"], "survivor": ["0x456"],
        })
        # When organizing before the prefix's metadata commands have finished.
        self.manager.organize()
        # Then d reclaims c while the earlier tasks keep their letters.
        self.assertEqual(self.store.rows(), {"first": 2, "second": 3, "survivor": 4})

    def test_organize_preserves_desktop_tasks_with_windows(self):
        # Given a desktop-only task that still has a row window.
        (self.store.path / "rows.tsv").write_text("occupied\t4\n")
        self.manager.ensure_task("occupied")
        self.manager.desktop = OrganizingDesktop(self.store, windows={"occupied": ["0x456"]})
        # When organizing.
        self.manager.organize()
        # Then the populated task remains active.
        self.assertEqual(self.store.get("occupied")["state"], "active")

    def test_organize_preserves_empty_tasks_with_a_checkout(self):
        # Given an empty task with an attached checkout but no agent session.
        (self.store.path / "rows.tsv").write_text("checkout\t4\n")
        task = self.manager.ensure_task("checkout")
        self.manager.attach_checkout(task, self.repo)
        self.manager.desktop = OrganizingDesktop(self.store, windows={})
        # When organizing.
        self.manager.organize()
        # Then the checkout's reservation remains intact.
        self.assertEqual(self.store.rows(), {"checkout": 2})

    def test_organize_preserves_empty_tasks_with_an_agent_session(self):
        # Given an empty task with an agent session recorded independently of its checkout.
        (self.store.path / "rows.tsv").write_text("agent\t4\n")
        task = self.manager.ensure_task("agent")
        self.agent.ensure_session(task, self.store)
        self.manager.desktop = OrganizingDesktop(self.store, windows={})
        # When organizing.
        self.manager.organize()
        # Then the agent's reservation remains intact.
        self.assertEqual(self.store.rows(), {"agent": 2})

    def test_organize_preserves_setup_reservations(self):
        # Given an empty task whose setup has not finished.
        (self.store.path / "rows.tsv").write_text("preparing\t4\n")
        task = self.manager.ensure_task("preparing")
        task["state"] = "preparing"
        self.store.save(task)
        self.manager.desktop = OrganizingDesktop(self.store, windows={})
        # When organizing.
        self.manager.organize()
        # Then setup keeps its reservation.
        self.assertEqual(self.store.rows(), {"preparing": 2})

    def test_organize_checks_layout_before_archiving_empty_tasks(self):
        # Given an empty task whose layout cannot safely resolve task ownership.
        (self.store.path / "rows.tsv").write_text("empty\t4\n")
        self.manager.ensure_task("empty")
        self.manager.desktop = OrganizingDesktop(self.store, windows={})
        self.manager.desktop.layout_problem = "Grid label differs from its address"
        # When organization rejects that layout.
        with self.assertRaisesRegex(TaskError, "Grid label differs"):
            self.manager.organize()
        # Then no task has been archived as a side effect.
        self.assertEqual(self.store.get("empty")["state"], "active")


if __name__ == "__main__":
    unittest.main()
