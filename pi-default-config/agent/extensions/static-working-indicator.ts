// Replace pi's animated working spinner with a static dot: less redraw over ssh.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async (_event, ctx) => {
    ctx.ui.setWorkingIndicator({ frames: [ctx.ui.theme.fg("accent", "●")] })
  })
}
