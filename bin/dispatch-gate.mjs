#!/usr/bin/env node
// Mythos 的 PreToolUse hook：主 session（Router）只聊天派工，任何動作交背景子代理，對話不被佔住（11-03 使用者定）。
// 子代理的呼叫帶 agent_id（harness 填、模型偽造不了）→ pinGuard 後放行；難度判斷與派 O／deep 由 dispatcher 子代理做。
// 主 session 整份白名單（11-03 Codex 審計 P0）：只准 Telegram 工具、ToolSearch、TaskStop、背景 dispatcher；Bash／讀寫檔／Web／等待工具一律擋。
// fail-closed：payload 壞或例外一律擋並記 log（Codex 審計：fail-open＝閘一壞主 session 又能自己動手）。
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const MYTHOS = process.env.MYTHOS_DIR || path.dirname(HERE)
const LOGS = path.join(MYTHOS, 'logs')
// 原文 §2.1 Router 不執行任務；§4.1 stop()＝TaskStop；ToolSearch 只載延遲工具的 schema
const MAIN_ALLOW = new Set(['ToolSearch', 'TaskStop'])
// 原文 §2.2 Worker 不直接跟人互動，結果經 Router 轉述
const WORKER_DENY = /^mcp__telegram__(reply|react|edit_message)$/

function log(line) {
  try {
    fs.mkdirSync(LOGS, { recursive: true })
    fs.appendFileSync(path.join(LOGS, 'dispatch-gate.log'), `${new Date().toISOString()} ${line}\n`)
  } catch {}
}

function allow() {
  process.exit(0)
}

function deny(why, reasonOverride) {
  const reason = reasonOverride || `Mythos 主 session 只聊天派工，不自己動手：用 Agent 工具派背景 dispatcher 子代理（subagent_type: "dispatcher"，不設 run_in_background 或設 true），把使用者原話與你知道的脈絡交給它，它會判難度、自己做或派 O／deep；派完立刻 reply 使用者一句「已派 dispatcher」，結束本回合。${why ? `（${why}）` : ''}`
  log(`DENY ${why}`)
  fs.writeSync(1, JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  }))
  process.exit(0)
}

function readPayload() {
  try {
    return JSON.parse(fs.readFileSync(0, 'utf8'))
  } catch (e) {
    log(`FAIL-CLOSED bad hook json: ${e.message}`)
    return null
  }
}

function textOf(content) {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return null
  if (content.some(x => x && x.type === 'tool_result')) return null
  return content.filter(x => x && x.type === 'text').map(x => x.text || '').join('')
}

function lastUserText(transcriptPath) {
  if (!transcriptPath) return null
  let buf
  try {
    const fd = fs.openSync(transcriptPath, 'r')
    const size = fs.fstatSync(fd).size
    const len = Math.min(size, 4 << 20)
    buf = Buffer.alloc(len)
    fs.readSync(fd, buf, 0, len, size - len)
    fs.closeSync(fd)
  } catch {
    return null
  }
  const entries = []
  for (const line of buf.toString('utf8').split('\n')) {
    try { entries.push(JSON.parse(line)) } catch {}
  }
  for (let i = entries.length - 1; i >= 0; i--) {
    const e = entries[i]
    // Telegram channel 訊息被 harness 記成 isMeta:true＋origin.kind=channel（11-03 實測 36/36），
    // 舊版一律跳過 isMeta → #手動 從沒讀到、tier 也拿 [派工回報] 之類的舊文字判
    if (!e || e.type !== 'user' || (e.isMeta && e.origin?.kind !== 'channel')) continue
    const text = textOf(e.message?.content ?? e.content)
    if (typeof text === 'string' && text.trim()) return text
  }
  return null
}

// 派工憑證保護（11-02）：delegate-guard 的 p-*.sh／p-*.md／ledger-*.json 是派工當下的驗收 pin，
// 事後改它＝自己改考卷。不分 tier、不分主 session 或子代理，Write／Edit／非唯讀 Bash 一律擋；只有使用者打 #手動 能解。
const PIN_RE = /delegate-guard\/(p-[^\s'"]*\.(sh|md)|ledger-[^\s'"]*)/
const PIN_READONLY = /^\s*(cat|ls|stat|head|tail|grep|wc|diff|node\s+\S*delegate-guard\/scripts\/verify\.mjs)\b[^;&|><`$]*$/
function pinGuard(tool, input) {
  let hit = false
  if (tool === 'Write' || tool === 'Edit' || tool === 'MultiEdit') hit = PIN_RE.test(String(input.file_path || ''))
  else if (tool === 'Bash') {
    const c = String(input.command || '')
    hit = PIN_RE.test(c) && !PIN_READONLY.test(c)
  }
  if (!hit) return
  log(`DENY pin-guard tool=${tool}`)
  fs.writeSync(1, JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny',
    permissionDecisionReason: '派工憑證（delegate-guard 的 p-*／ledger-*）禁止事後修改：驗收過期請另開新票並把舊票標 superseded，不得自己改考卷；確需修改請使用者在訊息打 #手動。' } }))
  process.exit(0)
}

function pre(payload) {
  const tool = String(payload.tool_name || '')
  const input = payload.tool_input || {}

  if (payload.agent_id) {
    if (WORKER_DENY.test(tool)) deny(`worker ${tool}`, '子代理不直接對使用者發訊息：結論寫在你最後一則訊息，主 session 會轉述。')
    // pinGuard 只剩子代理會碰到；使用者訊息帶 #手動 才解（只解這一層）
    if (!(lastUserText(payload.transcript_path) || '').includes('#手動')) pinGuard(tool, input)
    allow()
  }

  if (tool.startsWith('mcp__telegram__') || MAIN_ALLOW.has(tool)) allow()
  if (tool === 'Agent' || tool === 'Task') {
    if (input.run_in_background === false) deny('Agent 不可 run_in_background:false，會佔住對話')
    if (input.subagent_type !== 'dispatcher') deny(`主 session 只派 dispatcher，不派 ${input.subagent_type || '(未指定)'}`)
    allow()
  }
  deny(`主 session 不用 ${tool || '(空)'}`)
}

function main() {
  const mode = process.argv[2]
  // fail 模式（舊 PostToolUseFailure）已移除，照收不做事，免得還沒重開的 session 報錯
  if (mode !== 'pre') allow()
  const payload = readPayload()
  if (!payload) deny('hook payload 讀不到')
  try {
    pre(payload)
  } catch (e) {
    deny(`閘例外 ${e.message}`)
  }
  deny('pre 沒有結論')
}

main()
