// 自檢：/ctx 摘要解析、忙碌偵測（10-07：忙碌中送 /context 會被 Escape 打斷工具、並回原文）
import fs from 'fs'
import assert from 'assert'
const src = fs.readFileSync(new URL('../bin/tg-commands.mjs', import.meta.url), 'utf8')
const pick = re => src.match(re)[0]
const formatContext = new Function(pick(/^const kNum[^\n]*\n/m) + pick(/^function formatContext[\s\S]*?^}\n/m) + 'return formatContext')()
const busyRe = new RegExp(src.match(/const isBusy = .*?\/(.+?)\/\.test/)[1])

const pane = `  ⎿  Context Usage
     ⛁ ⛀ ⛁   131.7k/200k tokens (66%)
     ⛁ ⛁   ⛁ System prompt: 8.7k tokens (4.3%)
                           ⛁ Messages: 87.3k tokens (43.6%)
                           ⛶ Free space: 35.3k (17.6%)
                           ⛝ Autocompact buffer: 33k tokens (16.5%)
     Auto-compact window: 200k tokens
     MCP tools · /mcp`
const out = formatContext(pane)
assert.match(out, /Context：131\.7k \/ 200k（66%）/)
assert.ok(out.indexOf('Messages') < out.indexOf('System prompt'), '照大小排序')
assert.match(out, /可用 35\.3k/)
assert.ok(!out.includes('MCP tools ·'), '明細清單不進摘要')
assert.equal(formatContext('no header here'), null)
assert.ok(busyRe.test('  ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt · ← 2 agents'))
assert.ok(!busyRe.test('  ⏵⏵ bypass permissions on (shift+tab to cycle)'))
assert.match(src, /deepclaude: async chat =>/)
assert.match(src, /exec\('\/bin\/bash', \[DEEPCLAUDE_START\]\)/)
assert.match(src, /command: 'deepclaude'/)
// /fix：展開 fix.md（去 frontmatter、代入 $ARGUMENTS），選單與說明表都要有
const expandFix = new Function('fs', 'FIX_MD', pick(/^export function expandFix[\s\S]*?^}\n/m).replace('export ', '') + 'return expandFix')(fs, '/dev/null')
const md = '---\ndescription: x\n---\n\n症狀：$ARGUMENTS\n\n## 1. 首輪'
assert.equal(expandFix('boom', md), '\n症狀：boom\n\n## 1. 首輪')
assert.ok(!expandFix('boom', md).includes('description:'), 'frontmatter 要剝掉')
assert.match(expandFix('', md), /未附症狀/)
assert.match(src, /command: 'fix'/)
assert.match(src, /name === 'fix'/)
const real = expandFix('X123', fs.readFileSync(process.env.HOME + '/.claude/commands/fix.md', 'utf8'))
assert.ok(real.includes('症狀：X123') && !real.includes('$ARGUMENTS'), '真實 fix.md 展開')
console.log('PASS')

// /wheel：展開 wheel.md，選單與說明表都要有（不 import 模組：import 會啟動 proxy 搶 poller）
assert.match(src, /command: 'wheel'/)
assert.match(src, /name === 'wheel'/)
assert.match(src, /\/wheel <問題>/)
const expandWheel = new Function('fs', 'WHEEL_MD', pick(/^export function expandWheel[\s\S]*?^}\n/m).replace('export ', '') + 'return expandWheel')(fs, '/dev/null')
const w = expandWheel('Q789', fs.readFileSync(process.env.HOME + '/.claude/commands/wheel.md', 'utf8'))
assert.ok(w.includes('Q789') && !w.includes('$ARGUMENTS') && !w.startsWith('---'), '真實 wheel.md 展開')
console.log('PASS wheel')
