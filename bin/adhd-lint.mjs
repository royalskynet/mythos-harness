#!/usr/bin/env node
// ADHD 格式（Telegram 版）機械檢查，零 LLM、零依賴。
// 五條：
// 1. 第一行＝結論；有要老闆做的事，第一行就寫那件事。
// 2. 兩件以上用編號 `1.` `2.`，一項一行一件事，最多 3 項；全文 220 字內。
// 3. 進行中的事寫具體時間（約 10 分鐘、今晚 02:00），不寫「稍後」「後續」。
// 4. 做完的事寫「已完成」放前面。
// 5. 不寫安撫、預告、客套句（您可以放心、有結果再跟您回報、目前沒有需要您決定的事、我這邊的理解是）。
// 其餘：不貼 job id、thread 代號、commit、路徑、英文術語。
// 數字上限（環境變數可覆寫）：ADHD_MAX_CHARS=220, ADHD_MAX_LINES=6, ADHD_MAX_LINE_CHARS=40
import { fileURLToPath } from 'node:url'

const MAX_CHARS = Number(process.env.ADHD_MAX_CHARS) || 220
const MAX_LINES = Number(process.env.ADHD_MAX_LINES) || 6
const MAX_LINE_CHARS = Number(process.env.ADHD_MAX_LINE_CHARS) || 40
const FILLER_RE = /您可以(先)?放心|(有結果|做完|後續)[^。\n]{0,8}(再|會)(跟|向)?您回報|目前沒有需要您決定|我這邊的理解是|請您放心/g

export function adhdLint(text) {
  const t = String(text ?? '').replace(/\r\n?/g, '\n').trim()
  if (!t) return []
  const stripped = t.replace(/\s+/g, '')
  if (stripped.length <= 12) return []
  const lines = t.split('\n').map(l => l.trimEnd())
  const nonEmpty = lines.filter(l => l.trim() !== '')
  const errs = []
  if (stripped.length > MAX_CHARS) errs.push(`太長 ${stripped.length} 字，上限 ${MAX_CHARS}`)
  if (nonEmpty.length > MAX_LINES) errs.push(`超過 ${MAX_LINES} 行`)
  nonEmpty.forEach((l, i) => {
    if (l.length > MAX_LINE_CHARS) errs.push(`第 ${i + 1} 行 ${l.length} 字，上限 ${MAX_LINE_CHARS}`)
  })
  if (nonEmpty.length >= 3) {
    for (let i = 1; i < nonEmpty.length; i++) {
      if (!/^\d+\.\s/.test(nonEmpty[i])) { errs.push('多件事要編號'); break }
    }
  }
  FILLER_RE.lastIndex = 0
  let m
  while ((m = FILLER_RE.exec(t))) errs.push(`客套句：${m[0]}`)
  return errs
}

function main() {
  let buf = ''
  process.stdin.setEncoding('utf8')
  process.stdin.on('data', c => (buf += c))
  process.stdin.on('end', () => {
    const errs = adhdLint(buf)
    if (errs.length) {
      for (const e of errs) process.stderr.write(e + '\n')
      process.exit(1)
    }
    process.exit(0)
  })
}

if (process.argv[1] && fileURLToPath(import.meta.url).endsWith(process.argv[1].replace(/.*\//, ''))) main()
