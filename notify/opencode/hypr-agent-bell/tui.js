// Ring the terminal bell when opencode needs attention. When its Alacritty window is unfocused, the bell
// becomes a Hyprland "urgent" mark on that window's workspace, which the Omarchy workspace widget
// highlights.
// Mirrors the claude-code Stop hook (~/.local/bin/hypr-agent-bell). Writing BEL straight to the controlling
// terminal is the same mechanism, expressed without a shell-out.
import { appendFileSync } from "node:fs"
import { Plugin } from "@opencode/plugin/tui"

export default Plugin.define({
  id: "hypr-agent-bell",
  /** Ring for attention events in this terminal and unsubscribe when the plugin unloads. */
  setup(context) {
    const stops = [
      context.data.on("permission.asked", (event) => ringForSession(context, event.data.sessionID)),
      context.data.on("form.created", (event) => ringForSession(context, event.data.form.sessionID)),
      context.data.on("session.execution.failed", (event) => ringForSession(context, event.data.sessionID)),
      context.data.on("session.execution.succeeded", (event) => ringForSession(context, event.data.sessionID)),
    ]

    return () => stops.forEach((stop) => stop())
  },
})

/** Ring only for the current session family or an open tab, not sessions in other terminals. */
function ringForSession(context, sessionID) {
  // V2 shares events across clients. Include child sessions, but do not mark unrelated windows urgent.
  const rootID = context.data.session.root(sessionID)
  const route = context.ui.router.current()
  const current = route.type === "session" && context.data.session.root(route.sessionID) === rootID
  const openTab = context.ui.tabs.enabled() && context.ui.tabs.list().some((tab) => tab.sessionID === rootID)
  if (!current && !openTab) return

  try {
    appendFileSync("/dev/tty", "\x07") // BEL
  } catch (_) {
    // never let a notification failure disrupt the session
  }
}
