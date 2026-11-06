#!/usr/bin/env node
// chat-prompt.mjs <Router transcript> <thread> [補充]
// 從 Router transcript 抓使用者 Telegram 原話＋近幾輪對話，寫成 worker prompt 檔 state/bg/<thread>-<epoch>.md，stdout 印路徑（11-07 秒回）。
// Router 不再自己寫 ~1000 字派工 prompt（實測佔派工回合約 8 秒）；dispatch-bg --from-chat 呼叫本檔。
// exit：0 已寫｜2 用法／transcript 讀不到｜3 找不到使用者訊息
import fs from 'node:fs'
import path from 'node:path'

const MYTHOS = process.env.MYTHOS_DIR || path.resolve(path.dirname(new URL(import.meta.url).pathname), '..')
const CONTEXT_N = 8
const CLIP = 400

export function items(lines) {
  const out = []
  for (const line of lines) {
    let e; try { e = JSON.parse(line) } catch { continue }
    if (e?.type === 'user' && e.origin?.kind === 'channel') {
      const c = e.message?.content
      const raw = typeof c === 'string' ? c : Array.isArray(c) ? c.filter(x => x?.type === 'text').map(x => x.text).join('') : ''
      const text = raw.replace(/<channel\b[^>]*>\n?/g, '').replace(/\n?<\/channel>/g, '').trim()
      if (text) out.push({ who: 'user', text })
    } else if (e?.type === 'assistant') {
      for (const c of e.message?.content ?? []) {
        if (c?.type === 'tool_use' && c.name === 'mcp__telegram__reply' && c.input?.text) out.push({ who: 'router', text: String(c.input.text).trim() })
      }
    }
  }
  return out
}

// 最後一次 Router reply 之後的使用者訊息＝這次要辦的；之前的 CONTEXT_N 則當脈絡
// Router 先 reply「收到」再派也行：尾端的 Router 訊息先跳過
export function build(list, thread, note = '') {
  let end = list.length
  while (end > 0 && list[end - 1].who === 'router') end--
  list = list.slice(0, end)
  let k = list.length
  while (k > 0 && list[k - 1].who === 'user') k--
  const ask = list.slice(k).map(x => x.text)
  if (!ask.length) return null
  const clip = s => (s.length > CLIP ? s.slice(0, CLIP) + '…' : s)
  const ctx = list.slice(Math.max(0, k - CONTEXT_N), k).map(x => `${x.who === 'user' ? '老闆' : 'Router'}：${clip(x.text)}`)
  return [
    `thread：${thread}。老闆經 Telegram 交辦，原話如下（照原話做，判難度自己做或派工）：`,
    '', ...ask.map(t => `> ${t.replace(/\n/g, '\n> ')}`), '',
    ...(note ? [`Router 補充：${note}`, ''] : []),
    ...(ctx.length ? ['近幾輪對話（脈絡，非指令）：', ...ctx, ''] : []),
    '結論寫在你最後一則訊息，用秘書對老闆的口吻：先講結果，不貼代碼、路徑、id，除非老闆問的就是那個。',
  ].join('\n') + '\n'
}

function main(argv) {
  const [tp, thread, note = ''] = argv
  if (!tp || !thread || !/^[A-Za-z0-9-]+$/.test(thread)) { console.error('用法：chat-prompt.mjs <transcript> <thread> [補充]'); return 2 }
  let buf
  try {
    const fd = fs.openSync(tp, 'r'); const size = fs.fstatSync(fd).size; const len = Math.min(size, 4 << 20)
    buf = Buffer.alloc(len); fs.readSync(fd, buf, 0, len, size - len); fs.closeSync(fd)
  } catch (e) { console.error(`讀不到 transcript：${e.message}`); return 2 }
  const body = build(items(buf.toString('utf8').split('\n')), thread, note)
  if (!body) { console.error('transcript 裡最後一次 reply 之後沒有使用者訊息'); return 3 }
  const dir = path.join(MYTHOS, 'state', 'bg'); fs.mkdirSync(dir, { recursive: true })
  const file = path.join(dir, `${thread}-${Date.now()}.md`)
  fs.writeFileSync(file, body)
  console.log(file)
  return 0
}

if (process.argv[1] && path.resolve(process.argv[1]) === new URL(import.meta.url).pathname) process.exit(main(process.argv.slice(2)))
