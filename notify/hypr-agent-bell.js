// Ring the terminal bell when an opencode session goes idle — i.e. the agent finished its turn and is
// ready for feedback. When opencode's Alacritty window is unfocused, the bell becomes a Hyprland "urgent"
// mark on that window's workspace, which waybar highlights (see ~/.config/waybar/style.css .urgent).
// Mirrors the claude-code Stop hook (~/.local/bin/hypr-agent-bell). Writing BEL straight to the controlling
// terminal is the same mechanism, expressed without a shell-out.
import { appendFileSync } from "node:fs"

export async function HyprAgentBell() {
  return {
    async event(input) {
      if (input.event?.type !== "session.idle") return
      try {
        appendFileSync("/dev/tty", "\x07") // BEL
      } catch (_) {
        // never let a notification failure disrupt the session
      }
    },
  }
}
