#!/usr/bin/env node
// Mythos 的 PreToolUse hook：本輪使用者訊息不是 easy 時，主 session 只准派工，不准自己動手。
// 動手的一律是子代理（payload 帶 agent_id，harness 填、模型偽造不了）：主 session 派背景 Agent 或 bin/dispatch，
// 自己繼續跟使用者聊（11-03 對齊 DeepSeek Harness 兩層架構，取代 30 分鐘親手窗口）。
// 判斷順序：pinGuard（不分主子）→ 子代理放行 → easy 放行 → 前景 Agent 擋 → Write/Edit 看路徑、Bash 看白名單。
// fail-open：任何例外一律放行，只記 log；deny 也記 log。
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import crypto from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const MYTHOS = process.env.MYTHOS_DIR || path.dirname(HERE)
const STATE = path.join(MYTHOS, 'state')
const LOGS = path.join(MYTHOS, 'logs')
const CACHE = path.join(STATE, 'dispatch-gate.json')
// triage 來自 orchestrator（github.com/royalskynet/orchestrator 的 bin/triage）；本機預設路徑不在就找 PATH
const TRIAGE_DEFAULT = path.join(os.homedir(), 'dev/dispatch-router/bin/triage')
const TRIAGE = process.env.DISPATCH_GATE_TRIAGE || (fs.existsSync(TRIAGE_DEFAULT) ? TRIAGE_DEFAULT : 'triage')

const ALLOW_PREFIXES = [
  '/tmp/',
  // 依安裝位置推算（11-03 公開版）：bot 自己的 state／memory／trips＋它的 Claude Code transcript 目錄
  path.join(MYTHOS, 'state') + '/',
  path.join(MYTHOS, 'memory') + '/',
  path.join(MYTHOS, 'trips') + '/',
  path.join(os.homedir(), '.claude/projects', MYTHOS.replace(/[^A-Za-z0-9]/g, '-')) + '/',
]

const WHITELIST = new Set([
  'ls', 'cat', 'head', 'tail', 'grep', 'rg', 'find', 'wc', 'stat', 'file', 'which',
  'date', 'echo', 'printf', 'jq', 'sort', 'uniq', 'cut', 'awk', 'sed', 'tr', 'diff',
  'test', '[', 'true', 'pwd', 'ps', 'pgrep', 'tmux', 'dcq', 'dc', 'wo-verify',
  'triage', 'fixindex', 'curl', 'git', 'gh', 'node', 'python3', 'remind', 'local-llm',
  'sleep', 'dispatch', 'dispatch-retry', 'dispatch-cancel', 'cd', 'launchctl',
])

const DENY_GIT = new Set(['commit', 'push', 'reset', 'checkout', 'rebase', 'merge', 'add', 'rm', 'mv', 'clean', 'stash'])
const DENY_GH = new Set(['pr create', 'pr merge', 'repo create', 'release create', 'issue create'])
const ALLOW_TMUX = new Set(['capture-pane', 'has-session', 'ls', 'list-sessions'])
const ALLOW_LAUNCHCTL = new Set(['list', 'print', 'print-disabled'])

function log(line) {
  try {
    fs.mkdirSync(LOGS, { recursive: true })
    fs.appendFileSync(path.join(LOGS, 'dispatch-gate.log'), `${new Date().toISOString()} ${line}\n`)
  } catch {}
}

function allow() {
  process.exit(0)
}

function deny(tier, why) {
  const reason = `本輪 Laya 判 ${tier}，Mythos 主 session 只能派工：要動手（含唯讀診斷驗收為何失敗、改 ~/.claude／launchd／Carrie 這類不能出機的活）就用 Agent 工具派背景子代理（run_in_background 不設或 true），子代理的工具呼叫不受此閘；量大低難度的寫工單（含 ## 驗收）用 bin/dispatch <task.md> <cwd> <tier>（easy／mid＝派of、hard＝deep）。派完繼續回使用者。${why ? `（${why}）` : ''}`
  log(`DENY tier=${tier} ${why}`)
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

function readCache() {
  try {
    const c = JSON.parse(fs.readFileSync(CACHE, 'utf8'))
    if (c && typeof c.key === 'string' && typeof c.tier === 'string') return c
  } catch {}
  return {}
}

function saveCache(c) {
  try {
    fs.mkdirSync(STATE, { recursive: true })
    fs.writeFileSync(CACHE, JSON.stringify(c))
  } catch {}
}

function tierOf(text) {
  const key = crypto.createHash('sha1').update(text).digest('hex')
  const cache = readCache()
  if (cache.key === key && ['easy', 'mid', 'hard'].includes(cache.tier)) return cache.tier

  const tmp = path.join(os.tmpdir(), `dispatch-gate-${process.pid}-${Date.now()}.txt`)
  fs.writeFileSync(tmp, text)
  let out
  try {
    out = execFileSync(TRIAGE, [tmp], { encoding: 'utf8', timeout: 30000 })
  } finally {
    try { fs.unlinkSync(tmp) } catch {}
  }
  const raw = String(out || '').split(/\r?\n/).map(s => s.trim()).find(Boolean) || ''
  const tier = ['easy', 'mid', 'hard'].includes(raw) ? raw : 'mid'
  saveCache({ key, tier, at: Math.floor(Date.now() / 1000) })
  return tier
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

function firstNonOpt(args, skipWithValue = []) {
  for (let i = 0; i < args.length; i++) {
    const a = args[i]
    if (skipWithValue.includes(a)) { i++; continue }
    if (a.startsWith('-')) continue
    return a
  }
  return ''
}

function firstNonOpts(args, n, skipWithValue = []) {
  const out = []
  for (let i = 0; i < args.length && out.length < n; i++) {
    const a = args[i]
    if (skipWithValue.includes(a)) { i++; continue }
    if (a.startsWith('-')) continue
    out.push(a)
  }
  return out
}

function subAllowed(cmd, args) {
  if (cmd === 'git') {
    const sub = firstNonOpt(args, ['-C', '-c', '--git-dir', '--work-tree', '--namespace', '--exec-path'])
    if (DENY_GIT.has(sub)) return false
  } else if (cmd === 'gh') {
    const pair = firstNonOpts(args, 2, ['-R', '--repo', '--hostname', '--jq', '--template'])
    if (DENY_GH.has(pair.join(' '))) return false
  } else if (cmd === 'sed') {
    if (args.some(a => a === '-i' || a.startsWith('-i') || a === '--in-place' || a.startsWith('--in-place='))) return false
  } else if (cmd === 'node' || cmd === 'python3') {
    // ponytail: -e／-c 可任意寫檔，一律擋；要跑邏輯就放 bin/ 或派工
    const evals = new Set(['-e', '-c', '-p', '--eval', '--print', '--command'])
    // -e"…"／-c'…' 黏在一起也算（Codex 審計 #2）
    if (args.some(a => evals.has(a) || a.startsWith('--eval=') || a.startsWith('--command=') || /^-[a-zA-Z]*[ecp]/.test(a))) return false
    {
      const script = firstNonOpt(args, ['-r', '--require', '-C', '--loader', '--import', '--experimental-loader'])
      if (script) {
        const abs = path.isAbsolute(script) ? script : path.resolve(MYTHOS, script)
        const binDir = path.join(MYTHOS, 'bin') + path.sep
        if (!abs.startsWith(binDir)) return false
      }
    }
  } else if (cmd === 'curl') {
    if (args.some(a => /^-X(POST|PUT|DELETE)$/i.test(a))) return false
    if (args.some(a => /^--request=(POST|PUT|DELETE)$/i.test(a))) return false
    const xi = args.findIndex(a => a === '-X' || a === '--request')
    if (xi >= 0 && ['POST', 'PUT', 'DELETE'].includes(String(args[xi + 1] || '').toUpperCase())) return false
    if (args.some(a => a === '-o' || a === '-O' || a.startsWith('--output') || a === '--remote-name')) return false
    if (args.some(a => a === '-d' || a === '--data' || a.startsWith('--data-') || /^-d./.test(a))) return false
  } else if (cmd === 'find') {
    if (args.some(a => a === '-delete' || a.startsWith('-exec') || a.startsWith('-ok') || a === '-fprint')) return false
  } else if (cmd === 'tmux') {
    const sub = firstNonOpt(args, ['-L', '-S', '-f', '-c', '-T'])
    if (!ALLOW_TMUX.has(sub)) return false
  } else if (cmd === 'launchctl') {
    if (!ALLOW_LAUNCHCTL.has(args[0])) return false
  }
  return true
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

// awk 能 system()／getline／print > 檔，等於任意執行（Codex 審計 #3）
const AWK_EXEC = /\bsystem\s*\(|\bgetline\b|\bprintf?\b[^;}]*[>|]/

function bashAllowed(command) {
  const raw0 = command
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
    if (!WHITELIST.has(cmd)) return false
    if (cmd === 'awk' && AWK_EXEC.test(raw0)) return false
    if (!subAllowed(cmd, tokens.slice(1))) return false
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
  const text = lastUserText(payload.transcript_path)
  if (!text) allow()

  // 使用者明說 #手動＝本輪解鎖（只有使用者打得出來，模型無法自己繞）
  if (text.includes('#手動')) allow()
  pinGuard(String(payload.tool_name || ''), payload.tool_input || {})
  if (payload.agent_id) allow()
  const tier = tierOf(text)
  if (tier === 'easy') allow()

  const tool = String(payload.tool_name || '')
  const input = payload.tool_input || {}

  // 前景 Agent 會卡住主 session，派工期間沒法回使用者
  if (tool === 'Agent' && input.run_in_background === false) return deny(tier, 'Agent 不可 run_in_background:false')

  if (tool === 'Write' || tool === 'Edit' || tool === 'MultiEdit') {
    if (allowedPath(input.file_path)) allow()
    return deny(tier, `寫入非允許路徑 ${input.file_path || '(空)'}`)
  }

  if (tool === 'Bash') {
    const command = String(input.command || '')
    if (bashAllowed(command)) allow()
    return deny(tier, `指令不在派工白名單 ${command.slice(0, 200)}`)
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
