#!/usr/bin/env node
// 長任務進度顯示（零 token）：Claude Code hook 直接打 Bot API，不經模型。
//   pre  （PreToolUse，async）：本回合第一個工具 → 靜音 sendMessage「⏳ 步驟」；之後 editMessageText 累加步驟。
//   stop （Stop）：刪掉本回合的進度訊息；結果照舊由模型 reply 發新訊息（新訊息才推播）。
// 為什麼不讓模型先 reply「在做 X」再由 hook 改：第一步靠模型記得＝Documentation 層，符合率約 0%。
// chat_id 從 transcript 最後一則使用者訊息的 <channel source="telegram" …> 取；最後一則不是 TG 來的
// （例：remind --ask 打進 pane）就不顯示。telegram 自己的工具（reply／edit_message…）不算步驟。
// Bash 只顯示 description，沒有就只顯示程式名：指令全文可能帶憑證，進度訊息會經 Telegram 伺服器。
// 設計借鏡 overwirehq/claude-code-telegram（progress_msg＋節流 edit＋收尾刪除；無 LICENSE，未抄碼）。
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'

const HOME = os.homedir()
const STATE_DIR = process.env.TG_PROGRESS_STATE || path.join(HOME, 'bots/mythos/state')
// --worker（11-07 秒回 ⑦）：bg worker 的 transcript 沒有 <channel>，chat 改取 access.json allowFrom[0]（同 tg-send），
// 狀態檔每個 session 一份（多個 worker 跟 Router 並行，不能共用一份）；標題取 worker prompt 裡「> 」引用的老闆原話。
const WORKER = process.argv.includes('--worker')
let STATE = path.join(STATE_DIR, 'progress.json')
let LOCK = path.join(STATE_DIR, 'progress.lock')
function useSessionState(sid) {
  STATE = path.join(STATE_DIR, `progress-w-${String(sid ?? 'x').replace(/[^A-Za-z0-9-]/g, '')}.json`)
  LOCK = STATE + '.lock'
}
const LOG = process.env.TG_PROGRESS_LOG || path.join(HOME, 'bots/mythos/logs/tg-progress.log')
const API = process.env.TG_API_BASE || 'https://api.telegram.org'
// worker Stop 後留墓碑（done＋done_at）而不是刪檔：async hook 晚到的 pre 會在刪檔後重發一則刪不掉的進度（11-07 Codex P1）。
// 墓碑過了 DONE_GRACE_MS 才當新回合（同一個 worker session 被續派）。
const DONE_GRACE_MS = Number(process.env.TG_PROGRESS_DONE_GRACE_MS || 120000)
const STALE_MS = 6 * 3600 * 1000
const EDIT_GAP_MS = WORKER ? 5000 : 1500 // Telegram 對同一 chat 的修改頻率有上限；worker 可能多個並行，放慢
const SHOW_STEPS = 8

const log = s => { try { fs.appendFileSync(LOG, `[${new Date().toISOString()}] ${s}\n`) } catch {} }
const sleep = ms => new Promise(r => setTimeout(r, ms))

function botToken() {
  if (process.env.TELEGRAM_BOT_TOKEN) return process.env.TELEGRAM_BOT_TOKEN
  const dir = process.env.TELEGRAM_STATE_DIR || path.join(HOME, '.mythos/telegram')
  const m = /^TELEGRAM_BOT_TOKEN=(.*)$/m.exec(fs.readFileSync(path.join(dir, '.env'), 'utf8'))
  return m ? m[1].trim() : ''
}

async function api(method, body) {
  try {
    const res = await fetch(`${API}/bot${botToken()}/${method}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(8000),
    })
    const j = await res.json().catch(() => ({}))
    if (!res.ok) log(`${method} HTTP ${res.status}`) // 不印 URL／body：URL 含 token
    return res.ok ? j.result : null
  } catch (e) {
    log(`${method} ${e.name}`)
    return null
  }
}

// 最後一則「使用者自己打的」訊息（跳過 tool_result）是不是 TG 來的。
export function lastChannel(transcriptPath) {
  let buf
  try {
    const fd = fs.openSync(transcriptPath, 'r')
    const size = fs.fstatSync(fd).size
    const len = Math.min(size, 1 << 20)
    buf = Buffer.alloc(len)
    fs.readSync(fd, buf, 0, len, size - len)
    fs.closeSync(fd)
  } catch { return null }
  const lines = buf.toString('utf8').split('\n')
  for (let i = lines.length - 1; i >= 0; i--) {
    let e
    try { e = JSON.parse(lines[i]) } catch { continue }
    // Claude Code 10 月版把 channel 來訊標 isMeta:true（origin.kind=channel）；只跳過其他 meta，否則永遠認不出 TG 回合
    if (e.type !== 'user' || (e.isMeta && e.origin?.kind !== 'channel')) continue
    const c = e.message?.content
    const text = typeof c === 'string' ? c
      : Array.isArray(c) && !c.some(x => x.type === 'tool_result') ? c.filter(x => x.type === 'text').map(x => x.text).join('') : null
    if (text === null) continue
    const m = /^\s*<channel source="telegram" chat_id="([^"]+)" message_id="([^"]+)"/.exec(text)
    return m ? { chat_id: m[1], inbound: m[2] } : null
  }
  return null
}

export function ownerChat() {
  try {
    const dir = process.env.TELEGRAM_STATE_DIR || path.join(HOME, '.mythos/telegram')
    const a = JSON.parse(fs.readFileSync(path.join(dir, 'access.json'), 'utf8'))
    return a.allowFrom?.[0] ? String(a.allowFrom[0]) : null
  } catch { return null }
}

// worker 第一則使用者訊息（prompt）裡第一行「> 」＝老闆原話（bin/chat-prompt.mjs 的格式）；沒有就空
export function workerTitle(transcriptPath) {
  try {
    const fd = fs.openSync(transcriptPath, 'r'); const buf = Buffer.alloc(256 << 10)
    const n = fs.readSync(fd, buf, 0, buf.length, 0); fs.closeSync(fd)
    for (const line of buf.toString('utf8', 0, n).split('\n')) {
      let e; try { e = JSON.parse(line) } catch { continue }
      if (e.type !== 'user') continue
      const c = e.message?.content
      const text = typeof c === 'string' ? c : Array.isArray(c) ? c.filter(x => x.type === 'text').map(x => x.text).join('') : ''
      const m = /^> (.+)$/m.exec(text)
      return m ? m[1].trim() : ''
    }
  } catch {}
  return ''
}

const short = (s, n) => { s = String(s ?? '').replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s }

export function label(tool, input = {}) {
  if (tool.startsWith('mcp__telegram__')) return null
  switch (tool) {
    case 'Bash': return input.description ? short(input.description, 48) : `跑 ${short(String(input.command ?? '').trim().split(/\s+/)[0], 24)}`
    case 'Read': return `讀 ${path.basename(input.file_path ?? '')}`
    case 'Edit': case 'MultiEdit': return `改 ${path.basename(input.file_path ?? '')}`
    case 'Write': return `寫 ${path.basename(input.file_path ?? '')}`
    case 'NotebookEdit': return `改 ${path.basename(input.notebook_path ?? '')}`
    case 'Grep': return `搜 ${short(input.pattern, 30)}`
    case 'Glob': return `找 ${short(input.pattern, 30)}`
    case 'Agent': case 'Task': return `子代理：${short(input.description, 36)}`
    case 'WebSearch': return `查 ${short(input.query, 36)}`
    case 'WebFetch': try { return `抓 ${new URL(input.url).hostname}` } catch { return '抓網頁' }
    case 'Skill': return `skill ${short(input.skill, 30)}`
    case 'TodoWrite': case 'ToolSearch': return null
  }
  const m = /^mcp__(.+?)__(.+)$/.exec(tool)
  return m ? `${m[1]}.${m[2]}` : tool
}

export function render(steps, title = '') {
  const shown = steps.slice(-(title ? 3 : SHOW_STEPS))
  const head = title ? `⏳ 背景在做：${short(title, 30)}（第 ${steps.length} 步）` : `⏳ 處理中（第 ${steps.length} 步）`
  return [head, ...(steps.length > shown.length ? ['…'] : []), ...shown.map((s, i) => (i === shown.length - 1 ? '▸ ' : '✓ ') + s)].join('\n')
}

const readState = () => { try { return JSON.parse(fs.readFileSync(STATE, 'utf8')) } catch { return {} } }
const writeState = s => { const t = STATE + '.tmp'; fs.writeFileSync(t, JSON.stringify(s)); fs.renameSync(t, STATE) }

async function withLock(fn) {
  for (let i = 0; i < 100; i++) {
    try { fs.mkdirSync(LOCK); break } catch {
      try { if (Date.now() - fs.statSync(LOCK).mtimeMs > 15000) fs.rmdirSync(LOCK) } catch {}
      await sleep(50)
      if (i === 99) return log('lock timeout')
    }
  }
  try { return await fn() } finally { try { fs.rmdirSync(LOCK) } catch {} }
}

async function pre(h) {
  // 子代理（dispatcher 等）在主回合結束後還會跑，進度訊息會刪不掉；它的結果由主 session reply
  if (h?.agent_id) return
  const step = label(h.tool_name ?? '', h.tool_input)
  if (!step) return
  if (WORKER) useSessionState(h.session_id)
  const ch = WORKER ? (ownerChat() && { chat_id: ownerChat(), inbound: 'w' }) : lastChannel(h.transcript_path)
  if (!ch) return
  const turn = `${h.session_id}:${ch.chat_id}:${ch.inbound}`
  let wait = 0
  await withLock(async () => {
    let s = readState()
    const expired = WORKER && s.done && Date.now() - (s.done_at ?? 0) > DONE_GRACE_MS
    if (s.turn !== turn || expired) s = { turn, chat_id: ch.chat_id, title: WORKER ? workerTitle(h.transcript_path) : '', steps: [], msg_id: null, shown: 0, last_edit: 0, done: false }
    if (s.done) return
    s.steps.push(step)
    if (!WORKER) void api('sendChatAction', { chat_id: s.chat_id, action: 'typing' })  // worker 在背景，不佔「輸入中」
    if (!s.msg_id) {
      const r = await api('sendMessage', { chat_id: s.chat_id, text: render(s.steps, s.title), disable_notification: true })
      if (r) { s.msg_id = r.message_id; s.shown = s.steps.length; s.last_edit = Date.now() }
    } else {
      wait = s.last_edit + EDIT_GAP_MS - Date.now()
      if (wait <= 0) await edit(s)
    }
    writeState(s)
  })
  if (wait > 0) { // 節流中：等窗口過了再補一次，用最新狀態（期間可能又多了幾步）
    await sleep(wait)
    await withLock(async () => {
      const s = readState()
      if (s.turn === turn && !s.done && s.msg_id && s.shown < s.steps.length && Date.now() - s.last_edit >= EDIT_GAP_MS) {
        await edit(s); writeState(s)
      }
    })
  }
}

async function edit(s) {
  const r = await api('editMessageText', { chat_id: s.chat_id, message_id: s.msg_id, text: render(s.steps, s.title) })
  s.last_edit = Date.now()
  if (r) s.shown = s.steps.length
}

async function stop(h = {}) {
  if (WORKER) useSessionState(h.session_id)
  await withLock(async () => {
    const s = readState()
    if (!s.turn || s.done) return
    s.done = true
    s.done_at = Date.now()
    writeState(s) // 先標 done：還在路上的 pre 不會再發新訊息
    if (s.msg_id) {
      await api('deleteMessage', { chat_id: s.chat_id, message_id: s.msg_id })
      log(`turn done steps=${s.steps.length}`)
    }
  })
  if (WORKER) pruneWorkerStates()
}

// 墓碑不刪，改在 Stop 時清掉 6 小時沒動的 worker 狀態檔
function pruneWorkerStates() {
  try {
    for (const f of fs.readdirSync(STATE_DIR)) {
      if (!/^progress-w-.*\.json$/.test(f)) continue
      const p = path.join(STATE_DIR, f)
      if (Date.now() - fs.statSync(p).mtimeMs > STALE_MS) fs.unlinkSync(p)
    }
  } catch {}
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const mode = process.argv[2]
  let h = {}
  try { h = JSON.parse(fs.readFileSync(0, 'utf8') || '{}') } catch {}
  try { await (mode === 'stop' ? stop(h) : pre(h)) } catch (e) { log(`${mode} ${e.message}`) }
  process.exit(0) // 永不擋工具、永不擋 Stop
}
