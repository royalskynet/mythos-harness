// 與 ctx-guard 共用 O_EXCL lock 的期限；格式不完整時保守排隊，依 mtime 最遲 600 秒後釋放。
import fs from 'node:fs'
import path from 'node:path'
export function compactLocked(root) {
  const file = path.join(root, 'state/router-compact.lock')
  try {
    const stat = fs.statSync(file)
    let expires = stat.mtimeMs + 600_000
    try { const lk = JSON.parse(fs.readFileSync(file, 'utf8')); if (Number.isFinite(lk.expires)) expires = Math.min(expires, lk.expires * 1000) } catch {}
    if (Date.now() < expires) return true
    fs.unlinkSync(file)
  } catch (e) { if (e.code !== 'ENOENT') return true }
  return false
}
