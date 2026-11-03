#!/usr/bin/env node
// state/events.jsonl 共用讀改（A）。JSON 欄位不進 shell。
//   node lib-events.mjs scan  <events> <transcript>   掃 ACK → 印 "<id>\t<acked_at>"（不含未 ACK 的）
//   node lib-events.mjs upsert <events> '<json>'      有同 event_id 就跳過、印 "new"，否則追加、印 "existing"
//   node lib-events.mjs set    <events> <id> '<json>' 合併欄位到該筆
//   node lib-events.mjs bump   <events> '<id>\t<id>…' 這批投遞成功：delivered_at=now、tries+1
import fs from 'node:fs'

const [cmd, file, ...args] = process.argv.slice(2)
const read = () => fs.existsSync(file) ? fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map(l => { try { return JSON.parse(l) } catch { return null } }).filter(Boolean) : []
const write = rows => fs.writeFileSync(file, rows.map(r => JSON.stringify(r)).join('\n') + (rows.length ? '\n' : ''))
if (cmd === 'scan') {
  // 印 "<id>\t<acked_at>"：transcript 裡有 type:"user" 且內容含 event_id=<id> 的紀錄才算處理完
  const transcript = args[0]
  if (!file || !transcript || !fs.existsSync(file) || !fs.existsSync(transcript)) process.exit(0)
  const now = Math.floor(Date.now() / 1000)
  const lines = fs.readFileSync(transcript, 'utf8').split('\n')
  // 可信的收件紀錄：type:"user" 且內容是字串或純 text 區塊；tool_result／mixed 區塊不算，
  // transcript 裡貼了事件文字的別的東西不能冒充 ACK
  const texts = []
  for (const l of lines) {
    const i = l.indexOf('"type":"user"')  // 先做便宜的前置過濾，再 parse
    if (i < 0) continue
    let e; try { e = JSON.parse(l) } catch { continue }
    if (!e || e.type !== 'user') continue
    const c = e.message?.content ?? e.content
    if (typeof c === 'string') { texts.push(c); continue }
    if (!Array.isArray(c)) continue
    if (c.some(x => x && x.type === 'tool_result')) continue
    const t = c.filter(x => x && x.type === 'text').map(x => x.text || '').join('')
    if (t) texts.push(t)
  }
  // event_id=<id> 後面必須是空白、；、全形空白或字串結尾：job-PASS 不配 job-PASS-x
  const isAcked = id => texts.some(t => {
    const needle = 'event_id=' + id
    for (let at = t.indexOf(needle); at >= 0; at = t.indexOf(needle, at + 1)) {
      const next = t[at + needle.length]
      if (next === undefined || /[\s；]/.test(next)) return true
    }
    return false
  })
  for (const row of read()) {
    if (row.acked_at) continue
    if (isAcked(row.event_id)) console.log(`${row.event_id}\t${now}`)
  }
} else if (cmd === 'upsert') {
  const row = JSON.parse(args[0])
  const rows = read()
  if (rows.some(r => r.event_id === row.event_id)) { console.log('existing'); process.exit(0) }
  rows.push(row); write(rows); console.log('new')
} else if (cmd === 'set') {
  const [id, patch] = args
  const rows = read()
  const row = rows.find(r => r.event_id === id)
  if (!row) { console.log('missing'); process.exit(0) }
  Object.assign(row, JSON.parse(patch)); write(rows); console.log('ok')
} else if (cmd === 'bump') {
  const ids = new Set(args[0].split('\n').filter(Boolean))
  const rows = read(), now = Math.floor(Date.now() / 1000)
  for (const r of rows) if (ids.has(r.event_id)) { r.delivered_at = now; r.tries = (r.tries || 0) + 1 }
  write(rows); console.log('ok')
} else {
  console.error('用法：lib-events.mjs scan <events> <transcript> | upsert <events> <json> | set <events> <id> <json>')
  process.exit(2)
}
