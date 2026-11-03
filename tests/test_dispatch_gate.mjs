// Why: Mythos 主 session 只聊天派工（11-03）；這個 hook 判錯方向就是主 session 自己動手佔住對話，或把派工鎖死。
// 全部用暫存 MYTHOS_DIR＋假 transcript，不碰真的 state／~/.dcq／tmux。
import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const GATE = path.join(ROOT, 'bin/dispatch-gate.mjs')
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'dispatch-gate-test-'))
const MYTHOS = path.join(TMP, 'mythos')
fs.mkdirSync(path.join(MYTHOS, 'state'), { recursive: true })
process.on('exit', () => fs.rmSync(TMP, { recursive: true, force: true }))

let seq = 0
function transcript(text) {
  const p = path.join(TMP, `t${++seq}.jsonl`)
  fs.writeFileSync(p, JSON.stringify({ type: 'user', message: { role: 'user', content: text } }) + '\n')
  return p
}

function run(mode, payload) {
  return execFileSync(process.execPath, [GATE, mode], {
    input: JSON.stringify(payload),
    env: { ...process.env, MYTHOS_DIR: MYTHOS },
  }).toString()
}

function pre(tool, input, tp, extra = {}) {
  return run('pre', { tool_name: tool, tool_input: input, transcript_path: tp ?? transcript('幫我看一下'), session_id: 'test', ...extra })
}

function decision(out) {
  const s = out.trim()
  return s ? JSON.parse(s).hookSpecificOutput.permissionDecision : null
}

const PIN = '/Users/x/.claude/delegate-guard/p-123.sh'

test('主 session：背景 Agent 放行、前景 Agent 擋', () => {
  assert.equal(decision(pre('Agent', { subagent_type: 'dispatcher', prompt: 'x' })), null)
  assert.equal(decision(pre('Agent', { subagent_type: 'dispatcher', prompt: 'x', run_in_background: true })), null)
  assert.equal(decision(pre('Agent', { subagent_type: 'dispatcher', prompt: 'x', run_in_background: false })), 'deny')
})

test('主 session：Write 只准 /tmp、state、工單路徑', () => {
  assert.equal(decision(pre('Write', { file_path: '~/dev/x.js' })), 'deny')
  assert.equal(decision(pre('Edit', { file_path: path.join(MYTHOS, 'bin/dispatch') })), 'deny')
  assert.equal(decision(pre('Write', { file_path: '/tmp/dc-worker/a-task.md' })), null)
  assert.equal(decision(pre('Write', { file_path: path.join(MYTHOS, 'state/workorders/x.md') })), null)
})

for (const command of [
  'bin/dispatch /tmp/a-task.md /tmp mid',
  `${MYTHOS}/bin/dispatch-retry deep-1-x "補充"`,
  'bin/dispatch-cancel deep-1-x',
  'remind add "+30m" "看 x"',
  'date && echo hi',
  'FOO=1 bin/dispatch /tmp/a-task.md /tmp hard',
]) {
  test(`主 session Bash 放行：${command.slice(0, 40)}`, () => {
    assert.equal(decision(pre('Bash', { command })), null)
  })
}

for (const command of [
  // 11-03 使用者 Telegram 實例：主 session 自己跑測試，佔住對話，「哈囉」沒人回
  'bash tests/test_dispatch_deep.sh',
  'ls -la',
  'rg -n x /tmp',
  'wo-verify /tmp/a.md | tail -5',
  'git status',
  'cd /tmp && bin/dispatch /tmp/a-task.md /tmp mid',
  '/tmp/evil/dispatch x',
  'bin/../../tmp/dispatch x',
  'echo "$(rm -rf /tmp/z)"',
  'echo `touch /tmp/v`',
  'echo hi > ~/dev/a',
  'echo ok & touch /tmp/v',
  "e'ch'o x; rm -rf /tmp/z",
]) {
  test(`主 session Bash 擋：${command.slice(0, 40)}`, () => {
    assert.equal(decision(pre('Bash', { command })), 'deny')
  })
}

test('11-03：使用者訊息含 #手動 不解鎖主 session 動手', () => {
  const tp = transcript('#手動 幫我改 launchd')
  assert.equal(decision(pre('Write', { file_path: '~/dev/x.js' }, tp)), 'deny')
  assert.equal(decision(pre('Bash', { command: 'launchctl list' }, tp)), 'deny')
})

test('子代理（agent_id）：任意 Write／Bash 放行', () => {
  const extra = { agent_id: 'a1', agent_type: 'dispatcher' }
  assert.equal(decision(pre('Write', { file_path: '~/dev/x.js' }, undefined, extra)), null)
  assert.equal(decision(pre('Bash', { command: 'bash tests/test_dispatch_deep.sh' }, undefined, extra)), null)
  assert.equal(decision(pre('Agent', { prompt: 'x', run_in_background: false }, undefined, extra)), null)
})

test('pinGuard：主 session 與子代理都擋，#手動 才解，唯讀放行', () => {
  const extra = { agent_id: 'a1' }
  assert.equal(decision(pre('Write', { file_path: PIN }, undefined, extra)), 'deny')
  assert.equal(decision(pre('Bash', { command: `sed -i s/a/b/ ${PIN}` }, undefined, extra)), 'deny')
  assert.equal(decision(pre('Bash', { command: `cat ${PIN}` }, undefined, extra)), null)
  assert.equal(decision(pre('Write', { file_path: PIN }, transcript('#手動 改憑證'), extra)), null)
})

test('transcript 不存在時：Agent 照放、主 session 動手照擋', () => {
  const tp = path.join(TMP, 'missing.jsonl')
  assert.equal(decision(pre('Agent', { prompt: 'x' }, tp)), null)
  assert.equal(decision(pre('Bash', { command: 'ls' }, tp)), 'deny')
})

test('fail 模式是 no-op', () => {
  assert.equal(run('fail', { tool_name: 'Bash', tool_input: { command: 'wo-verify /tmp/x.md' }, transcript_path: '' }).trim(), '')
})
