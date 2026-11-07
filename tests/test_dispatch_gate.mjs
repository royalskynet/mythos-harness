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
const WORKER_T = path.join(os.tmpdir(), `dispatch-gate-worker-${process.pid}`)
const EXEMPT_F = path.join(TMP, 'cap-exempt.txt')
fs.writeFileSync(EXEMPT_F, '# 測試用\n夜班顧問請求\n')
fs.mkdirSync(WORKER_T, { recursive: true })
process.on('exit', () => fs.rmSync(WORKER_T, { recursive: true, force: true }))
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
    env: { ...process.env, MYTHOS_DIR: MYTHOS, MYTHOS_TRANSCRIPT_DIR: TMP, MYTHOS_WORKER_TRANSCRIPT_DIR: WORKER_T, MYTHOS_SELF_CAP: '', MYTHOS_CAP_EXEMPT_FILE: EXEMPT_F },
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
  assert.equal(decision(pre('Agent', { subagent_type: 'dispatcher', prompt: 'x' })), 'allow')
  assert.equal(decision(pre('Agent', { subagent_type: 'dispatcher', prompt: 'x', run_in_background: true })), 'allow')
  assert.equal(decision(pre('Agent', { subagent_type: 'dispatcher', prompt: 'x', run_in_background: false })), 'deny')
  assert.equal(decision(pre('Agent', { subagent_type: 'general-purpose', prompt: 'x' })), 'deny')
  assert.equal(decision(pre('Agent', { prompt: 'x' })), 'deny')
})

for (const tool of ['mcp__telegram__reply', 'mcp__telegram__react', 'mcp__telegram__edit_message', 'ToolSearch', 'TaskStop']) {
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
  // 11-04 Codex 二審：Telegram 只放精確三個，附件下載交子代理、未知 mcp__telegram__* 一律擋
  ['mcp__telegram__download_attachment', { file_id: 'x' }],
  ['mcp__telegram__foo', {}],
  ['', {}],
]) {
  test(`主 session 擋：${tool || '(空)'} ${JSON.stringify(input).slice(0, 40)}`, () => {
    assert.equal(decision(pre(tool, input)), 'deny')
  })
}

test('11-03：使用者訊息含 #手動 不解鎖主 session 動手', () => {
  const tp = transcript('#手動 幫我改 launchd')
  assert.equal(decision(pre('Write', { file_path: path.join(os.homedir(), 'dev/x.js') }, tp)), 'deny')
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
  assert.equal(decision(pre('Write', { file_path: path.join(os.homedir(), 'dev/x.js') }, undefined, extra)), null)
  assert.equal(decision(pre('Bash', { command: 'bash tests/test_dispatch_deep.sh' }, undefined, extra)), null)
  assert.equal(decision(pre('Agent', { prompt: 'x', run_in_background: false }, undefined, extra)), 'allow')  // 放行但改寫成 haiku
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
  assert.equal(decision(pre('Agent', { subagent_type: 'dispatcher', prompt: 'x' }, tp)), 'allow')
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

test('11-04：Router reply 不准請示「回好我就派」，問資訊與一般結果放行', () => {
  for (const t of ['我建議全做。要的話回「好」，我一併派出去。', '要做回「好」我派 deep', '要不要我順便載入 watchdog？', '我們得決定改文件還是恢復排程'])
    assert.equal(decision(pre('mcp__telegram__reply', { text: t })), 'deny', t)
  for (const t of ['已派 dispatcher：載入 watchdog、開新票', '你要幾點提醒？', '好，已處理', '完成：測試 32/32 pass'])
    assert.equal(decision(pre('mcp__telegram__reply', { text: t })), null, t)
})

// 11-06 自做上限：子代理／worker 連做 ≥20 次沒派工就擋，逼寫工單交 O
function selfLog(prompt, n, { dispatchAt = -1 } = {}) {
  const lines = [{ type: 'user', message: { role: 'user', content: prompt } }]
  for (let i = 0; i < n; i++) {
    const command = i === dispatchAt ? 'DISPATCH_THREAD=t1 bin/dispatch state/workorders/a.md /tmp mid' : `ls ${i}`
    lines.push({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Bash', input: { command } }] } })
  }
  return lines.map(l => JSON.stringify(l)).join('\n') + '\n'
}
function subagent(prompt, n, opt) {
  const main = transcript('幫我看一下')
  const dir = path.join(path.dirname(main), path.basename(main, '.jsonl'), 'subagents')
  fs.mkdirSync(dir, { recursive: true })
  fs.writeFileSync(path.join(dir, 'agent-a9.jsonl'), selfLog(prompt, n, opt))
  return main
}
const SUB = { agent_id: 'a9', agent_type: 'dispatcher' }

test('自做上限：子代理 19 次放行、20 次擋', () => {
  assert.equal(decision(pre('Bash', { command: 'ls' }, subagent('thread=x 查 log', 19), SUB)), null)
  assert.equal(decision(pre('Bash', { command: 'ls' }, subagent('thread=x 查 log', 20), SUB)), 'deny')
  assert.equal(decision(pre('Read', { file_path: '/tmp/a' }, subagent('thread=x 查 log', 30), SUB)), 'deny')
})

test('自做上限：超過後寫工單與派工照放；派工後重算（不是派一次就無限）', () => {
  const tp = subagent('thread=x 查 log', 25)
  assert.equal(decision(pre('Write', { file_path: path.join(MYTHOS, 'state/workorders/a.md') }, tp, SUB)), null)
  assert.equal(decision(pre('Bash', { command: 'DISPATCH_THREAD=x bin/dispatch state/workorders/a.md /tmp mid' }, tp, SUB)), null)
  assert.equal(decision(pre('Write', { file_path: '/tmp/other.md' }, tp, SUB)), 'deny')
  assert.equal(decision(pre('Bash', { command: 'ls' }, subagent('thread=x 查 log', 23, { dispatchAt: 3 }), SUB)), null)
  assert.equal(decision(pre('Bash', { command: 'ls' }, subagent('thread=x 查 log', 40, { dispatchAt: 3 }), SUB)), 'deny')
})

test('11-07 難度上限：tier=mid|hard 時 haiku 只能自做 8 次，交規劃單照放且重算；easy 仍是 20', () => {
  assert.equal(decision(pre('Bash', { command: 'ls' }, subagent('thread=x\ntier=hard（本機判定）\n重構', 7), SUB)), null)
  assert.equal(decision(pre('Bash', { command: 'ls' }, subagent('thread=x\ntier=hard（本機判定）\n重構', 8), SUB)), 'deny')
  assert.equal(decision(pre('Bash', { command: 'ls' }, subagent('thread=x\ntier=mid\n改', 8), SUB)), 'deny')
  assert.equal(decision(pre('Bash', { command: 'ls' }, subagent('thread=x\ntier=easy\n查', 19), SUB)), null)
  const tp = subagent('thread=x\ntier=hard\n重構', 12)
  assert.equal(decision(pre('Bash', { command: "printf '%s\\n' '重構 X' | DISPATCH_THREAD=x /m/bin/plan-ticket hard /r" }, tp, SUB)), null)
})

test('自做上限豁免：bg-hard、cap-exempt.txt 字串；#手動 不豁免（Router 也打得出來）', () => {
  for (const p of ['第一步：git -C /r worktree add -b bg-hard/x /tmp/x', '[夜班顧問請求 2026-11-06] DIR=/x'])
    assert.equal(decision(pre('Bash', { command: 'ls' }, subagent(p, 50), SUB)), null, p)
  assert.equal(decision(pre('Bash', { command: 'ls' }, subagent('#手動 自己查完', 50), SUB)), 'deny')
})

test('自做上限：bg worker transcript 也計；範圍外（deep）不計', () => {
  const w = path.join(WORKER_T, 'w1.jsonl')
  fs.writeFileSync(w, selfLog('查 log', 20))
  assert.equal(decision(pre('Bash', { command: 'ls' }, w)), 'deny')
  const other = path.join(os.tmpdir(), `deep-cap-${process.pid}.jsonl`)
  fs.writeFileSync(other, selfLog('查 log', 50))
  try { assert.equal(decision(pre('Bash', { command: 'ls' }, other)), null) } finally { fs.rmSync(other, { force: true }) }
})

test('自做上限：子代理自己的 transcript 找不到就不計', () => {
  assert.equal(decision(pre('Bash', { command: 'ls' }, undefined, { agent_id: 'nope' })), null)
})

// 11-06 反向把關：累計不因續派歸零；真缺輪數走 [加輪請求] → 使用者回「加輪」→ Router 送 #加輪 +N
function segLog(segs) {
  const lines = []
  for (const x of segs) {
    if (x === 'D') lines.push({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Bash', input: { command: 'bin/dispatch state/workorders/a.md /tmp mid' } }] } })
    else if (typeof x === 'string') lines.push({ type: 'user', message: { role: 'user', content: x } })
    else for (let i = 0; i < x; i++) lines.push({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Read', input: { file_path: `/tmp/${i}` } }] } })
  }
  return lines.map(l => JSON.stringify(l)).join('\n') + '\n'
}
function subSegs(segs) {
  const main = transcript('幫我看一下')
  const dir = path.join(path.dirname(main), path.basename(main, '.jsonl'), 'subagents')
  fs.mkdirSync(dir, { recursive: true })
  fs.writeFileSync(path.join(dir, 'agent-a9.jsonl'), segLog(segs))
  return main
}
const ls = tp => decision(pre('Bash', { command: 'ls' }, tp, SUB))

test('加輪：續派訊息不歸零（舊漏洞：回「請續派」就繞過）', () => {
  assert.equal(ls(subSegs(['查 log', 15, '繼續', 10])), 'deny')
})

test('加輪：#加輪 +N 加額度，預設 20，單次最多 40', () => {
  assert.equal(ls(subSegs(['查 log', 20, '#加輪 +10', 9])), null)
  assert.equal(ls(subSegs(['查 log', 20, '#加輪 +10', 10])), 'deny')
  assert.equal(ls(subSegs(['查 log', 20, '#加輪', 19])), null)
  assert.equal(ls(subSegs(['查 log', 20, '#加輪 +999', 39])), null)
  assert.equal(ls(subSegs(['查 log', 20, '#加輪 +999', 40])), 'deny')
})

test('加輪：派工後重算；cap-exempt 豁免只認第一則任務', () => {
  assert.equal(ls(subSegs(['查 log', 18, 'D', 19])), null)
  assert.equal(ls(subSegs(['查 log', 18, 'D', 20])), 'deny')
  assert.equal(ls(subSegs(['查 log', 20, '[夜班顧問請求 x]', 5])), 'deny')
})

test('加輪：deny 訊息教子代理寫 [加輪請求]', () => {
  const out = pre('Bash', { command: 'ls' }, subSegs(['查 log', 20]), SUB)
  assert.match(JSON.parse(out).hookSpecificOutput.permissionDecisionReason, /\[加輪請求\]/)
})

function routerTx(...msgs) {
  const p = path.join(TMP, `r${++seq}.jsonl`)
  fs.writeFileSync(p, msgs.map(([kind, text]) => JSON.stringify(kind === 'channel'
    ? { type: 'user', isMeta: true, origin: { kind: 'channel' }, message: { content: text } }
    : { type: 'user', message: { content: text } })).join('\n') + '\n')
  return p
}

test('加輪：Router 送 #加輪 要使用者 Telegram 回過「加輪」，自己批不了', () => {
  const send = { to: 'a9', message: '#加輪 +20 繼續' }
  assert.equal(decision(pre('SendMessage', send, routerTx(['channel', '幫我查 log']))), 'deny')
  assert.equal(decision(pre('SendMessage', send, routerTx(['channel', '加輪']))), null)
  // [派工回報]／子代理結果不是使用者授權
  assert.equal(decision(pre('SendMessage', send, routerTx(['channel', '查 log'], ['tmux', '[派工回報] 加輪']))), 'deny')
  assert.equal(decision(pre('Write', { file_path: path.join(MYTHOS, 'state/bg/t1.md'), content: '#加輪 +20' }, routerTx(['channel', '好']))), 'deny')
  assert.equal(decision(pre('SendMessage', { to: 'a9', message: '繼續' }, routerTx(['channel', '好']))), null)
})

test('快查線：Router 可跑 bin/quick <絕對路徑> \'<問題>\'，夾帶指令或雙引號都擋', () => {
  const tp = routerTx(['channel', '查一下'])
  const bash = (command) => decision(pre('Bash', { command }, tp))
  assert.equal(bash("bin/quick /home/u/repo 'bin 底下有幾個 gate 檔；含 $HOME 也只是字'"), 'allow')
  assert.equal(bash("bin/quick --push /home/u/repo 'q'"), 'allow')
  assert.equal(bash("bin/quick /home/u/repo 'q'; rm -rf /tmp/x"), 'deny')
  assert.equal(bash('bin/quick /home/u/repo "$(id)"'), 'deny')
  assert.equal(bash("bin/quick relative/path 'q'"), 'deny')
  assert.equal(bash("bin/quick /x 'a' 'b'"), 'deny')
})

test('記憶快查：Router 可跑 bin/recall \'<關鍵字>\' 與 --obs/--fix <數字>，其餘擋', () => {
  const tp = routerTx(['channel', '之前怎麼定的'])
  const bash = (command) => decision(pre('Bash', { command }, tp))
  assert.equal(bash("bin/recall '訂閱 花錢' --ask '訂閱算不算花錢'"), 'allow')
  assert.equal(bash("bin/recall '訂閱 花錢'"), 'deny')
  assert.equal(bash("bin/recall 'a' --ask 'b'; id"), 'deny')
  assert.equal(bash('bin/recall --obs 9457'), null)
  assert.equal(bash('bin/recall --fix 11774'), null)
  assert.equal(bash("bin/recall 'q'; rm -rf /tmp/x"), 'deny')
  assert.equal(bash('bin/recall "$(id)"'), 'deny')
  assert.equal(bash('bin/recall --obs 1; id'), 'deny')
  assert.equal(bash('bin/recall --selftest'), 'deny')
})

test('秒回：quick／recall 被改寫成背景跑，quick 強制 --push，其餘欄位保留', () => {
  const tp = routerTx(['channel', '查一下'])
  const upd = (command) => JSON.parse(pre('Bash', { command, description: 'd' }, tp)).hookSpecificOutput.updatedInput
  assert.deepEqual(upd("bin/quick /r 'q'"), { command: "bin/quick --push /r 'q'", description: 'd', run_in_background: true })
  assert.deepEqual(upd("bin/quick --push /r 'q'"), { command: "bin/quick --push /r 'q'", description: 'd', run_in_background: true })
  assert.deepEqual(upd("bin/recall 'k' --ask 'q'"), { command: "bin/recall 'k' --ask 'q'", description: 'd', run_in_background: true })
  assert.equal(pre('Bash', { command: 'bin/recall --fix 1' }, tp).trim(), '')
})

test('秒回派工：bin/dispatch-bg --from-chat <thread> 放行並補 --transcript；夾帶指令擋', () => {
  const tp = routerTx(['channel', '幫我修 log'])
  const upd = (command) => JSON.parse(pre('Bash', { command }, tp)).hookSpecificOutput
  assert.equal(upd('bin/dispatch-bg --from-chat t-log').updatedInput.command, `bin/dispatch-bg --from-chat t-log --transcript '${tp}'`)
  assert.equal(upd('bin/dispatch-bg --from-chat t-log').updatedInput.run_in_background, true, '啟動 worker 不佔 Router 回合')
  assert.equal(upd("bin/dispatch-bg --thread t-log --from-chat t-log --note '接續昨天'").permissionDecision, 'allow')
  assert.equal(upd('bin/dispatch-bg --from-chat t-log; id').permissionDecision, 'deny')
  assert.equal(upd("bin/dispatch-bg --from-chat t-log --transcript '/etc/passwd'").permissionDecision, 'deny')
})

test('子代理只用 haiku：主 session 與 worker 派的 Agent 一律改寫成 haiku（指定 opus 也一樣）', () => {
  const upd = (input, tp, extra) => JSON.parse(pre('Agent', input, tp, extra)).hookSpecificOutput.updatedInput
  assert.deepEqual(upd({ subagent_type: 'dispatcher', prompt: 'x', model: 'opus' }), { subagent_type: 'dispatcher', prompt: 'x', model: 'haiku', run_in_background: true })
  const w = upd({ subagent_type: 'general-purpose', prompt: 'y', model: 'sonnet' }, undefined, { agent_id: 'a1', agent_type: 'dispatcher' })
  assert.equal(w.model, 'haiku')
  assert.equal(w.prompt, 'y')
})
