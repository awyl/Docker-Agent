// Claude Code status line: reads the statusLine JSON on stdin, prints two lines.
//   Opus 5.5 | 37k - 4% | main | +8 -135
//   5h 28% 37m | 7d 15% 3d9h
// No dependencies: Node stdlib + git. Wired in settings.json `statusLine`.
import { execFileSync } from 'node:child_process'

const c = (code, s) => `\x1b[${code}m${s}\x1b[0m`
const SEP = c(2, ' | ')
const k = n => (n >= 1000 ? `${Math.round(n / 1000)}k` : `${n}`)

export const left = sec => {
  const m = Math.max(0, Math.round(sec / 60))
  const d = Math.floor(m / 1440), h = Math.floor((m % 1440) / 60)
  return d ? `${d}d${h}h` : h ? `${h}h${m % 60}m` : `${m}m`
}

const git = (cwd, ...args) => {
  try {
    return execFileSync('git', ['-C', cwd, ...args], { encoding: 'utf8', timeout: 2000, stdio: ['ignore', 'pipe', 'ignore'] }).trim()
  } catch {
    return undefined
  }
}

export function render(j, nowSec, run = git) {
  const cw = j.context_window ?? {}
  const cwd = j.workspace?.current_dir ?? j.cwd ?? '.'
  const branch = run(cwd, 'branch', '--show-current')
  const stat = branch === undefined ? '' : run(cwd, 'diff', '--shortstat', 'HEAD') ?? ''
  const n = re => stat.match(re)?.[1] ?? '0'
  const top = [
    c(36, j.model?.display_name ?? j.model?.id ?? '?'),
    cw.total_input_tokens ? c(2, `${k(cw.total_input_tokens)} - ${cw.used_percentage ?? 0}%`) : '',
    c(35, branch === undefined ? 'no git' : branch || 'detached'),
    branch === undefined ? '' : c(33, `+${n(/(\d+) insertion/)} -${n(/(\d+) deletion/)}`),
  ]
  const lim = (label, r) => r && `${label} ${Math.round(r.used_percentage)}%${r.resets_at ? ` ${left(r.resets_at - nowSec)}` : ''}`
  const rl = j.rate_limits ?? {}
  const bottom = [lim('5h', rl.five_hour), lim('7d', rl.seven_day)]
  return [top, bottom].map(l => l.filter(Boolean).join(SEP)).filter(Boolean).join('\n')
}

if (import.meta.url === `file://${process.argv[1]}`) {
  let input = ''
  for await (const chunk of process.stdin) input += chunk
  console.log(render(JSON.parse(input || '{}'), Date.now() / 1000))
}
