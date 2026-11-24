import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { runInNewContext } from "node:vm";

describe("hypr-agent-bell/tui.js", () => {
  for (const name of ["permission.asked", "form.created", "session.execution.failed", "session.execution.succeeded"]) {
    it(`rings for ${name} in the current session family`, () => {
      // Given a terminal showing the parent of the event's session.
      const bell = loadBell();
      // When the child session needs attention.
      bell.listeners.get(name)({ data: { sessionID: "local:child", form: { sessionID: "local:child" } } });
      // Then its terminal receives BEL.
      assert.deepEqual(bell.bells, ["\x07"]);
    });
  }

  it("ignores sessions belonging to another terminal", () => {
    // Given a terminal showing only the local session.
    const bell = loadBell();
    // When an unrelated session finishes.
    bell.listeners.get("session.execution.succeeded")({ data: { sessionID: "remote" } });
    // Then it does not ring this terminal.
    assert.deepEqual(bell.bells, []);
  });

  it("rings for an open background tab", () => {
    // Given a terminal with a different session open in a tab.
    const bell = loadBell({ tabs: [{ sessionID: "background" }] });
    // When that tab's child session finishes.
    bell.listeners.get("session.execution.succeeded")({ data: { sessionID: "background:child" } });
    // Then the terminal receives BEL.
    assert.deepEqual(bell.bells, ["\x07"]);
  });

  it("unsubscribes when the plugin unloads", () => {
    // Given the plugin's registered attention listeners.
    const bell = loadBell();
    // When it unloads.
    bell.stop();
    // Then no listeners remain.
    assert.equal(bell.listeners.size, 0);
  });

  it("does not disrupt the session when the terminal is unavailable", () => {
    // Given a terminal that cannot be written.
    const bell = loadBell({ unavailable: true });
    // When the local session finishes.
    const notify = bell.listeners.get("session.execution.succeeded");
    // Then the notification failure does not escape the event handler.
    assert.doesNotThrow(() => notify({ data: { sessionID: "local" } }));
  });
});

/** Execute the installed plugin's event logic without OpenCode or a real terminal. */
function loadBell(options = {}) {
  const source = readFileSync(new URL("../notify/opencode/hypr-agent-bell/tui.js", import.meta.url), "utf8");
  const listeners = new Map();
  const bells = [];
  const context = {
    Plugin: { define: (definition) => definition },
    appendFileSync: (_path, value) => {
      if (options.unavailable) throw new Error("No terminal");
      bells.push(value);
    },
  };
  runInNewContext(source.replace(/^import .*$/gm, "").replace("export default", "globalThis.plugin ="), context);

  const stop = context.plugin.setup({
    data: {
      on(name, listener) {
        listeners.set(name, listener);
        return () => listeners.delete(name);
      },
      session: { root: (sessionID) => sessionID.split(":")[0] },
    },
    ui: {
      router: { current: () => ({ type: "session", sessionID: "local" }) },
      tabs: { enabled: () => Boolean(options.tabs), list: () => options.tabs ?? [] },
    },
  });
  return { listeners, bells, stop };
}
