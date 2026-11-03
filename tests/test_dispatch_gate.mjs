// Why: Mythos 只能動口；這個 hook 判錯方向就是放它亂改檔或把它鎖死。
// 全部用暫存 MYTHOS_DIR＋假 triage＋假 transcript，不碰真的 state／~/.dcq／tmux。
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
const STATE = path.join(MYTHOS, 'state')
const HANDSON = path.join(STATE, 'dispatch-gate-handson')
const COUNT = path.join(TMP, 'triage-count')
const TRIAGE = path.join(TMP, 'triage')

fs.mkdirSync(STATE, { recursive: true })
fs.writeFileSync(TRIAGE, [
  '#!/bin/sh',
  'printf "run\\n" >> "$TRIAGE_COUNT"',
  'printf "%s\\n" "${TRIAGE_OUT:-mid}"',
].join('\n') + '\n')
fs.chmodSync(TRIAGE, 0o755)

process.on('exit', () => fs.rmSync(TMP, { recursive: true, force: true }))

let seq = 0
function transcript(text) {
  const p = path.join(TMP, `t${++seq}.jsonl`)
  fs.writeFileSync(p, JSON.stringify({ type: 'user', message: { role: 'user', content: text } }) + '\n')
  return p
}

function run(mode, payload, extra = {}) {
  return execFileSync(process.execPath, [GATE, mode], {
    input: JSON.stringify(payload),
    env: {
      ...process.env,
      MYTHOS_DIR: MYTHOS,
      DISPATCH_GATE_TRIAGE: TRIAGE,
      TRIAGE_COUNT: COUNT,
      TRIAGE_OUT: 'mid',
      ...extra,
    },
  }).toString()
}

function pre(tool, input, tp, extra = {}) {
  return run('pre', { tool_name: tool, tool_input: input, transcript_path: tp, session_id: 'test' }, extra)
}

function decision(out) {
  const s = out.trim()
  return s ? JSON.parse(s).hookSpecificOutput.permissionDecision : null
}

function clearHandson() {
  try { fs.unlinkSync(HANDSON) } catch {}
}

function countRuns() {
  try { return fs.readFileSync(COUNT, 'utf8').trim().split('\n').filter(Boolean).length } catch { return 0 }
}

test('easy 時 Write 任意路徑放行', () => {
  clearHandson()
  const out = pre('Write', { file_path: '/Users/51mini/dev/x.js' }, transcript('easy turn'), { TRIAGE_OUT: 'easy' })
  assert.equal(out.trim(), '')
})

test('mid 時 Write 非允許路徑 deny、/tmp 工單放行', () => {
  clearHandson()
  const tp = transcript('mid turn write')
  assert.equal(decision(pre('Write', { file_path: '/Users/51mini/dev/x.js' }, tp, { TRIAGE_OUT: 'mid' })), 'deny')
  assert.equal(pre('Write', { file_path: '/tmp/dc-worker/a-task.md' }, tp).trim(), '')
})

test('mid 時 Bash 白名單與子指令限制', () => {
  clearHandson()
  const tp = transcript('mid turn bash')
  const cases = [
    ['ls -la && dcq status', true],
    ['rm -rf /tmp/x', false],
    ['git push', false],
    ['echo hi > /Users/51mini/dev/a', false],
    ['sed -i s/a/b/ f', false],
    ['FOO=1 dcq add /tmp/a.md /tmp mid', true],
  ]
  for (const [command, ok] of cases) {
    const out = pre('Bash', { command }, tp)
    if (ok) assert.equal(out.trim(), '', command)
    else assert.equal(decision(out), 'deny', command)
  }
})

test('11-03：子代理（agent_id）mid 輪 Write 任意路徑放行、主 session 照擋', () => {
  const tp = transcript('subagent turn')
  assert.equal(decision(pre('Write', { file_path: '/Users/51mini/dev/x.js' }, tp, { TRIAGE_OUT: 'mid' })), 'deny')
  const out = run('pre', { tool_name: 'Write', tool_input: { file_path: '/Users/51mini/dev/x.js' }, transcript_path: tp, agent_id: 'a1', agent_type: 'general-purpose' })
  assert.equal(out.trim(), '')
})

test('同一則使用者訊息第二次呼叫不再跑 triage', () => {
  clearHandson()
  const before = countRuns()
  const tp = transcript('cache turn')
  assert.equal(decision(pre('Write', { file_path: '/Users/51mini/dev/x.js' }, tp, { TRIAGE_OUT: 'mid' })), 'deny')
  const afterFirst = countRuns()
  assert.equal(afterFirst, before + 1)
  assert.equal(decision(pre('Write', { file_path: '/Users/51mini/dev/x.js' }, tp)), 'deny')
  assert.equal(countRuns(), afterFirst)
})

test('transcript 不存在時放行', () => {
  const out = pre('Write', { file_path: '/Users/51mini/dev/x.js' }, path.join(TMP, 'missing.jsonl'))
  assert.equal(out.trim(), '')
})

test('11-03：fail 模式已移除，照收不建 handson 檔', () => {
  clearHandson()
  run('fail', { tool_name: 'Bash', tool_input: { command: 'wo-verify /tmp/x.md' }, transcript_path: '' })
  assert.equal(fs.existsSync(HANDSON), false)
})

test('11-02 補洞：mid 時 node -e／python3 -c／find -delete／curl -o／tmux send-keys deny，cd 放行', () => {
  clearHandson()
  const tp = transcript('mid turn holes')
  for (const command of [
    `node -e "require('fs').writeFileSync('/Users/51mini/dev/a','x')"`,
    `python3 -c "open('/Users/51mini/dev/a','w')"`,
    'find /Users/51mini/dev -name x -delete',
    'curl -s -o /Users/51mini/dev/a https://example.com',
    'tmux -L other send-keys -t s "rm -rf x" Enter',
  ]) assert.equal(decision(pre('Bash', { command }, tp)), 'deny', command)
  assert.equal(pre('Bash', { command: 'cd /tmp && ls && dcq status' }, tp).trim(), '')
})

test('11-02：使用者訊息帶 #手動 本輪解鎖，且不跑 triage', () => {
  clearHandson()
  const before = countRuns()
  const out = pre('Write', { file_path: '/Users/51mini/dev/x.js' }, transcript('#手動 幫我改 launchd'), { TRIAGE_OUT: 'hard' })
  assert.equal(out.trim(), '')
  assert.equal(countRuns(), before)
})

test('11-02 deep：mid 時 dispatch-retry／dispatch-cancel 放行', () => {
  clearHandson()
  const tp = transcript('mid turn deep retry cancel')
  assert.equal(pre('Bash', { command: 'bin/dispatch-retry deep-1-x "補充"' }, tp).trim(), '')
  assert.equal(pre('Bash', { command: 'bin/dispatch-cancel deep-1-x' }, tp).trim(), '')
})


// 引號內的 | ; > 是字面（11-01 gate log 有 13 次唯讀查詢被誤擋）
for (const cmd of [
  'rg -n "slug|SLUG" /Users/51mini/dev/fixindex/fixindex --max-count 40',
  'rg -n "cmd_fi|cmd_auto|\\bfi\\)|auto\\)" /Users/51mini/dev/fixindex/fixindex -m 20',
  "ls -la ~/Library/LaunchAgents | grep -E 'opencode-probe|wiki-m2-cleanup'",
  "launchctl list | grep -E 'opencode-probe|weekly-retro'",
  'launchctl print gui/501/com.coco.weekly-retro',
  'grep "a;b>c" /tmp/x',
  'ls /tmp 2>&1 | head -3',
  "awk -F'\\t' '{print $1}' /tmp/a | sort",
  'echo \'$(literal)\'',
]) {
  test(`mid 唯讀查詢放行：${cmd.slice(0, 40)}`, () => {
    clearHandson()
    assert.equal(decision(pre('Bash', { command: cmd }, transcript('mid turn'))), null)
  })
}
for (const cmd of [
  'grep "x" /tmp/a; rm -rf /Users/51mini/dev',
  'echo "$(rm -rf /tmp/z)|x"',
  'echo "a|b" > /Users/51mini/dev/x',
  "grep 'x' | sh",
  'launchctl unload ~/Library/LaunchAgents/x.plist',
  'launchctl bootout gui/501/x',
  'echo "unterminated | rm x',
  // 11-02 Codex 審計反例
  'echo \\"; touch /Users/51mini/dev/victim; # "',
  'echo "$(touch /Users/51mini/dev/victim)"',
  'echo `touch /Users/51mini/dev/victim`',
  'ls $(touch /Users/51mini/dev/victim)',
  'echo ok & touch /Users/51mini/dev/victim',
  "git 'pu'sh",
  `node -e"require('fs').writeFileSync('/Users/51mini/dev/victim','x')"`,
  `python3 -c"open('/Users/51mini/dev/victim','w')"`,
  `awk 'BEGIN {system("touch /Users/51mini/dev/victim")}'`,
  `awk '{print > "/Users/51mini/dev/victim"}' /tmp/a`,
]) {
  test(`mid 危險指令照擋：${cmd.slice(0, 40)}`, () => {
    clearHandson()
    assert.equal(decision(pre('Bash', { command: cmd }, transcript('mid turn'))), 'deny')
  })
}
