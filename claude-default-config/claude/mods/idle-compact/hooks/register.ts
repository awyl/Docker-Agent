import type { Register, Timer } from 'claude-code'

// Subscription Claude Code caches prompts for 1h; compact 5 min before that so
// the summary is built from a warm cache and the next prompt re-caches only it.
const IDLE_MS = 55 * 60 * 1000
// Below this the context is cheap to re-cache anyway; leave it whole.
const MIN_PERCENT = 10

export const register: Register = on => {
  let timer: Timer | undefined
  // Only a turn the user started arms the timer, so the compaction's own
  // turn (if it raises one) never re-arms it into an hourly loop.
  let userTurn = false

  on('prompt.submit', ($, e, next) => {
    timer?.cancel()
    timer = undefined
    userTurn = true
    return next(e)
  }).catch(($, e, next) => next(e)) // never hold a prompt back over this mod

  on('turn.complete', ($, e, next) => {
    if (e.agentId === undefined && userTurn) {
      userTurn = false
      timer?.cancel()
      timer = $.clock.after(IDLE_MS, async () => {
        timer = undefined
        const { context } = await $.session.usage()
        if ((context.percent ?? 0) < MIN_PERCENT) return
        $.ui.toast('idle-compact: compacting before the prompt cache expires')
        await $.session.compact()
      })
    }
    return next(e)
  })
}
