#!/usr/bin/env bash
# Checks claude-default-config/claude/statusline.mjs formats both lines and
# drops what it has no figure for. Git is stubbed; no Claude needed.
#
#   ./test/statusline.sh
set -euo pipefail
REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node --input-type=module -e "
import assert from 'node:assert/strict'
import { render, left } from '$REPO/claude-default-config/claude/statusline.mjs'
const plain = s => s.replace(/\x1b\[[0-9;]*m/g, '')
const gitStub = (cwd, cmd) => (cmd === 'branch' ? 'main' : ' 3 files changed, 12 insertions(+), 3 deletions(-)')
const full = {
  model: { display_name: 'Opus 5.5' },
  context_window: { total_input_tokens: 36937, used_percentage: 4 },
  rate_limits: { five_hour: { used_percentage: 28, resets_at: 1000 + 37 * 60 }, seven_day: { used_percentage: 15, resets_at: 1000 + 3 * 86400 + 9 * 3600 } },
}
assert.equal(plain(render(full, 1000, gitStub)), 'Opus 5.5 | 37k - 4% | main | +12 -3\n5h 28% 37m | 7d 15% 3d9h')
assert.equal(plain(render({ model: { id: 'x' } }, 0, () => undefined)), 'x | no git')
assert.equal(left(-5), '0m')
console.log('statusline: ok')
"
