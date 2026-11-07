// request id 只收 Telegram 數字識別，不記訊息內文；單行 append，不改 ledger 格式。
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
export const requestId = params => {
  const m = params?.meta
  return /^-?\d+$/.test(String(m?.chat_id)) && /^\d+$/.test(String(m?.message_id))
    ? `tg:${m.chat_id}:${m.message_id}` : ''
}
export function requestIds(text) {
  return [...new Set([...text.matchAll(/^request_id=(tg:-?\d+:\d+)$/gm)].map(m => m[1]))]
}
export function record(root, stage, ids, job = '', source = '') {
  if (!ids.length) return true
  try {
    const dir = path.join(root, 'state')
    fs.mkdirSync(dir, { recursive: true })
    fs.appendFileSync(path.join(dir, 'requests.jsonl'), ids.map(request_id => JSON.stringify({
      request_id, stage, ts: Date.now(), ...(job ? { job } : {}), ...(source ? { source } : {}),
    })).join('\n') + '\n')
    return true
  } catch (e) {
    // 計時記錄失敗不能把已送出的 Telegram 改判成「未送」，也不能截斷 proxy。
    process.stderr.write(`request 紀錄寫入失敗：${e.code || 'unknown'}\n`)
    return false
  }
}
export function envIds() { return /^tg:-?\d+:\d+$/.test(process.env.MYTHOS_REQUEST_ID || '') ? [process.env.MYTHOS_REQUEST_ID] : [] }
export function jobIds(root, job) {
  if (!/^bg-[0-9a-f]{8}$/.test(job)) return []
  try { return JSON.parse(fs.readFileSync(path.join(root, 'state/bg', `${job}.requests`), 'utf8')) } catch { return [] }
}
export function report(root, days) {
  const ids = new Map(), since = Date.now() - days * 86400000
  let lines = []
  try { lines = fs.readFileSync(path.join(root, 'state/requests.jsonl'), 'utf8').split('\n') } catch {}
  const rows = lines.flatMap(l => { try { const r = JSON.parse(l); return r && typeof r === 'object' ? [r] : [] } catch { return [] } })
  const queued = new Set(rows.filter(r => r.stage === 'queued').map(r => r.request_id))
  for (const row of rows) {
    if (!/^tg:-?\d+:\d+$/.test(row.request_id) || !Number.isFinite(row.ts) || row.ts < since) continue
    // Router 的確認也可能走 reply；有背景交接的 request 只採 tg-send 的最終答案。
    if (row.stage === 'answer-sent' && row.source === 'router' && queued.has(row.request_id)) continue
    if (!['received', 'ack', 'queued', 'worker-start', 'answer-sent'].includes(row.stage)) continue
    const stages = ids.get(row.request_id) || {}
    stages[row.stage] = Math.min(stages[row.stage] ?? Infinity, row.ts)
    ids.set(row.request_id, stages)
  }
  return [...ids].map(([request_id, s]) => {
    const diff = (a, b) => s[a] !== undefined && s[b] !== undefined && s[a] >= s[b] ? (s[a] - s[b]) / 1000 : null
    return { request_id, ack_s: diff('ack', 'received'), answer_s: diff('answer-sent', 'worker-start'),
      completion_s: diff('answer-sent', 'received'), queue_s: diff('queued', 'received'),
      start_s: diff('worker-start', 'queued'), stages: s }
  })
}
if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [cmd, root, stage, task, job] = process.argv.slice(2)
  if (cmd === 'report') { console.log(JSON.stringify(report(root, Number(stage)))); process.exit(0) }
  if (cmd === 'env-log') process.exit(record(root, stage, envIds()) ? 0 : 1)
  const ids = [...new Set([...requestIds(fs.readFileSync(task, 'utf8')), ...envIds()])]
  if (job && stage === 'worker-start') {
    const file = path.join(root, 'state/bg', `${job}.requests`)
    const tmp = `${file}.tmp.${process.pid}`
    fs.writeFileSync(tmp, JSON.stringify(ids)); fs.renameSync(tmp, file)
  }
  if (!record(root, stage, ids, job)) process.exitCode = 1
}
