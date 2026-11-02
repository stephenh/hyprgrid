"""Exercise lifecycle boundaries with real jj workspaces and real repository hooks."""

import json
import ctypes
import ctypes.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tasks"))
from core import Manager, Settings, Store, TaskError, task_environment
from desktop import Desktop, chromium_profiles, lua_string, menu_rows, task_terminal_command, task_terminal_launch, task_app_id


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


if __name__ == "__main__":
    unittest.main()
