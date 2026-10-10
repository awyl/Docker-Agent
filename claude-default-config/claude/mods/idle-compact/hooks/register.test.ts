import { expect, mock, test } from 'claude-code/testing'

const MIN = 60 * 1000

test('compacts once after 55 idle minutes, not again until the next prompt', async ($, on) => {
  const clock = mock.clock(on)
  let compactions = 0
  on('session.compact', () => {
    compactions += 1
    return { skip: 'counted' }
  })
  on('ui.toast', () => ({ value: undefined }))
  on('session.usage', () => ({ value: { startedAt: 0, context: { percent: 40 } } }))
  on('prompt.submit', ($, e) => ({ text: e.text }))
  on('turn.complete', () => ({ text: '' }))

  const turn = { answer: '', durationMs: 1, isAborted: false, turnId: 't', reason: 'answer' } as const

  await $.prompt.submit({ text: 'hi' })
  await $.turn.complete(turn)
  await clock.advance(54 * MIN)
  expect(compactions).toBe(0)
  await clock.advance(1 * MIN)
  expect(compactions).toBe(1)

  await $.turn.complete(turn) // a turn with no prompt (the compaction's) never re-arms
  await clock.advance(120 * MIN)
  expect(compactions).toBe(1)

  await $.prompt.submit({ text: 'again' })
  await $.turn.complete(turn)
  await clock.advance(30 * MIN)
  await $.prompt.submit({ text: 'still here' }) // activity cancels the timer
  await clock.advance(30 * MIN)
  expect(compactions).toBe(1)
})
