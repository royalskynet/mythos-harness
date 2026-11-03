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
    env: { ...process.env, MYTHOS_DIR: MYTHOS, MYTHOS_TRANSCRIPT_DIR: TMP },
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

test('主 session：背景 dispatcher 放行；前景、非 dispatcher、未指定類型都擋', () => {
  assert.equal(decision(pre('Agent', { subagent_type: 'dispatcher', prompt: 'x' })), null)
  assert.equal(decision(pre('Agent', { subagent_type: 'dispatcher', prompt: 'x', run_in_background: true })), null)
  assert.equal(decision(pre('Agent', { subagent_type: 'dispatcher', prompt: 'x', run_in_background: false })), 'deny')
  assert.equal(decision(pre('Agent', { subagent_type: 'general-purpose', prompt: 'x' })), 'deny')
  assert.equal(decision(pre('Agent', { prompt: 'x' })), 'deny')
})

for (const tool of ['mcp__telegram__reply', 'mcp__telegram__react', 'mcp__telegram__download_attachment', 'ToolSearch', 'TaskStop']) {
  test(`主 session 放行：${tool}`, () => {
    assert.equal(decision(pre(tool, {})), null)
  })
}

// 11-03 Codex 審計：舊閘只管 5 種工具，Read／Grep／WebFetch／TaskOutput 等照放，主 session 仍能自己忙
for (const [tool, input] of [
  ['Bash', { command: 'bin/dispatch /tmp/a-task.md /tmp mid' }],
  ['Bash', { command: 'echo hi < /tmp/fifo' }],
  ['Bash', { command: 'DCQ_BIN=/tmp/worker bin/dispatch /tmp/a-task.md /tmp mid' }],
  ['Bash', { command: 'remind add "+30m" "看 x"' }],
  ['Write', { file_path: '/tmp/dc-worker/a-task.md' }],
  ['Write', { file_path: '/etc/wo/x' }],
  ['Edit', { file_path: path.join(MYTHOS, 'state/x.md') }],
  ['Read', { file_path: '/tmp/x' }],
  ['Grep', { pattern: 'x' }],
  ['Glob', { pattern: '*' }],
  ['WebFetch', { url: 'https://example.com' }],
  ['WebSearch', { query: 'x' }],
  ['TaskOutput', { task_id: 'x' }],
  ['Skill', { skill: 'x' }],
  ['mcp__jev_gate__jev_evaluate', {}],
  ['', {}],
]) {
  test(`主 session 擋：${tool || '(空)'} ${JSON.stringify(input).slice(0, 40)}`, () => {
    assert.equal(decision(pre(tool, input)), 'deny')
  })
}

test('11-03：使用者訊息含 #手動 不解鎖主 session 動手', () => {
  const tp = transcript('#手動 幫我改 launchd')
  assert.equal(decision(pre('Write', { file_path: '~/dev/x.js' }, tp)), 'deny')
  assert.equal(decision(pre('Bash', { command: 'launchctl list' }, tp)), 'deny')
})

test('fail-closed：payload 不是 JSON 時擋', () => {
  const out = execFileSync(process.execPath, [GATE, 'pre'], { input: 'not json', env: { ...process.env, MYTHOS_DIR: MYTHOS, MYTHOS_TRANSCRIPT_DIR: TMP } }).toString()
  assert.equal(decision(out), 'deny')
})

test('子代理不能直接回使用者 Telegram', () => {
  const extra = { agent_id: 'a1', agent_type: 'dispatcher' }
  assert.equal(decision(pre('mcp__telegram__reply', { text: 'x' }, undefined, extra)), 'deny')
  assert.equal(decision(pre('mcp__telegram__download_attachment', {}, undefined, extra)), null)
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
  assert.equal(decision(pre('Agent', { subagent_type: 'dispatcher', prompt: 'x' }, tp)), null)
  assert.equal(decision(pre('Bash', { command: 'ls' }, tp)), 'deny')
})

test('fail 模式是 no-op', () => {
  assert.equal(run('fail', { tool_name: 'Bash', tool_input: { command: 'wo-verify /tmp/x.md' }, transcript_path: '' }).trim(), '')
})

test('同目錄的非 Mythos session（deep，transcript 在別處）不被當 Router 擋', () => {
  const other = path.join(os.tmpdir(), `deep-${process.pid}.jsonl`)
  fs.writeFileSync(other, JSON.stringify({ type: 'user', message: { role: 'user', content: 'x' } }) + '\n')
  try {
    assert.equal(decision(pre('Bash', { command: 'git status' }, other)), null)
    assert.equal(decision(pre('Bash', { command: 'git status' })), 'deny')  // Mythos 本人照擋
    assert.equal(decision(pre('Bash', { command: 'git status' }, '')), 'deny')  // 沒路徑 fail-closed
  } finally { fs.rmSync(other, { force: true }) }
})
