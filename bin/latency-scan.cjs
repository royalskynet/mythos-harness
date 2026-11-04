const fs = require("fs"), path = require("path")
const [dir, days, mergeSec, detail] = [process.argv[2], Number(process.argv[3]), Number(process.argv[4]), process.argv[5] === "1"]
const since = Date.now() - days * 86400000
const lat = []
const maxes = []
let pending = 0, noReply = 0
let cur = null // 檔尾還開著的輪（有起點才算 pending_tail）
for (const f of fs.readdirSync(dir)) {
  if (!f.endsWith(".jsonl")) continue
  let st
  try { st = fs.statSync(path.join(dir, f)) } catch { continue }
  if (st.mtimeMs < since) continue
  let lines
  try { lines = fs.readFileSync(path.join(dir, f), "utf8").split("\n") } catch { continue }
  // 輪＝{ start: 起點（第一則 user）, last: 本輪最後一則 user, merged: 併筆數 }
  // ponytail: replyUse 收整檔每個 reply tool_use id → 當時 waiting 起點；單檔數萬行還撐得住，再大就改成邊掃邊記
  const replyUse = new Map() // id → 登記時的輪
  let w = null                // 這一輪正在等回覆：{ start: 起點, last: 本輪最後一則 user, merged: 併筆數 }，null＝沒有在等
  // 壓縮重寫會把整條對話鏈追加到檔尾：user 保留原 timestamp、tool_result 改成壓縮當下 → 假延遲。
  // F2：按身分去重，不靠時間單調。seenUser＝user 原 timestamp＋內容（重寫份整則跳過）；
  // seenUse＝reply tool_use id（重寫份同 id 不覆寫原本的登記）；settled＝已結算的 tool_use id（再出現的結果不結算）。
  // ponytail: 三個集合都按檔累積，單檔數萬行沒問題；真的爆量再改成只留最近 N 筆的 Map。
  const seenUser = new Set(), seenUse = new Set(), settled = new Set()
  for (const line of lines) {
    if (!line) continue
    let o
    try { o = JSON.parse(line) } catch { continue }
    const t = Date.parse(o.timestamp || "")
    if (!Number.isFinite(t)) continue
    if (!(t >= since)) continue
    const c = o.message && o.message.content
    if (o.type === "user") {
      if (typeof c === "string") {
        if (!c.includes('<channel source="telegram"')) continue
        const key = t + "\u0000" + c
        if (seenUser.has(key)) continue
        seenUser.add(key)
        if (w === null) {
          w = { start: t, last: t, merged: 0 }
          cur = w
        } else if (t - w.last > mergeSec * 1000) {
          noReply++ // 上一輪沒回；這則另起一輪
          w = { start: t, last: t, merged: 0 }
          cur = w
        } else {
          w.last = t
          w.merged++
        }
        continue
      }
      if (!Array.isArray(c) || w === null) continue
      for (const x of c) {
        if (!x || x.type !== "tool_result" || x.is_error === true) continue
        if (settled.has(x.tool_use_id)) continue
        const start = replyUse.get(x.tool_use_id)
        if (start === undefined || start !== w.start) continue
        replyUse.delete(x.tool_use_id)
        settled.add(x.tool_use_id)
        lat.push((t - w.start) / 1000)
        maxes.push({ s: (t - w.start) / 1000, start: w.start, merged: w.merged, file: f })
        w = null
        cur = null
        break
      }
      continue
    }
    if (o.type !== "assistant" || !Array.isArray(c) || w === null) continue
    for (const x of c) {
      if (!x || x.type !== "tool_use" || !x.id || !/__reply$/.test(x.name || "")) continue
      if (seenUse.has(x.id)) continue
      seenUse.add(x.id)
      replyUse.set(x.id, w.start)
    }
  }
  if (cur !== null) pending++ // 這檔檔尾還在等
  cur = null
}
const ok = lat.slice().sort((a, b) => a - b)
const rank = p => ok.length ? ok[Math.ceil(p * ok.length) - 1] : 0
const top = maxes.reduce((a, b) => (!a || b.s > a.s ? b : a), null)
console.log(JSON.stringify({ n: lat.length, p50_s: rank(0.5), p90_s: rank(0.9), max_s: ok.length ? ok[ok.length - 1] : 0,
  over60: ok.filter(x => x > 60).length, no_reply: noReply, pending_tail: pending,
  ...(detail ? { max_detail: top ? { max_s: top.s, start: new Date(top.start).toISOString(), merged: top.merged, file: top.file } : null } : {}) }))
