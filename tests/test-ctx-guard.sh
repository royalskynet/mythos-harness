#!/usr/bin/env bash
# ctx-guard 測試：假 transcript，超過閾值被標出、低於不標；advisor 加總不算；Router/worker 動作用 stub。
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
G="${CTX_GUARD_BIN:-$HERE/bin/ctx-guard}"  # 突變測試指向副本，不改現役檔
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
TMP="$T"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"
fail=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
mk() { # 檔 input cache_create cache_read [iterations-json]
  printf '{"type":"assistant","message":{"model":"claude-x","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":5%s}}}\n' "$2" "$3" "$4" "${5:+,\"iterations\":$5}" >> "$1"
}
R="$T/proj/-r"; W="$T/proj/-w"; mkdir -p "$R" "$W" "$T/state" "$T/bin"
mk "$R/aaaaaaaa-0000.jsonl" 4 2000 150000        # 152K：不標
mk "$W/bbbbbbbb-0000.jsonl" 4 2000 185000        # 187K：warn
mk "$W/cccccccc-0000.jsonl" 4 2000 205000        # 207K：over，bg pending
# 11-06 實測：advisor 讓頂層 usage 變 2 倍（33 萬），真 context 是最後一次主模型 message（16.5 萬）
mk "$R/dddddddd-0000.jsonl" 4 2295 330992 '[{"type":"message","input_tokens":2,"cache_creation_input_tokens":732,"cache_read_input_tokens":165130},{"type":"advisor_message","input_tokens":168561},{"type":"message","input_tokens":2,"cache_creation_input_tokens":1563,"cache_read_input_tokens":165862}]'
printf 'bg-cccccccc\tmid\tx\t1\tpending\t/w\tt-x\tbg\n' > "$T/state/dispatch-jobs.tsv"
printf '#!/bin/sh\necho "$@" >> %s/claude.calls\n' "$T" > "$T/bin/claude"; chmod +x "$T/bin/claude"
export CTX_DIRS="$R:$W" CTX_ROUTER_DIR="$R" CTX_STATE_DIR="$T/state" CTX_LOG="$T/log" CTX_CLAUDE_BIN="$T/bin/claude" MYTHOS_DIR="$T"
export CTX_TMUX_BIN=/usr/bin/false

L="$("$G" list)"
echo "$L" | grep -q 'aaaaaaaa' && echo "$L" | grep aaaaaaaa | grep -q ' ok ' && ok "152K 不標" || bad "152K 應為 ok"
echo "$L" | grep bbbbbbbb | grep -q 'WARN' && ok "187K 標 WARN" || bad "187K 應 WARN"
echo "$L" | grep cccccccc | grep -q 'OVER' && ok "207K 標 OVER" || bad "207K 應 OVER"
echo "$L" | grep dddddddd | grep -q ' ok .*167427' && ok "advisor 加總不算（16.5 萬 ok）" || bad "advisor 加總被誤算：$(echo "$L" | grep dddddddd)"

"$G" scan
grep -q 'OVER job\|OVER bg-cccccccc' "$T/log" && ok "log 有 OVER bg-cccccccc" || bad "log 缺 OVER：$(cat "$T/log" 2>/dev/null)"
grep -q 'WARN worker.*bbbbbbbb' "$T/log" && ok "log 有 WARN" || bad "log 缺 WARN"
grep -q 'aaaaaaaa\|dddddddd' "$T/log" && bad "低於閾值不該進 log" || ok "低於閾值不進 log"
grep -q 'stop cccccccc' "$T/claude.calls" 2>/dev/null && ok "超限 worker 被 claude stop" || bad "沒 stop：$(cat "$T/claude.calls" 2>/dev/null)"
grep -q 'bbbbbbbb' "$T/claude.calls" 2>/dev/null && bad "warn 不該 stop" || ok "warn 不 stop"
"$G" note bg-cccccccc | grep -q '207K' && ok "note 標 207K" || bad "note 缺"
"$G" notices | grep -q 'bg-cccccccc' && ok "notices 有超限事件" || bad "notices 缺"
n1="$(wc -l < "$T/log")"; "$G" scan; [ "$(wc -l < "$T/log")" = "$n1" ] && ok "重複掃描不洗版" || bad "log 洗版"
"$G" ack-notices; [ -z "$("$G" notices)" ] && ok "ack 後清空" || bad "ack 失敗"

# Router 超限：stub tmux 記錄送鍵（pane 閒置）
cat > "$T/bin/tmux" <<S
#!/bin/sh
case "\$*" in *capture-pane*) echo '❯' ;; *) echo "\$*" >> $T/tmux.calls ;; esac
S
chmod +x "$T/bin/tmux"; export CTX_TMUX_BIN="$T/bin/tmux"
# 同一測試有多輪獨立 transcript fixture；上一輪的 compact 先明確完成。
finish_compact() {
  python3 - <<'PYDONE'
import json, os
f=os.path.join(os.environ['MYTHOS_DIR'], 'state', 'router-compact.lock')
if os.path.exists(f):
    lk=json.load(open(f))
    with open(lk['transcript'], 'a') as out: out.write('{"type":"system","subtype":"compact_boundary"}\n')
PYDONE
}
mk "$R/eeeeeeee-0000.jsonl" 4 2000 210000
"$G" scan
grep -q -- '-l /compact' "$T/tmux.calls" 2>/dev/null && ok "Router 超限送 /compact" || bad "Router 沒送 compact"
c1="$(wc -l < "$T/tmux.calls")"; "$G" scan; [ "$(wc -l < "$T/tmux.calls")" = "$c1" ] && ok "冷卻內不重送" || bad "重複送 compact"

# 閒置提早壓縮（11-07）：Router 最新 session 150K、pane 閒、10 分鐘沒動 → 送 /compact；剛動過、或不是最新那個 → 不送
finish_compact
R2="$T/proj/-r2"; mkdir -p "$R2"; : > "$T/tmux.calls"
mk "$R2/ffffffff-0000.jsonl" 4 2000 148000; touch -t "$(date -v-10M +%Y%m%d%H%M)" "$R2/ffffffff-0000.jsonl"
mk "$R2/99999999-0000.jsonl" 4 2000 160000; touch -t "$(date -v-30M +%Y%m%d%H%M)" "$R2/99999999-0000.jsonl"
CTX_DIRS="$R2" CTX_ROUTER_DIR="$R2" CTX_STATE_DIR="$T/state2" "$G" scan
grep -q -- '-l /compact' "$T/tmux.calls" && ok "閒置 150K 提早送 /compact" || bad "閒置沒送 compact：$(cat "$T/log" | tail -3)"
grep -q 'idle /compact sent (tokens=150004)' "$T/log" && ! grep -q 'idle /compact sent (tokens=162004)' "$T/log" && ok "只壓最新那個 session" || bad "壓錯 session：$(grep idle "$T/log")"
: > "$T/tmux.calls"; touch "$R2/ffffffff-0000.jsonl"
CTX_DIRS="$R2" CTX_ROUTER_DIR="$R2" CTX_STATE_DIR="$T/state3" "$G" scan
[ -s "$T/tmux.calls" ] && bad "剛動過不該壓縮" || ok "老闆剛在聊就不壓縮"
: > "$T/tmux.calls"; touch -t "$(date -v-10M +%Y%m%d%H%M)" "$R2/ffffffff-0000.jsonl"
CTX_ROUTER_IDLE=0 CTX_DIRS="$R2" CTX_ROUTER_DIR="$R2" CTX_STATE_DIR="$T/state4" "$G" scan
[ -s "$T/tmux.calls" ] && bad "CTX_ROUTER_IDLE=0 應關閉" || ok "CTX_ROUTER_IDLE=0 關閉"

# 突變：把閾值拉高，208K 的 session 就不該被標
CTX_LIMIT=999999 CTX_WARN=999999 "$G" list | grep -q 'OVER\|WARN' && bad "閾值突變仍標出" || ok "閾值拉高就不標（突變）"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "SOME FAIL"; exit 1; }
