const fs = require("fs"), path = require("path")
const [dir, days, mergeSec, detail] = [process.argv[2], Number(process.argv[3]), Number(process.argv[4]), process.argv[5] === "1"]
const stages = process.argv[6] === "1" // --stages：多印 samples（E1 --stages 用）
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
  const replyUse = new Map() // id → 登記時的輪（起點）
  let w = null                // 這一輪正在等回覆：{ start: 起點, last: 本輪最後一則 user, merged: 併筆數 }，null＝沒有在等
  // 壓縮重寫會把整條對話鏈追加到檔尾：user 保留原 timestamp、tool_result 改成壓縮當下 → 假延遲。
  // F2／E1：按身分去重，不靠時間單調。seenUser＝channel 標籤同時有 chat_id 與 message_id 時用
  // mid:<chat_id>:<message_id>（重播換了 timestamp 也同鍵），否則退回 timestamp＋內容；
  // seenUse＝reply tool_use id（重寫份同 id 不再登記，也就不能替重播的 user 消帳）。
  // ponytail: 集合按檔累積，單檔數萬行沒問題；真的爆量再改成只留最近 N 筆的 Map。
  const seenUser = new Set(), seenUse = new Set()
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
        const chat = /\bchat_id="([^"]*)"/.exec(c), mid = /\bmessage_id="(\d+)"/.exec(c)
        const hasMid = chat && mid ? "mid:" + chat[1] + ":" + mid[1] : null
        if (seenUser.has(hasMid ?? t + "\u0000" + c)) continue
        seenUser.add(hasMid ?? t + "\u0000" + c)
        if (w === null) {
          w = { start: t, last: t, merged: 0, mid: hasMid, firstA: null }
          cur = w
        } else if (t - w.last > mergeSec * 1000) {
          noReply++ // 上一輪沒回；這則另起一輪
          w = { start: t, last: t, merged: 0, mid: hasMid, firstA: null }
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
        const start = replyUse.get(x.tool_use_id)
        if (start === undefined || start !== w.start) continue
        replyUse.delete(x.tool_use_id)
        lat.push((t - w.start) / 1000)
        // E1 --stages 用：每個樣本的起點／第一次 reply／reply 結果／本輪第一則 user 的 message_id
        // E1 --stages 用：起點＝本輪第一則 user；first_assistant_ts＝本輪之後第一則 assistant 行；result 那行＝reply 完成／tool_result
        maxes.push({ s: (t - w.start) / 1000, start: w.start, user_ts: w.start, reply_ts: w.firstA, result_ts: t,
          mid: w.mid, merged: w.merged, file: f })
        w = null
        cur = null
        break
      }
      continue
    }
    if (o.type !== "assistant" || w === null) continue
    if (w.firstA === null || t < w.firstA) w.firstA = t
    if (!Array.isArray(c)) continue
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
  ...(detail ? { max_detail: top ? { max_s: top.s, start: new Date(top.start).toISOString(), merged: top.merged, file: top.file } : null } : {}),
  ...(stages ? { samples: maxes.map(m => ({ s: m.s, user_ts: m.user_ts, first_assistant_ts: m.reply_ts,
    reply_use_ts: m.result_ts, result_ts: m.result_ts, mid: m.mid ?? "", file: m.file })) } : {}) }))
