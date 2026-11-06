// 11-07 Codex P1：Router 用 bin/quick／bin/recall／bin/dispatch-bg 處理掉的訊息不回 reply，
// chat-prompt 要把這些 Bash 呼叫當 Router 邊界，下一次 --from-chat 才不會把已處理的舊問題一起派出去
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { items, build } from '../bin/chat-prompt.mjs'

const u = t => JSON.stringify({ type: 'user', origin: { kind: 'channel' }, message: { content: `<channel source="telegram">\n${t}\n</channel>` } })
const bash = cmd => JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Bash', input: { command: cmd } }] } })
const reply = t => JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'mcp__telegram__reply', input: { text: t } }] } })

test('quick／recall 處理過的舊問題不混進新交辦', () => {
  const lines = [u('A 服務在嗎'), bash("bin/quick /Users/x '服務在嗎'"), u('B 以前怎麼定的'), bash("bin/recall '訂閱' --ask 'B'"), u('C 幫我修 log'), bash('bin/dispatch-bg --from-chat t-c')]
  const p = build(items(lines), 't-c')
  assert.match(p, /> C 幫我修 log/)
  assert.doesNotMatch(p, /> A 服務在嗎/)
  assert.doesNotMatch(p, /> B 以前怎麼定的/)
})

test('上一張 dispatch-bg 之後追加的才是新交辦；其他 Bash 不算邊界', () => {
  const lines = [u('X'), bash('bin/dispatch-bg --from-chat t-x'), reply('收到'), u('Y1'), bash('ls'), u('Y2')]
  const p = build(items(lines), 't-y')
  assert.match(p, /> Y1/)
  assert.match(p, /> Y2/)
  assert.doesNotMatch(p, /> X\n/)
})
