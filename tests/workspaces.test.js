import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { runInNewContext } from "node:vm";

describe("Workspaces.qml", () => {
  it("refreshes monitor state when a workspace moves across monitors", () => {
    // Given a bar on the destination monitor, before focus catches up
    const bar = eventHandler(false);

    // When Hyprland reports a workspace move
    bar.onRawEvent({ name: "moveworkspacev2" });

    // Then both cached models are refreshed
    assert.deepEqual(bar.refreshes, ["monitors", "workspaces"]);
  });

  it("refreshes monitor state when the focused bar receives a workspace switch", () => {
    // Given the bar on the focused monitor
    const bar = eventHandler(true);

    // When Hyprland reports a workspace switch
    bar.onRawEvent({ name: "workspacev2" });

    // Then both cached models are refreshed
    assert.deepEqual(bar.refreshes, ["monitors", "workspaces"]);
  });

  it("suppresses managed attention while snoozed", () => {
    // Given a task waiting for input with a future snooze deadline
    const context = taskFunctions(1000);
    const task = { state: "active", activity: "needs-input", snoozed_until: 2 };

    // When the bar computes its attention flag
    const urgent = context.taskAttention(task);

    // Then the native bell cannot bypass snoozing
    assert.equal(urgent, false);
  });

  it("restores attention when a snooze expires without another agent event", () => {
    // Given a task with an expired snooze
    const context = taskFunctions(3000);
    const task = { state: "active", activity: "ready", snoozed_until: 2 };

    // When the wall clock passes the deadline
    const urgent = context.taskAttention(task);

    // Then its pending response needs attention again
    assert.equal(urgent, true);
  });

  it("resolves a task by its new row after compaction", () => {
    // Given a stable task that has moved from b to a
    const context = taskFunctions(0);
    context.loadTasks(JSON.stringify({ version: 1, tasks: { stable: { name: "Invoices" } } }));

    // When the compositor publishes the new row assignment
    context.loadTaskRows("stable\t2\n");

    // Then the first row resolves to the original task
    assert.equal(context.taskForWorkspace("2a").name, "Invoices");
  });

});

/** Run the actual QML event handler without starting a shell on the live desktop. */
function eventHandler(focused) {
  const source = readFileSync(new URL("../quattro/hyprgrid.workspaces/Workspaces.qml", import.meta.url), "utf8");
  const handler = source.match(/    function onRawEvent\(event\) \{[\s\S]*?\n    \}/)[0];
  const refreshes = [];
  const context = {
    root: { monitor: { focused } },
    Hyprland: {
      refreshMonitors() { refreshes.push("monitors"); },
      refreshWorkspaces() { refreshes.push("workspaces"); },
    },
  };
  runInNewContext(handler, context);
  return { onRawEvent: context.onRawEvent, refreshes };
}

/** Exercise the bar's task projection without QML rendering or a live compositor. */
function taskFunctions(now) {
  const source = readFileSync(new URL("../quattro/hyprgrid.workspaces/Workspaces.qml", import.meta.url), "utf8");
  const context = { root: { now }, tasks: {}, taskRows: {} };
  for (const name of ["loadTasks", "loadTaskRows", "taskForWorkspace", "taskStatus", "taskAttention"]) {
    const handler = source.match(new RegExp(`  function ${name}\\([^]*?\\n  \\}`))[0];
    runInNewContext(handler, context);
  }
  return context;
}
