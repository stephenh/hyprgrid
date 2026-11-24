import { Plugin } from "@opencode/plugin"

// The server entrypoint makes the adjacent TUI plugin discoverable. The V2 background service has no
// controlling terminal, so only tui.js rings the bell.
export default Plugin.define({
  id: "hypr-agent-bell",
  setup() {},
})
