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
