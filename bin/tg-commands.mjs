#!/usr/bin/env node
// Telegram slash commands for Mythos — zero-token, deterministic.
//
// 為什麼要這一層：從 Telegram 送 `/clear`、`/usage` 進來，只會變成一段文字進 LLM，
// Claude Code 不會把它當指令執行（2026-10-06 實證）。這支程式當 telegram MCP server 的
// stdio proxy：子行程還是官方 plugin 的 server.ts，一字不改；我們只讀它往 claude 吐的
// `notifications/claude/channel` 通知，命中指令表就「不轉發」，自己在 tmux pane 裡
// 用 send-keys 打真正的 Claude Code 斜線指令，再把 pane 輸出用 Bot API 回 Telegram。
// 命中的訊息不進 LLM，所以不花 token，也不靠模型記得要執行（Documentation 層符合率約 0%）。
//
// 攔不到的三個：/start /help /status 由 plugin 自己的 grammy handler 吃掉（它們不會變成
// 通知，proxy 看不到）。所以 claude 的 /status 在這裡叫 `/stats`。
//
// 注意：mcp.json 的 telegram server command 從此是 node 這支，不再與 plugin 的 .mcp.json
// 一字不差 —— plugin 的 MCP 哪天恢復載入就不會被 claude 壓掉，可能兩邊同時 getUpdates
// （子行程會看到 409 Conflict 並在 8 次後自己退出，見 server.ts）。真的發生就把 plugin
// 在 .claude/settings.json 的 enabledPlugins 設 false。
import { spawn, execFile } from 'node:child_process'
import { createInterface } from 'node:readline'
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import { fileURLToPath } from 'node:url'
import { requestId, record } from './lib-request.mjs'
import { compactLocked } from './lib-maintenance.mjs'
import { createHash } from 'node:crypto'

const HOME = os.homedir()
// launchd 起的行程 PATH 常沒有 Homebrew：先試常見位置，都沒有才靠 PATH
const TMUX = process.env.TMUX_BIN || ['/opt/homebrew/bin/tmux', '/usr/local/bin/tmux', '/usr/bin/tmux'].find(p => fs.existsSync(p)) || 'tmux'
const SOCKET = 'mythos'
const PANE = 'mythos'
const STATE_DIR = process.env.TELEGRAM_STATE_DIR || path.join(HOME, '.mythos/telegram')
const LOG = path.join(HOME, 'bots/mythos/logs/tg-commands.log')
const PLUGIN_ROOT = path.join(HOME, '.claude/plugins/cache/claude-plugins-official/telegram')
const DEEPCLAUDE_START = path.join(HOME, '.claude/skills/deepclaude/scripts/start.sh')
const MYTHOS_ROOT = process.env.MYTHOS_DIR || path.join(path.dirname(fileURLToPath(import.meta.url)), '..')

function log(msg) {
  try {
    fs.appendFileSync(LOG, `[${new Date().toISOString()}] ${msg}\n`)
  } catch {}
}

// 最新版的 plugin 目錄：升版後不用再改 mcp.json 的路徑。
function pluginDir() {
  const vs = fs.readdirSync(PLUGIN_ROOT).filter(v => /^\d+\.\d+\.\d+$/.test(v))
  vs.sort((a, b) => a.localeCompare(b, undefined, { numeric: true }))
  if (!vs.length) throw new Error(`no telegram plugin version under ${PLUGIN_ROOT}`)
  return path.join(PLUGIN_ROOT, vs[vs.length - 1])
}

function botToken() {
  if (process.env.TELEGRAM_BOT_TOKEN) return process.env.TELEGRAM_BOT_TOKEN
  const m = /^TELEGRAM_BOT_TOKEN=(.*)$/m.exec(fs.readFileSync(path.join(STATE_DIR, '.env'), 'utf8'))
  if (!m) throw new Error('TELEGRAM_BOT_TOKEN not found')
  return m[1].trim()
}

async function api(method, body) {
  // 測試用：不連網，只記呼叫
  if (process.env.TG_API_STUB) return fs.appendFileSync(process.env.TG_API_STUB, `${method} ${JSON.stringify(body)}\n`), true
  try {
    const res = await fetch(`https://api.telegram.org/bot${botToken()}/${method}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    })
    if (!res.ok) log(`${method} failed: HTTP ${res.status}`) // 不印 body：可能回放 token
    return res.ok
  } catch (e) {
    // 斷網／讀不到 token：typing 每 4 秒打一次，丟出去會變 unhandled rejection 把 proxy 整個帶走
    log(`${method} failed: ${e.message.replace(/bot[0-9]+:[\w-]+/g, 'bot***')}`)
    return false
  }
}

const send = (chat_id, text) => api('sendMessage', { chat_id, text })
const sendPre = (chat_id, text) =>
  text === BUSY ? send(chat_id, text) :
  api('sendMessage', {
    chat_id,
    parse_mode: 'HTML',
    text: `<pre>${text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')}</pre>`,
  })

const sleep = ms => new Promise(r => setTimeout(r, ms))
const tmux = (...args) =>
  new Promise(resolve =>
    execFile(TMUX, ['-L', SOCKET, ...args], { maxBuffer: 4 << 20 }, (err, stdout) => {
      if (err) log(`tmux ${args[0]} failed: ${err.message}`)
      resolve(stdout ?? '')
    }),
  )

const exec = (file, args = []) =>
  new Promise((resolve, reject) =>
    execFile(file, args, { timeout: 30_000, maxBuffer: 1 << 20 }, (err, stdout, stderr) => {
      if (err) {
        err.message = (stderr || err.message).trim()
        reject(err)
      } else resolve(stdout.trim())
    }),
  )

// 在 TUI 的輸入框打一行斜線指令。`/` 會跳自動完成，第一項就是完全相符的那個，
// 所以先送字面文字、等它渲染、再送 Enter（run.sh 啟動時送 Enter 同一招）。
async function type(line) {
  await tmux('send-keys', '-t', PANE, '-l', line)
  await sleep(600)
  await tmux('send-keys', '-t', PANE, 'Enter')
}

// claude 正在跑工具時，狀態列會有「esc to interrupt」。這時打斜線指令只會被當成插話排隊，
// 輸出還沒出來就抓 pane，後面的 Escape 更會把正在跑的工具打斷（10-07 /ctx 打斷 fixindex find）。
const BUSY = '⏳ Mythos 正在跑工具，現在送指令會打斷它。等它做完再試，要停先用 /stop。'
const isBusy = async () =>
  process.env.TG_BUSY_FILE ? fs.existsSync(process.env.TG_BUSY_FILE) : /esc to interrupt/.test(await tmux('capture-pane', '-p', '-t', PANE))

// 秒回（11-07，借鏡 Hermes gateway _keep_typing 與 LangGraph double-texting 的 enqueue＋先回）：
// 訊息一進來就每 4 秒補送 typing（Telegram 的 typing 5 秒就消失），直到 Router 對這個 chat 送出 reply、
// pane 閒下來或 10 分鐘；Router 正在忙（這則只能排隊）就先回「收到，等等處理」。零 token。
const TYPING_MS = Number(process.env.TG_TYPING_MS) || 4000
const TYPING_MAX = 10 * 60_000
const ACK_BUSY = '收到，等等處理'
const typing = new Map()
function stopTyping(chat) {
  clearInterval(typing.get(chat))
  typing.delete(chat)
}
function startTyping(chat) {
  stopTyping(chat)
  const t0 = Date.now()
  const timer = setInterval(async () => {
    const age = Date.now() - t0
    if (age > TYPING_MAX || (age > 2 * TYPING_MS && !(await isBusy()))) return stopTyping(chat)
    if (typing.get(chat) === timer) void api('sendChatAction', { chat_id: chat, action: 'typing' })
  }, TYPING_MS)
  typing.set(chat, timer)
  void api('sendChatAction', { chat_id: chat, action: 'typing' })
}
const busyAcks = new Set()
async function ackBusy(chat, rid) {
  if (rid && busyAcks.has(rid)) return
  if (rid) busyAcks.add(rid)
  if (busyAcks.size > 4096) busyAcks.delete(busyAcks.values().next().value)
  if (await send(chat, ACK_BUSY)) record(MYTHOS_ROOT, 'ack', rid ? [rid] : [])
  else if (rid) busyAcks.delete(rid)
}
async function onUserMessage(chat, rid) {
  if (!chat) return
  if (compactLocked(MYTHOS_ROOT) || await isBusy()) {
    await ackBusy(chat, rid)
  }
  startTyping(chat)
}
// claude → plugin 的 tools/call：Router 對某 chat 送出 reply 就停那個 chat 的 typing
export function replyChat(line) {
  if (!line.includes('tools/call')) return null
  try {
    const m = JSON.parse(line)
    return m?.method === 'tools/call' && m.params?.name === 'reply' ? String(m.params.arguments?.chat_id ?? '') || null : null
  } catch {
    return null
  }
}

// 跑一個只在 TUI 裡顯示結果的指令（/status、/usage…），把 pane 文字抓回來。忙碌中回 BUSY，不送鍵。
async function run(line, { wait = 2500, dismiss = true, scrollback = false } = {}) {
  if (await isBusy()) return BUSY
  await type(line)
  await sleep(wait)
  const pane = await tmux('capture-pane', '-p', '-t', PANE, ...(scrollback ? ['-S', '-400'] : []))
  if (dismiss) await tmux('send-keys', '-t', PANE, 'Escape')
  // 遮信箱：/status 會印 Email／Organization，貼回主 session 會被 canary 的 pii-email 整則擋掉。
  const out = pane
    .replace(/[\w.+-]+@[\w-]+(\.[\w-]+)+/g, '<email>')
    .replace(/[ \t]+$/gm, '')
    .replace(/\n{3,}/g, '\n\n')
    .trimEnd()
  return out.length > 3400 && !scrollback ? out.slice(-3400) : out
}

// /context 原樣是格子圖＋上百行明細，pane 只抓得到尾巴（skills 清單），Telegram 看起來一團亂。
// 抽出總量與分類，照大小重排成短清單；抓不到就回 null，讓呼叫端退回原文。
const kNum = v => parseFloat(v) * (v.endsWith('k') ? 1000 : 1)
function formatContext(text) {
  // 只認整行的「⎿ Context Usage」標頭：pane 裡別的工具輸出也可能夾著這幾個字。
  const heads = [...text.matchAll(/^\s*⎿\s+Context Usage\s*$/gm)]
  if (!heads.length) return null
  const block = text.slice(heads.at(-1).index).split('Auto-compact window')[0]
  const total = block.match(/([\d.]+k?)\s*\/\s*([\d.]+k?) tokens \((\d+)%\)/)
  const rows = [...block.matchAll(/[⛁⛀⛶⛝]\s+([A-Za-z][\w ]*?): ([\d.]+k?)(?: tokens)? \(([\d.]+)%\)/g)]
    .map(([, name, size, pct]) => ({ name, size, pct }))
  if (!total || !rows.length) return null
  const extra = ['Free space', 'Autocompact buffer']
  const used = rows.filter(r => !extra.includes(r.name)).sort((a, b) => kNum(b.size) - kNum(a.size))
  const get = n => rows.find(r => r.name === n)
  const free = get('Free space'), buf = get('Autocompact buffer')
  return [
    `Context：${total[1]} / ${total[2]}（${total[3]}%）`,
    '',
    ...used.map(r => `• ${r.name} ${r.size}（${r.pct}%）`),
    '',
    free && `可用 ${free.size}（${free.pct}%）`,
    buf && `autocompact 保留 ${buf.size}（${buf.pct}%）`,
  ].filter(l => l !== false && l !== undefined && l !== null).join('\n')
}

const PASS = new Set(['fi'])

// /fix：Claude Code 的 ~/.claude/commands/fix.md 是唯一正本，每次現讀（改正本即生效）。
// Mythos 不載入 commands，所以在這裡去掉 frontmatter、代入 $ARGUMENTS，把整份展開後的提示轉給模型。
const FIX_MD = path.join(os.homedir(), '.claude/commands/fix.md')
export function expandFix(arg, md = fs.readFileSync(FIX_MD, 'utf8')) {
  const body = md.replace(/^---\n[\s\S]*?\n---\n/, '')
  return body.replaceAll('$ARGUMENTS', arg || '（未附症狀：先問使用者貼錯誤原文）')
}

// /wheel：同樣現讀 ~/.claude/commands/wheel.md 展開轉給模型（找現成輪子 prior-art）
const WHEEL_MD = path.join(os.homedir(), '.claude/commands/wheel.md')
export function expandWheel(arg, md = fs.readFileSync(WHEEL_MD, 'utf8')) {
  const body = md.replace(/^---\n[\s\S]*?\n---\n/, '')
  return body.replaceAll('$ARGUMENTS', arg || '（未附問題：先問使用者要找哪一類輪子）')
}

const HELP = [
  '可用指令（Mythos）',
  '',
  '/new /clear /reset — 開新對話（重開 claude 行程，約 20 秒）',
  '/compact — 壓縮 context',
  '/stats — Claude Code 狀態（版本／模型／MCP）',
  '/usage — 用量與方案額度',
  '/cost — 本 session 花費',
  '/ctx — context 用量明細',
  '/fix <症狀或錯誤原文> — 檢修模式（對應 Claude Code /fix：重現→根因→根治→預防→驗收）',
  '/wheel <問題> — 找現成輪子（對應 Claude Code /wheel：prior-art 三軸）',
  '/fi — 把這段對話的教訓記進 fixindex（交給 Mythos 做）',
  '/deepclaude — 新增獨立 Happy DeepClaude session',
  '/model [名稱] — 看或換模型',
  '/stop — 送 Esc 中斷目前工作',
  '/restart — 重開整個 claude 行程（launchd 拉回來）',
  '/ping — 活著嗎',
  '/cc <指令> — 直接打任意斜線指令進 TUI',
  '/cmds — 這張表',
  '',
  '/status 和 /help 被 telegram plugin 佔住（回的是配對狀態）。',
].join('\n')

const handlers = {
  cmds: async chat => send(chat, HELP),
  deepclaude: async chat => {
    await send(chat, '🚀 正在建立 Happy DeepClaude session')
    return send(chat, await exec('/bin/bash', [DEEPCLAUDE_START]))
  },
  ping: async chat => {
    const created = (await tmux('display-message', '-p', '-t', PANE, '#{session_created}')).trim()
    const up = created ? Math.round((Date.now() / 1000 - Number(created)) / 60) : '?'
    return send(chat, `pong — session 開了 ${up} 分鐘`)
  },
  // /clear 安全的前提：.claude/settings.json 的 telegram plugin 必須是 false。
  // plugin 開著時，/clear 重載設定會讓 plugin 版 MCP 搶走 token，channel 變聾（fix 10099）。
  new: async chat => {
    await type('/clear')
    return send(chat, '🆕 已清空 context，可以開始新對話')
  },
  compact: async chat => {
    await type('/compact')
    return send(chat, '🗜 在壓縮 context，完成後我會回報')
  },
  stats: async chat => sendPre(chat, await run('/status')),
  usage: async chat => sendPre(chat, await run('/usage', { wait: 3500 })),
  cost: async chat => sendPre(chat, await run('/cost')),
  ctx: async chat => {
    let out = await run('/context', { wait: 3500, scrollback: true })
    if (out === BUSY) return send(chat, BUSY)
    let pretty = formatContext(out)
    // 輸出慢於 3.5 秒時再從 scrollback 撈幾次，不把半截格子圖原文丟給使用者
    for (let i = 0; !pretty && i < 4; i++) {
      await sleep(1500)
      out = await tmux('capture-pane', '-p', '-t', PANE, '-S', '-600')
      pretty = formatContext(out)
    }
    if (!pretty) log(`ctx parse failed, tail: ${JSON.stringify(out.slice(-300))}`)
    return send(chat, pretty ?? '⚠️ 抓不到 /context 的結果（格式可能改了），看 logs/tg-commands.log')
  },
  model: async (chat, arg) =>
    arg
      ? (await type(`/model ${arg}`), send(chat, `✅ 已送出 /model ${arg}`))
      : sendPre(chat, await run('/model')),
  stop: async chat => {
    await tmux('send-keys', '-t', PANE, 'Escape')
    return send(chat, '⏹ 已送 Esc')
  },
  restart: async chat => {
    await send(chat, '♻️ 重開 claude 行程，約 20 秒後回來')
    await sleep(1500)
    return tmux('kill-session', '-t', PANE) // launchd KeepAlive 會把 run.sh 拉回來
  },
  cc: async (chat, arg) => {
    if (!arg) return send(chat, '用法：/cc <斜線指令>，例：/cc /mcp')
    return sendPre(chat, await run(arg.startsWith('/') ? arg : `/${arg}`, { wait: 4000 }))
  },
}
const ALIAS = { clear: 'new', reset: 'new', context: 'ctx', help2: 'cmds', restart2: 'restart' }

// 使用者回覆 bg 直發的那則（bin/tg-send 記在 state/tg-msg-thread.tsv）→ 內容前加標註，由 Router 判斷追問或新題。
// 只在對到的 job 正好是 ledger 裡該 thread 最後一列 bg／bg-hard 時標註（--thread 續派的是最新那個）；讀檔失敗＝不標註。
function replyTag(params) {
  const rid = params?.meta?.reply_to_message_id
  const chat = params?.meta?.chat_id
  if (rid == null || chat == null || typeof params.content !== 'string') return null
  try {
    let hit
    for (const l of fs.readFileSync(path.join(MYTHOS_ROOT, 'state/tg-msg-thread.tsv'), 'utf8').split('\n')) {
      const f = l.split('\t')
      if (f[0] === String(chat) && f[1] === String(rid)) hit = f
    }
    if (!hit) return null
    const [, , th, job] = hit
    let last
    for (const l of fs.readFileSync(path.join(MYTHOS_ROOT, 'state/dispatch-jobs.tsv'), 'utf8').split('\n')) {
      const f = l.split('\t')
      if (f[6] === th && (f[7] === 'bg' || f[7] === 'bg-hard')) last = f[0]
    }
    return last === job ? { th, job } : null
  } catch {
    return null
  }
}

// 追問直送 worker（11-04，借鏡 DeepSeek Super-agent：已有任務的後續訊息沿 thread 直送 Worker，少繞一次 Router）：
// 命中時 proxy 自己跑 dispatch-bg --thread 續派，Router 只收「已直送」通知、不再判斷要不要續派。
// worker 判斷不是同一件事就不寫摘要段 → dispatch-watch 照一般 [派工回報] 交回 Router。
// 續派失敗 → 退回舊標註，由 Router 判斷。測試模式（TG_COMMANDS_CHILD）沒給 DISPATCH_BG_BIN 時不直送，免得叫到真 claude。
const DISPATCH_BG_BIN =
  process.env.DISPATCH_BG_BIN || (process.env.TG_COMMANDS_CHILD ? '' : path.join(MYTHOS_ROOT, 'bin/dispatch-bg'))
function directFollowup(th, job, text, rid) {
  return new Promise(resolve => {
    if (!DISPATCH_BG_BIN || process.env.DIRECT_FOLLOWUP === '0') return resolve(null)
    let file
    try {
      const key = createHash('sha256').update(rid || text).digest('hex')
      file = path.join(MYTHOS_ROOT, 'state/bg', `${th}-followup-${key}.md`)
      fs.mkdirSync(path.dirname(file), { recursive: true })
      fs.writeFileSync(
        file,
        (rid ? `request_id=${rid}\n` : '') + `thread=${th}\n使用者回覆了你上一則結果（${job}），原話在最下面。\n` +
          '是同一件事的追問、補充或改方向 → 照做，最後照樣寫 result（摘要＋細節）。\n' +
          '跟這件事無關 → 不做；result 不寫「摘要：」段，只寫「交回 Router：這是新的事」加原話，Router 會另開。\n\n' +
          `原話：\n${text}\n`,
      )
    } catch (e) {
      log(`followup ${th}: 寫 prompt 失敗 ${e.message}`)
      return resolve(null)
    }
    execFile(DISPATCH_BG_BIN, ['--thread', th, th, file], { timeout: 60_000, env: { ...process.env, MYTHOS_DIR: MYTHOS_ROOT, DISPATCH_BG_EID: path.basename(file, '.md') } }, (err, stdout, stderr) => {
      const id = /^bg-[0-9a-f]{8}$/m.exec(stdout || '')?.[0]
      if (err || !id) {
        log(`followup ${th}: dispatch-bg 失敗 ${err?.message ?? ''} ${String(stderr || '').slice(0, 300)}`)
        return resolve(null)
      }
      resolve(id)
    })
  })
}

// P4 N02：follow-up 直通。P6：MYTHOS_FOLLOWUP_DIRECT 三值 off（預設）／observe（只寫觀察、交 Router）／auto（舊值 1 同 auto）。
// 只有 auto 才真的入列；observe 也會呼叫 bin/followup-direct（寫 observations.jsonl），但對 Router 的行為同 off。
// 回 thread 代號＝已入列或重播去重（不再交 Router）；null＝交 Router 照舊流程（未綁定、歧義、新話題、舊 generation 都走這邊）。
function followupMode() {
  const v = process.env.MYTHOS_FOLLOWUP_DIRECT
  return v === 'observe' ? 'observe' : (v === 'auto' || v === '1') ? 'auto' : 'off'
}
// P6：Router 路徑先查：同事件已由直通入列（queued 收據）就不再交 Router 重派。只在 auto 查。
function followupSeen(chat, fmid) {
  return new Promise(resolve => {
    if (followupMode() !== 'auto' || chat == null || fmid == null) return resolve(null)
    let out = ''
    let child
    try {
      child = spawn(path.join(MYTHOS_ROOT, 'bin/followup-direct'), ['--seen', String(chat), String(fmid)], {
        env: { ...process.env, MYTHOS_DIR: MYTHOS_ROOT },
        stdio: ['ignore', 'pipe', 'ignore'],
      })
    } catch {
      return resolve(null)
    }
    const timer = setTimeout(() => child.kill(), 5_000)
    child.stdout.on('data', d => { out += d })
    child.on('error', () => { clearTimeout(timer); resolve(null) })
    child.on('close', code => {
      clearTimeout(timer)
      const m = /^seen (t-[A-Za-z0-9-]+)$/m.exec(out)
      if (code === 0 && m) {
        log(`followup seen thread=${m[1]} chat=${chat} mid=${fmid}（已直通，不再交 Router）`)
        return resolve(m[1])
      }
      resolve(null)
    })
  })
}

function followupDirect(chat, fmid, rmid, text) {
  return new Promise(resolve => {
    if (followupMode() === 'off' || chat == null || fmid == null || rmid == null) return resolve(null)
    let out = ''
    let child
    try {
      child = spawn(path.join(MYTHOS_ROOT, 'bin/followup-direct'), [String(chat), String(fmid), String(rmid)], {
        env: { ...process.env, MYTHOS_DIR: MYTHOS_ROOT },
        stdio: ['pipe', 'pipe', 'pipe'],
      })
    } catch {
      return resolve(null)
    }
    const timer = setTimeout(() => child.kill(), 15_000)
    child.stdout.on('data', d => { out += d })
    child.on('error', () => { clearTimeout(timer); resolve(null) })
    child.on('close', code => {
      clearTimeout(timer)
      const m = /^(queued|dup) (t-[A-Za-z0-9-]+)$/m.exec(out)
      if (code === 0 && m) {
        log(`followup ${m[1]} thread=${m[2]} chat=${chat} mid=${fmid} rmid=${rmid}`)
        return resolve(m[2])
      }
      if (code !== 3) log(`followup 交 Router（exit ${code}）chat=${chat} mid=${fmid} rmid=${rmid}`)
      resolve(null)
    })
    child.stdin.end(String(text ?? ''))
  })
}

const attachmentPromises = new Map()
async function handleChannel(msg, line) {
  // 附件自動下載（借鏡 plugin）：channel 通知帶 attachment_file_id 時 proxy 自己向 plugin server 呼叫 download_attachment，把路徑寫進訊息
  const _meta = msg?.params?.meta
  const _fid = _meta?.attachment_file_id
  const _content = msg?.params?.content
  if (_fid && typeof _content === 'string' && !_content.includes('[附件已存 ')) {
    const _key = `${_meta?.chat_id}:${_meta?.message_id}`
    if (!attachmentPromises.has(_key)) {
      const _size = _meta?.attachment_size
      const _p = (Number(_size) > 20971520)
        ? Promise.resolve({ error: '檔案超過 20MB 上限' })
        : downloadAttachment(_fid)
      attachmentPromises.set(_key, _p)
    }
    const _res = await attachmentPromises.get(_key)
    if (_res?.path) {
      msg.params.content = _content + `\n[附件已存 ${_res.path}]`
      if (msg.params.meta) msg.params.meta.attachment_path = _res.path
      try { fs.chmodSync(_res.path, 0o600) } catch {}
    } else {
      msg.params.content = _content + `\n[附件下載失敗：${_res?.error ?? 'unknown'}]`
    }
    line = JSON.stringify(msg)
  }
  const orig = msg.params?.content
  if (compactLocked(MYTHOS_ROOT)) { queueMaintenance(msg, line); return false }
  if (intercept(msg.params)) return true
  // P4 N02：flag 開才先試直通；已入列（或重播去重）就不再交 Router
  const fu = typeof orig === 'string'
    ? ((await followupDirect(_meta?.chat_id, _meta?.message_id, _meta?.reply_to_message_id, orig)) ?? (await followupSeen(_meta?.chat_id, _meta?.message_id)))
    : null
  if (fu) {
    msg.params.content = `[已排入 worker thread=${fu}] ` + msg.params.content
    if (compactLocked(MYTHOS_ROOT)) { queueMaintenance(msg, JSON.stringify(msg)); return false }
    process.stdout.write(JSON.stringify(msg) + '\n')
    return true
  }
  const hit = replyTag(msg.params)
  // /fix、/wheel 展開會改 content：改過就送改過的（11-04 前送的是原始 line，展開內容被丟掉）；沒改才原樣轉發
  if (!hit) {
    process.stdout.write((msg.params?.content === orig ? line : JSON.stringify(msg)) + '\n')
    return true
  }
  const id = await directFollowup(hit.th, hit.job, msg.params.content, requestId(msg.params))
  log(`reply hit thread=${hit.th} job=${hit.job} → ${id ? `直送 ${id}` : '交 Router 判斷'}`)
  msg.params.content =
    (id ? `[已直送 worker thread=${hit.th} job=${id}] ` : `[回覆 bg thread=${hit.th} job=${hit.job}] `) + msg.params.content
  if (compactLocked(MYTHOS_ROOT)) { queueMaintenance(msg, JSON.stringify(msg)); return false }
  process.stdout.write(JSON.stringify(msg) + '\n')
  return true
}

// 回傳 true＝這則訊息被我吃掉，不要轉發給 claude。
function intercept(params) {
  const content = typeof params?.content === 'string' ? params.content.trim() : ''
  const chat = params?.meta?.chat_id
  if (!chat || !content.startsWith('/')) return false

  const m = /^\/([A-Za-z0-9_]+)(?:@\S+)?(?:\s+([\s\S]*))?$/.exec(content)
  if (!m) return false
  const name = ALIAS[m[1].toLowerCase()] ?? m[1].toLowerCase()
  const arg = m[2]?.trim()
  const fn = handlers[name]

  // 要模型判斷的指令原樣轉給 Mythos（/fi 要掃 session 挑教訓，proxy 做不了）
  if (name === 'fix') {
    try {
      params.content = expandFix(arg)
      log(`expand /fix (${params.content.length} chars) to model`)
      return false
    } catch (e) {
      log(`/fix expand failed: ${e.message}`)
      void send(chat, `⚠️ /fix 讀不到 ${FIX_MD}：${e.message}`)
      return true
    }
  }
  if (name === 'wheel') {
    try {
      params.content = expandWheel(arg)
      log(`expand /wheel (${params.content.length} chars) to model`)
      return false
    } catch (e) {
      log(`/wheel expand failed: ${e.message}`)
      void send(chat, `⚠️ /wheel 讀不到 ${WHEEL_MD}：${e.message}`)
      return true
    }
  }
  if (PASS.has(name)) {
    log(`pass /${name} to model`)
    return false
  }
  if (!fn) {
    log(`unknown command /${name}`)
    void send(chat, `不認識 /${name}。\n\n${HELP}`)
    return true // 不轉發：避免模型把打錯的指令當任務做
  }
  log(`run /${name}${arg ? ' ' + arg : ''}`)
  fn(chat, arg).catch(e => {
    log(`/${name} failed: ${e.message}`)
    void send(chat, `⚠️ /${name} 失敗：${e.message}`)
  })
  return true
}

const MENU = [
  { command: 'cmds', description: '可用指令' },
  { command: 'new', description: '清空 context' },
  { command: 'compact', description: '壓縮 context' },
  { command: 'stats', description: 'Claude Code 狀態' },
  { command: 'usage', description: '用量與額度' },
  { command: 'cost', description: '本 session 花費' },
  { command: 'ctx', description: 'context 用量' },
  { command: 'fix', description: '檢修：根因→根治→預防' },
  { command: 'wheel', description: '找現成輪子（prior-art）' },
  { command: 'fi', description: '記教訓進 fixindex' },
  { command: 'deepclaude', description: '新增 Happy DeepClaude session' },
  { command: 'model', description: '看或換模型' },
  { command: 'stop', description: '中斷目前工作' },
  { command: 'restart', description: '重開 claude 行程' },
  { command: 'ping', description: '活著嗎' },
  { command: 'start', description: 'Welcome and setup guide' },
  { command: 'help', description: 'What this bot can do' },
  { command: 'status', description: 'Check your pairing status' },
]

// 啟動時把 inbox 目錄與檔案權限鎖緊（失敗只記 log）
try {
  const inboxDir = path.join(HOME, '.mythos', 'telegram', 'inbox')
  fs.mkdirSync(inboxDir, { recursive: true, mode: 0o700 })
  fs.chmodSync(inboxDir, 0o700)
  for (const f of fs.readdirSync(inboxDir)) {
    try {
      const full = path.join(inboxDir, f)
      if (fs.statSync(full).isFile()) fs.chmodSync(full, 0o600)
    } catch {}
  }
} catch (e) { log(`inbox chmod: ${e.message}`) }
// TG_COMMANDS_CHILD 只給測試用：換掉子行程，就能在不碰真 bot 輪詢的情況下灌假通知。
const argv = process.env.TG_COMMANDS_CHILD
  ? process.env.TG_COMMANDS_CHILD.split(' ')
  : [path.join(HOME, '.local/bin/bun'), 'run', '--cwd', pluginDir(), '--shell=bun', '--silent', 'start']
log(`proxy up, child=${argv.slice(0, 4).join(' ')}`)
const child = spawn(argv[0], argv.slice(1), {
  stdio: ['pipe', 'pipe', 'pipe'],
  env: process.env,
  detached: true, // 自成程序群組：bun run 底下的 server.ts 是孫行程，要整群一起收
})
// 逐行轉給 plugin（JSON-RPC 一行一則），順便看 Router 何時 reply 好停 typing
createInterface({ input: process.stdin, crlfDelay: Infinity }).on('line', line => {
  const chat = replyChat(line)
  if (chat) {
    stopTyping(chat)
    try { const m = JSON.parse(line); replyRequests.set(String(m.id), latestRequest.get(chat)) } catch {}
  }
  child.stdin.write(line + '\n')
})
// claude 死掉 → stdin 關 → 收掉子行程再退，否則 server.ts 變孤兒繼續搶 getUpdates。
// 10-06 實測：孤兒 server.ts 不理 SIGTERM，所以 2 秒後補 SIGKILL。
const killGroup = sig => {
  try {
    process.kill(-child.pid, sig)
  } catch {}
}
// claude 退出時有時直接對 proxy 送 SIGTERM/SIGHUP、不關 stdin（10-06 實測沒有 stdin closed 那行），兩條路都要收。
let shuttingDown = false
const shutdown = why => {
  if (shuttingDown) return
  shuttingDown = true
  log(`${why} — shutting child down`)
  killGroup('SIGTERM')
  setTimeout(() => {
    killGroup('SIGKILL')
    process.exit(0)
  }, 2000)
}
process.stdin.on('end', () => shutdown('stdin closed'))
for (const sig of ['SIGTERM', 'SIGHUP', 'SIGINT']) process.on(sig, () => shutdown(sig))
child.on('exit', (code, sig) => {
  log(`child exited code=${code} sig=${sig}`)
  if (!shuttingDown) process.exit(code ?? 1) // 收尾中：等計時器補 SIGKILL 給孫行程
})

// 只有 channel 通知排同一條鏈（直送續派要等 dispatch-bg，使用者訊息之間不能插隊）；
// 工具 RPC 回應等其他行立刻透傳，輸入中／忙碌先回在排隊前就做（11-07 Codex：原本一則續派能把 reply 回應卡 60 秒）
let chain = Promise.resolve()
const latestRequest = new Map(), replyRequests = new Map()
const maintenanceDir = path.join(MYTHOS_ROOT, 'state/router-mailbox')
function queueMaintenance(msg, line) {
  fs.mkdirSync(maintenanceDir, { recursive: true })
  const key = createHash('sha256').update(requestId(msg.params) || line).digest('hex')
  const file = path.join(maintenanceDir, `${key}.json`)
  void ackBusy(msg.params?.meta?.chat_id, requestId(msg.params)).catch(e => log(`maintenance ack: ${e.message}`))
  if (fs.existsSync(file)) return
  const tmp = `${file}.tmp.${process.pid}`
  fs.writeFileSync(tmp, JSON.stringify({ msg, line, received: Date.now() }))
  fs.renameSync(tmp, file)
  const rid = requestId(msg.params)
  record(MYTHOS_ROOT, 'queued', rid ? [rid] : [])
}
// 磁碟佇列可跨 proxy 重開續接；只排 channel，RPC 不等 maintenance。
let replaying = false
setInterval(() => {
  if (replaying || compactLocked(MYTHOS_ROOT)) return
  let files
  try { files = fs.readdirSync(maintenanceDir).filter(f => f.endsWith('.json')).map(f => {
    const file = path.join(maintenanceDir, f)
    return { file, ...JSON.parse(fs.readFileSync(file, 'utf8')) }
  }).sort((a, b) => a.received - b.received) } catch { return }
  if (!files.length) return
  replaying = true
  chain = chain.then(async () => {
    for (const item of files) {
      if (compactLocked(MYTHOS_ROOT)) break
      if (await handleChannel(item.msg, item.line) === false) break
      fs.unlinkSync(item.file)
    }
  }).catch(e => log(`maintenance replay: ${e.message}`)).finally(() => { replaying = false })
}, 250).unref()
const dlPending = new Map()
let dlSeq = 0
function downloadAttachment(fileId) {
  const id = `tgproxy-dl-${++dlSeq}`
  return new Promise(resolve => {
    const timer = setTimeout(() => {
      dlPending.delete(id)
      resolve({ error: 'timeout' })
    }, Number(process.env.TG_DL_TIMEOUT_MS) || 60000)
    dlPending.set(id, { resolve, timer })
    try {
      child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method: 'tools/call', params: { name: 'download_attachment', arguments: { file_id: fileId } } }) + '\n')
    } catch (e) {
      clearTimeout(timer)
      dlPending.delete(id)
      resolve({ error: e.message })
    }
  })
}
createInterface({ input: child.stdout }).on('line', line => {
  let msg
  try {
    msg = JSON.parse(line)
  } catch {
    return process.stdout.write(line + '\n') // 非 JSON（bun 的雜訊）照原樣轉發
  }
  if (msg?.method !== 'notifications/claude/channel') {
    if (typeof msg?.id === 'string' && msg.id.startsWith('tgproxy-dl-')) {
      const p = dlPending.get(msg.id)
      if (p) {
        clearTimeout(p.timer)
        dlPending.delete(msg.id)
        const isError = !!(msg?.error || msg?.result?.isError)
        let found = null
        const contents = msg?.result?.content
        if (Array.isArray(contents)) {
          outer: for (const c of contents) {
            if (c && typeof c.text === 'string') {
              for (const ln of c.text.split('\n')) {
                const t = ln.trim()
                if (t.startsWith('/')) { found = t; break outer }
              }
            }
          }
        }
        if (isError || !found) {
          const reason = msg?.error?.message || (Array.isArray(contents) ? contents.map(c => c?.text).filter(Boolean).join(' ') : '') || 'download failed'
          p.resolve({ error: String(reason).trim() || 'download failed' })
        } else {
          p.resolve({ path: found })
        }
      }
      return
    }
    const rid = replyRequests.get(String(msg?.id))
    if (rid && !msg.error && !msg.result?.isError) {
      record(MYTHOS_ROOT, 'ack', [rid])
      record(MYTHOS_ROOT, 'answer-sent', [rid], '', 'router')
    }
    replyRequests.delete(String(msg?.id))
    return process.stdout.write(line + '\n')
  }
  const rid = requestId(msg.params)
  record(MYTHOS_ROOT, 'received', rid ? [rid] : [])
  if (rid) latestRequest.set(String(msg.params.meta.chat_id), rid)
  const c = msg.params?.content
  if (!(typeof c === 'string' && c.trim().startsWith('/'))) onUserMessage(msg.params?.meta?.chat_id, rid).catch(e => log(`ack: ${e.message}`))
  if (compactLocked(MYTHOS_ROOT)) return queueMaintenance(msg, line)
  chain = chain.then(() => handleChannel(msg, line)).catch(e => log(`line handler: ${e.message}`))
})

// plugin 在開始輪詢時會自己 setMyCommands（只有 start/help/status）。等它印出那行再覆寫，
// 順序才對；我們的清單含它那三個，不會弄丟。
createInterface({ input: child.stderr }).on('line', line => {
  process.stderr.write(line + '\n')
  if (line.includes('polling as @')) {
    setTimeout(
      () => void api('setMyCommands', { commands: MENU, scope: { type: 'all_private_chats' } }),
      1500,
    )
  }
})
