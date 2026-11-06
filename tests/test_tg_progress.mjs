// 自檢：進度訊息一回合只發一則、並行工具不重複發、節流後補 edit、Stop 刪掉、非 TG 回合與 telegram 工具不顯示、Bash 不外露指令全文
import fs from 'fs'
import os from 'os'
import path from 'path'
import http from 'http'
import assert from 'assert'
import { spawn } from 'child_process'

const BIN = process.env.TGP_BIN || new URL('../bin/tg-progress.mjs', import.meta.url).pathname  // 突變測試指向副本
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tgp-'))
const calls = []
let nextId = 500
const srv = http.createServer((req, res) => {
  let b = ''
  req.on('data', d => (b += d)).on('end', () => {
    const method = req.url.split('/').pop()
    calls.push({ method, body: JSON.parse(b) })
    res.setHeader('content-type', 'application/json')
    res.end(JSON.stringify({ ok: true, result: method === 'sendMessage' ? { message_id: nextId++ } : true }))
  })
}).listen(0)
await new Promise(r => srv.once('listening', r))
const env = { ...process.env, TG_API_BASE: `http://127.0.0.1:${srv.address().port}`, TELEGRAM_BOT_TOKEN: 'T', TG_PROGRESS_STATE: dir, TG_PROGRESS_LOG: path.join(dir, 'log') }

const tr = path.join(dir, 't.jsonl')
const writeTranscript = userText => fs.writeFileSync(tr, [
  { type: 'user', message: { content: userText }, ...(/^<channel /.test(userText) ? { isMeta: true, origin: { kind: 'channel', server: 'telegram' } } : {}) },
  { type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Bash' }] } },
  { type: 'user', message: { content: [{ type: 'tool_result', content: 'x' }] } },
].map(e => JSON.stringify(e)).join('\n') + '\n')
const run = (mode, h = {}) => new Promise(r => {
  const p = spawn('node', [BIN, mode], { env })
  p.stdin.end(JSON.stringify({ session_id: 's1', transcript_path: tr, ...h }))
  p.on('exit', code => r(code))
})
const pre = (tool_name, tool_input) => run('pre', { tool_name, tool_input })
const of = m => calls.filter(c => c.method === m)

writeTranscript('<channel source="telegram" chat_id="42" message_id="7" user="u"> 幫我查')
assert.equal(await pre('Read', { file_path: '/a/settings.json' }), 0)
await Promise.all([pre('Bash', { command: 'curl -H "Authorization: SECRET" x' }), pre('Grep', { pattern: 'foo' }), pre('mcp__telegram__reply', {})])
await new Promise(r => setTimeout(r, 300))
assert.equal(of('sendMessage').length, 1, '並行工具只發一則進度訊息')
assert.equal(of('sendMessage')[0].body.disable_notification, true, '進度訊息靜音')
assert.equal(of('sendMessage')[0].body.chat_id, '42')
const last = of('editMessageText').at(-1)
assert.ok(last, '節流後有補 edit')
assert.match(last.body.text, /第 3 步/, 'telegram 工具不算步驟')
assert.match(last.body.text, /讀 settings\.json/)
assert.match(last.body.text, /跑 curl/)
assert.ok(!JSON.stringify(calls).includes('SECRET'), 'Bash 指令全文不外露')
assert.equal(await run('stop'), 0)
assert.deepEqual(of('deleteMessage').map(c => c.body.message_id), [500], 'Stop 刪進度訊息')
await pre('Read', { file_path: '/b' }) // 回合已結束、同一則 inbound：不再發
assert.equal(of('sendMessage').length, 1, 'Stop 之後同回合不復活')

writeTranscript('<channel source="telegram" chat_id="42" message_id="8" user="u"> 下一題')
await pre('Read', { file_path: '/c' })
assert.equal(of('sendMessage').length, 2, '新 inbound＝新回合、新進度訊息')
await run('stop')

calls.length = 0
writeTranscript('[排程提醒] 檢查備份')
await pre('Read', { file_path: '/d' })
await run('stop')
assert.equal(calls.length, 0, '非 TG 來的回合不打 API')

// --worker（11-07）：chat 取 access.json allowFrom[0]、標題取 prompt 的「> 」原話、不送 typing、狀態檔每 session 一份且 Stop 後刪、不動 Router 的 progress.json
calls.length = 0
const tgDir = path.join(dir, 'tg'); fs.mkdirSync(tgDir)
fs.writeFileSync(path.join(tgDir, 'access.json'), JSON.stringify({ allowFrom: ['77'] }))
fs.writeFileSync(path.join(dir, 'progress.json'), '{"turn":"router-keep"}')
const wtr = path.join(dir, 'w.jsonl')
fs.writeFileSync(wtr, JSON.stringify({ type: 'user', message: { content: 'thread：t-a。老闆交辦：\n\n> 幫我把 log 輪替修好\n' } }) + '\n')
const runW = (mode, h = {}) => new Promise(r => {
  const p = spawn('node', [BIN, mode, '--worker'], { env: { ...env, TELEGRAM_STATE_DIR: tgDir } })
  p.stdin.end(JSON.stringify({ session_id: 'w9', transcript_path: wtr, ...h }))
  p.on('exit', code => r(code))
})
await runW('pre', { tool_name: 'Read', tool_input: { file_path: '/x/a.log' } })
assert.equal(of('sendMessage').length, 1, 'worker 第一步發一則')
assert.equal(of('sendMessage')[0].body.chat_id, '77', 'worker chat 取 allowFrom[0]')
assert.match(of('sendMessage')[0].body.text, /背景在做：幫我把 log 輪替修好/, 'worker 標題是老闆原話')
assert.equal(of('sendChatAction').length, 0, 'worker 不送 typing')
assert.ok(fs.existsSync(path.join(dir, 'progress-w-w9.json')), 'worker 狀態檔每 session 一份')
await runW('stop')
assert.equal(of('deleteMessage').length, 1, 'worker Stop 刪進度訊息')
assert.ok(!fs.existsSync(path.join(dir, 'progress-w-w9.json')), 'worker Stop 後刪狀態檔')
assert.equal(fs.readFileSync(path.join(dir, 'progress.json'), 'utf8'), '{"turn":"router-keep"}', 'worker 不動 Router 的狀態')

srv.close()
fs.rmSync(dir, { recursive: true })
console.log('PASS')
