"""Hyprland mutations and Omarchy pickers, kept out of the headless lifecycle code."""

import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import time

from core import TaskError, run


class Desktop:
    """Address task reservations by stable ID through the grid's Lua API."""

    def __init__(self, store, executable):
        self.store = store
        self.executable = executable

    def evaluate(self, code):
        """Treat compositor-reported Lua errors as failures even if hyprctl exits zero."""
        code = 'assert(hyprgrid and hyprgrid.tasks_enabled, "Load the hyprgrid task adapter first"); ' + code
        output = run(["hyprctl", "eval", code], timeout=10).strip()
        if output != "ok":
            raise TaskError(output or "Hyprland did not acknowledge the task command")

    def reserve(self, task):
        """Allocate without focusing; setup can continue while the user works elsewhere."""
        self.evaluate(f'hyprgrid.reserve({lua_string(task["id"])})')

    def release(self, task):
        """Let the grid compact rows after a successful archive."""
        self.evaluate(f'hyprgrid.release({lua_string(task["id"])})')

    def jump(self, task, terminal=False):
        """Preserve the current tool column, unless opening the task's terminal."""
        column = ', "2"' if terminal else ""
        self.evaluate(f'hyprgrid.jump({lua_string(task["id"])}{column})')

    def open(self, task, shell=False):
        """Launch a tagged native terminal; the Lua adapter routes its eventual window."""
        self.reserve(task)
        self.jump(task, terminal=True)
        command = ["xdg-terminal-exec", f'--app-id=hyprgrid-{task["id"]}',
                   f'--dir={task["path"]}', "--", self.executable,
                   "shell" if shell else "attach", task["id"]]
        command.append("--active-only")
        # Hyprland launches with the desktop environment even when invoked by another client.
        self.evaluate(f"hl.exec_cmd({lua_string(shlex.join(command))})")
        deadline = time.monotonic() + 10
        while not any(client.get("initialClass") == f'hyprgrid-{task["id"]}'
                      or client.get("class") == f'hyprgrid-{task["id"]}'
                      for client in self.clients(task)):
            if time.monotonic() >= deadline:
                raise TaskError("Task terminal did not appear with its app-id; check xdg-terminal-exec support")
            time.sleep(0.1)

    def clients(self, task):
        """Resolve the current row each time; a previous archive may have compacted it."""
        row = self.store.rows().get(task["id"])
        if row is None:
            return []
        letter = chr(ord("a") + row - 2)
        return [client for client in json.loads(run(["hyprctl", "-j", "clients"]))
                if re.fullmatch(r"\d+" + letter, client["workspace"]["name"])]

    def unmanaged_choices(self):
        """Offer pre-existing grid rows before they have managed task records."""
        managed = set(self.store.rows().values())
        path = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "hypr/workspace-descriptions.json"
        descriptions = json.loads(path.read_text()) if path.exists() else {}
        rows = {}
        for client in json.loads(run(["hyprctl", "-j", "clients"])):
            match = re.fullmatch(r"\d+([a-l])", client["workspace"]["name"])
            if not match or ord(match[1]) - ord("a") + 2 in managed:
                continue
            letter = match[1]
            label = str(descriptions.get(letter) or "Task " + letter).replace("\n", " ").replace("\t", " ")
            rows.setdefault(letter, ("window:" + client["address"], label,
                                     "Existing row " + letter + " · " + client.get("title", "")[:100].replace("\n", " ").replace("\t", " ")))
        return [rows[letter] for letter in sorted(rows)]

    def jump_window_row(self, address):
        """Follow a representative window if its unmanaged row compacted while the picker was open."""
        self.evaluate("for _, w in ipairs(hl.get_windows()) do "
                      f"if w.address == {lua_string(address)} and w.workspace then "
                      'local letter = w.workspace.name:match("^%d+([a-l])$"); '
                      "if letter then hyprgrid.jump_letter(letter) end; break end end")

    def close(self, task):
        """Gracefully close address-verified row members, never force-kill an application.

        A window that refuses closure (for example an unsaved editor) keeps the row
        reserved and makes archive retryable. No class-wide or process-wide kill is used.
        """
        for client in self.clients(task):
            address = client["address"]
            pid = int(client["pid"])
            workspace = client["workspace"]["name"]
            self.evaluate(
                "for _, w in ipairs(hl.get_windows()) do "
                f"if w.address == {lua_string(address)} and w.pid == {pid} "
                f"and w.workspace and w.workspace.name == {lua_string(workspace)} then "
                f'hl.dispatch(hl.dsp.window.close({{ window = {lua_string("address:" + address)} }})) '
                "end end")
        deadline = time.monotonic() + 5
        while self.clients(task):
            if time.monotonic() >= deadline:
                raise TaskError("Some task windows are still open. Save/close them, then retry archive.")
            time.sleep(0.1)


def pick(prompt, choices, graphical=False):
    """Return a machine key from a label/subtitle pair; cancellation has no side effects."""
    if not choices:
        raise TaskError(f"{prompt}: no entries")
    # Omarchy returns label + TAB + subtitle, omitting the leading icon field.
    if graphical:
        rows = menu_rows(choices)
        result = subprocess.run(["omarchy", "menu", "select", prompt],
                                input="\n".join("\t" + row for row in rows),
                                capture_output=True, text=True)
        if result.returncode:
            return None
        return rows.get(result.stdout.rstrip("\n"))
    if not os.isatty(0):
        raise TaskError("Specify a task ID when stdin is not a terminal")
    entries = list(choices)
    for number, (_, label, subtitle) in enumerate(entries, 1):
        print(f"{number:2}. {label} — {subtitle}")
    value = input(f"{prompt} [number, Enter cancels]: ").strip()
    if not value:
        return None
    if not value.isdigit() or not 1 <= int(value) <= len(entries):
        raise TaskError("Invalid selection")
    return entries[int(value) - 1][0]


def menu_rows(choices):
    """Match Omarchy's return protocol: rows without subtext return the label alone."""
    rows = {}
    for key, label, subtitle in choices:
        # Omarchy's menu labels/subtitles use Text.PlainText, not rich text.
        value = label
        if subtitle:
            value += "\t" + subtitle
        rows[value] = key
    return rows


def text_input(prompt, graphical=False):
    """Use the same task operations from a native prompt or an SSH terminal."""
    if not graphical:
        return input(prompt + ": ").strip() or None
    result = subprocess.run(["omarchy", "menu", "input", prompt], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def lua_string(value):
    """Encode UTF-8 as Lua decimal byte escapes, avoiding JSON's incompatible unicode escapes."""
    return '"' + "".join(f"\\{byte:03d}" for byte in value.encode("utf-8")) + '"'
