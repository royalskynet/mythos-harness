#!/usr/bin/env node
// Mythos 的 PreToolUse hook：主 session（Router）只聊天派工，任何動作交背景子代理，對話不被佔住（11-03 使用者定）。
// 子代理的呼叫帶 agent_id（harness 填、模型偽造不了）→ pinGuard 後放行；難度判斷與派 O／deep 由 dispatcher 子代理做。
// 主 session：Agent 必須背景、Bash 只准派工／提醒類秒回指令、Write/Edit 只准自己的 state／memory／工單路徑。
// 不再用 Laya 判 tier、不再有 #手動 全解鎖（使用者轉貼的文字含「#手動」就整輪解鎖，11-03 又卡死一次）。
// fail-open：任何例外一律放行，只記 log；deny 也記 log。
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const MYTHOS = process.env.MYTHOS_DIR || path.dirname(HERE)
const STATE = path.join(MYTHOS, 'state')
const LOGS = path.join(MYTHOS, 'logs')
const ALLOW_PREFIXES = [
  '/tmp/',
  // 依安裝位置推算（11-03 公開版）：bot 自己的 state／memory／trips＋它的 Claude Code transcript 目錄
  path.join(MYTHOS, 'state') + '/',
  path.join(MYTHOS, 'memory') + '/',
  path.join(MYTHOS, 'trips') + '/',
  path.join(os.homedir(), '.claude/projects', MYTHOS.replace(/[^A-Za-z0-9]/g, '-')) + '/',
]

// 主 session 能自己跑的只有秒回、不讀不改程式碼的指令；其餘（含唯讀查詢、跑測試、wo-verify）都派子代理
// 帶路徑的只准本 bot 的 bin/（主 session 能寫 /tmp，不能讓它寫一支 /tmp/x/dispatch 再借名執行）；不放 cd，免得 bin/ 相對路徑被換目錄
const WHITELIST = new Set([
  'echo', 'printf', 'true', 'date', 'remind',
  'dispatch', 'dispatch-retry', 'dispatch-cancel',
])
function ownBin(token, cmd) {
  if (!token.includes('/')) return true
  const abs = path.resolve(MYTHOS, token.replace(/^~(?=\/)/, os.homedir()))
  return abs === path.join(MYTHOS, 'bin', cmd)
}

function log(line) {
  try {
    fs.mkdirSync(LOGS, { recursive: true })
    fs.appendFileSync(path.join(LOGS, 'dispatch-gate.log'), `${new Date().toISOString()} ${line}\n`)
  } catch {}
}

function allow() {
  process.exit(0)
}

function deny(why) {
  const reason = `Mythos 主 session 只聊天派工，不自己動手：用 Agent 工具派背景 dispatcher 子代理（subagent_type: "dispatcher"，不設 run_in_background 或設 true），把使用者原話與你知道的脈絡交給它，它會判難度、自己做或派 O／deep；派完立刻 reply 使用者一句「已派 dispatcher」，結束本回合。${why ? `（${why}）` : ''}`
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
    log(`FAIL-OPEN bad hook json: ${e.message}`)
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

function allowedPath(p) {
  if (typeof p !== 'string' || !p) return false
  const abs = path.resolve(p)
  if (ALLOW_PREFIXES.some(prefix => abs.startsWith(prefix))) return true
  if (abs.includes('/wo/')) return true
  if (/task[^/]*\.md$/i.test(path.basename(abs))) return true
  return false
}

function redirectDenied(command) {
  const cleaned = command.replace(/\d*>&\d*/g, '')
  const re = />>?\s*([^\s;&|<>]+)/g
  let m
  while ((m = re.exec(cleaned)) !== null) {
    const target = m[1].replace(/^['"]|['"]$/g, '')
    if (target.startsWith('&')) continue
    if (target === '/dev/null') continue
    if (!allowedPath(target)) return true
  }
  return false
}

// 引號內的 | ; & < > 換行只是字面（rg -n "a|b"、grep -E 'x|y'），切段前先換成空白，免得唯讀查詢被誤擋（11-01 gate log 13 次）。
// 雙引號裡有 $( 或反引號＝可能執行指令，整串不處理，維持舊的保守切法。
// 回傳 null＝含命令替換（$(…)／反引號，單引號內除外）或引號沒關，呼叫端一律擋（11-02 Codex 審計：
// 雙引號內 $( 退回舊切法時 `echo "$(touch x)"` 會放行）。引號外的反斜線連同下一字元原樣保留，
// 免得 `echo \"; touch x; #"` 的 \" 被當成引號開頭、把真正的分號遮掉。
function maskQuoted(command) {
  let out = ''
  let q = ''
  for (let i = 0; i < command.length; i++) {
    const c = command[i]
    if (q) {
      if (c === q) q = ''
      else if (q === '"' && c === '\\') { out += c + (command[++i] ?? ''); continue }
      else if (q === '"' && (c === '`' || (c === '$' && command[i + 1] === '('))) return null
      else if (/[|;&<>\n]/.test(c)) { out += ' '; continue }
    } else if (c === '\\') { out += c + (command[++i] ?? ''); continue }
    else if (c === '`' || (c === '$' && command[i + 1] === '(')) return null
    else if (c === '"' || c === "'") q = c
    out += c
  }
  return q ? null : out
}

function bashAllowed(command) {
  command = maskQuoted(command)
  if (command === null) return false
  if (redirectDenied(command)) return false
  // 單一 & 也是分段（背景執行）；2>&1／>&2 先抹掉免得被切開
  const segments = command.replace(/\d*>&\d*/g, ' ').split(/&&|\|\||;|\n|\||&/)
  for (const raw of segments) {
    // shell 會拼接相鄰引號字串：git 'pu'sh＝git push
    let tokens = raw.trim().split(/\s+/).filter(Boolean).map(t => t.replace(/['"]/g, ''))
    let i = 0
    while (i < tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[i])) i++
    tokens = tokens.slice(i)
    if (!tokens.length) continue
    const cmd = path.basename(tokens[0])
    if (!WHITELIST.has(cmd) || !ownBin(tokens[0], cmd)) return false
  }
  return true
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
  const text = lastUserText(payload.transcript_path) || ''

  // pinGuard 不分主子；只有使用者訊息帶 #手動 能解（只解這一層）
  if (!text.includes('#手動')) pinGuard(tool, input)
  if (payload.agent_id) allow()

  if (tool === 'Agent') {
    if (input.run_in_background === false) return deny('Agent 不可 run_in_background:false，會佔住對話')
    allow()
  }
  if (tool === 'Write' || tool === 'Edit' || tool === 'MultiEdit') {
    if (allowedPath(input.file_path)) allow()
    return deny(`寫入非允許路徑 ${input.file_path || '(空)'}`)
  }
  if (tool === 'Bash') {
    const command = String(input.command || '')
    if (bashAllowed(command)) allow()
    return deny(`主 session 不跑這個指令 ${command.slice(0, 200)}`)
  }
  allow()
}

function main() {
  const mode = process.argv[2]
  const payload = readPayload()
  if (!payload) allow()
  try {
    // fail 模式（舊 PostToolUseFailure）已移除，照收不做事，免得還沒重開的 session 報錯
    if (mode === 'pre') pre(payload)
  } catch (e) {
    log(`FAIL-OPEN ${mode}: ${e.message}`)
    allow()
  }
  process.exit(0)
}

main()
