#!/usr/bin/env bash
# 驗收：watchdog v2（計畫「預防加固」7 條）。LLM、scrub、claude agents、tmux、canary 全用 stub，
# PATH 前面再墊假的 curl／opencode：有人想出網就記一筆，最後檢查必須是空的。
# 用法：bash tests/test-watchdog.sh            （預設測 bin/watchdog）
#       WD_BIN=<別份 watchdog> bash tests/test-watchdog.sh   （突變驗證用）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WD_BIN="${WD_BIN:-$ROOT/bin/watchdog}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wd-v2-test.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export TMP

S="$TMP/stubs"; mkdir -p "$S" "$TMP/home" "$TMP/router" "$TMP/projects"
: > "$TMP/net.log"

# ---- 出網守門：假 curl／opencode，被叫到就記下來並失敗 ----
for b in curl opencode; do
  printf '#!/bin/sh\necho "%s $*" >> "$TMP/net.log"\nexit 7\n' "$b" > "$S/$b"; chmod +x "$S/$b"
done
export PATH="$S:$PATH"

# ---- 假 LLM：記呼叫（名字＋收到的 prompt）、印固定內容 ----
mk_llm() { # 名字 輸出 [rc]
  cat > "$S/$1" <<EOF
#!/usr/bin/env bash
p="\$(cat)"
echo "$1" >> "\$TMP/llm-calls"
printf '%s\n===\n' "\$p" >> "\$TMP/llm-prompts"
printf '%s\n' "$2"
exit ${3:-0}
EOF
  chmod +x "$S/$1"
}
# 逾時的棒：exec sleep，被 run_to 整組砍掉，不留背景 sleep
cat > "$S/llm-hang" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "llm-hang" >> "$TMP/llm-calls"
echo $$ > "$TMP/hang.pid"
exec sleep 30
EOF
chmod +x "$S/llm-hang"

# ---- 假 canary：收到的 payload 記下來；看到假憑證樣式就 exit 2（同 sensitive-canary 的擋下碼）----
cat > "$S/canary" <<'EOF'
#!/usr/bin/env bash
p="$(cat)"
printf '%s\n===\n' "$p" >> "$TMP/canary-in"
pk='PRIV''ATE KEY'
if printf '%s' "$p" | grep -qE "gh[p]_[A-Za-z0-9]{20,}|BEGIN [A-Z ]*${pk}"; then exit 2; fi
exit 0
EOF
chmod +x "$S/canary"

# ---- 假 scrub：good 把假 PII 換成佔位；bad 原樣回傳 ----
cat > "$S/scrub-good" <<'EOF'
#!/usr/bin/env bash
echo x >> "$TMP/scrub-calls"
jq -c '{texts: [.texts[0] | gsub("0912-345-678"; "<PHONE>") | gsub("0x[0-9A-Fa-f]{40}"; "<WALLET>") | gsub("[A-Za-z0-9._-]+@[A-Za-z0-9.-]+"; "<EMAIL>")]}'
EOF
cat > "$S/scrub-bad" <<'EOF'
#!/usr/bin/env bash
echo x >> "$TMP/scrub-calls"
cat
EOF
chmod +x "$S/scrub-good" "$S/scrub-bad"

# ---- 假 claude agents／tmux ----
cat > "$S/claude" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "agents --json" ] || exit 1
cat "$TMP/agents.json" 2>/dev/null || echo '[]'
EOF
cat > "$S/tmux" <<'EOF'
#!/usr/bin/env bash
[ "$1" = ls ] && cat "$TMP/tmux-sessions" 2>/dev/null
exit 0
EOF
chmod +x "$S/claude" "$S/tmux"

export HOME="$TMP/home"
export MYTHOS_TRANSCRIPT_DIR="$TMP/router"
export CLAUDE_PROJECTS_DIR="$TMP/projects"
export TMUX_BIN="$S/tmux"
export WATCHDOG_CLAUDE_BIN="$S/claude"
export WATCHDOG_CANARY_CMD="$S/canary"
export WATCHDOG_LLM_TIMEOUT_S=3

# 每個情境一個乾淨的 MYTHOS_DIR／brief 目錄與計數檔
case_init() {
  C="$TMP/case-$1"
  mkdir -p "$C/mythos/state/deep" "$C/mythos/logs" "$C/brief"
  export MYTHOS_DIR="$C/mythos" MYTHOS_BRIEF_DIR="$C/brief"
  BRIEF="$C/brief/mythos-watchdog.tsv"
  WLOG="$MYTHOS_DIR/logs/watchdog.log"
  rm -f "$TMP/llm-calls" "$TMP/llm-prompts" "$TMP/canary-in" "$TMP/scrub-calls" "$TMP/agents.json" "$TMP/tmux-sessions"
  : > "$MYTHOS_DIR/logs/app.log"
  export WATCHDOG_LLM_LEGS="$S/llm-a"
  export WATCHDOG_L2_LEGS="$S/l2-a;$S/l2-b"
  export WATCHDOG_SCRUB_CMD="$S/scrub-good"
  unset WATCHDOG_L1_MAX_PER_HOUR WATCHDOG_CANARY_DIR
  export WATCHDOG_CANARY_CMD="$S/canary"
}
run_wd() { bash "$WD_BIN" "$@"; }
calls() { [ -f "$TMP/llm-calls" ] && wc -l < "$TMP/llm-calls" | tr -d ' ' || echo 0; }
calls_of() { if [ -f "$TMP/llm-calls" ]; then grep -c -x "$1" "$TMP/llm-calls" || true; else echo 0; fi; }
addlog() { printf '%s\n' "$*" >> "$MYTHOS_DIR/logs/app.log"; }
ago() { date -r $(( $(date +%s) - $1 )) '+%Y%m%d%H%M.%S'; }

# 假憑證／家目錄路徑：執行時才組出來，檔案裡不留字面值
FAKE_TOK="gh""p_Ab3De5Gh7Jk9Mn1Pq3St5Vw7Yz9Bc1Ef3Hi5"

# =============== 1. L0 判得出的情境 → LLM 呼叫數＝0 ===============
case_init l0
mk_llm llm-a "1 NOISE"
now=$(date +%s)
# pending 超過 6 小時
printf 'o-old\tmid\t/x/task.md\t%s\tpending\t/x\t-\tdcq\n' $((now - 30000)) > "$MYTHOS_DIR/state/dispatch-jobs.tsv"
# deep session 在、transcript 20 分鐘沒動
printf 'deep-%s-4242\n' "$now" > "$TMP/tmux-sessions"
printf 'deep-%s\trunning-deep\t/x/deep.md\t%s\trunning\t/work/proj\t-\tdeep\n' 77 "$now" >> "$MYTHOS_DIR/state/dispatch-jobs.tsv"
printf 'pid=1\ndeep_pid=4242\nsession=deep-%s-4242\n' "$now" > "$MYTHOS_DIR/state/deep/deep-77.handle"
mkdir -p "$CLAUDE_PROJECTS_DIR/-work-proj"
: > "$CLAUDE_PROJECTS_DIR/-work-proj/t.jsonl"; touch -t "$(ago 1200)" "$CLAUDE_PROJECTS_DIR/-work-proj/t.jsonl"
# 背景 worker blocked，第一次看到是 11 分鐘前
printf '[{"id":"bg1","kind":"background","state":"blocked","name":"x"},{"id":"bg2","kind":"background","state":"stopped"}]' > "$TMP/agents.json"
printf '{"alerted":{},"bg_blocked":{"bg1":%s}}\n' $((now - 660)) > "$MYTHOS_DIR/state/watchdog.json"
addlog "INFO all good"
run_wd
addlog "INFO still fine"
run_wd
[ "$(calls)" = 0 ] || fail "1：L0 情境叫了模型 $(calls) 次"
grep -q '卡在 pending' "$BRIEF" || fail "1：pending 沒告警"
grep -q 'deep session deep-' "$BRIEF" || fail "1：deep 停滯沒告警：$(cat "$BRIEF")"
grep -q '背景 agent bg1' "$BRIEF" || fail "1：bg blocked 沒告警"
grep -q 'bg2' "$BRIEF" && fail "1：stopped 的 bg 不該告警"
[ ! -s "$MYTHOS_DIR/state/watchdog-pending.jsonl" ] || fail "1：沒有錯誤行卻進了待判"
[ "$(wc -l < "$BRIEF" | tr -d ' ')" = 3 ] || fail "1：第二輪重複告警：$(cat "$BRIEF")"

# =============== 2. 待判非空 → 呼叫一次；每小時上限生效 ===============
case_init cap
export WATCHDOG_L1_MAX_PER_HOUR=2
mk_llm llm-a "1 NEW 設定檔被改壞"
addlog "ERROR old history line"          # 第一次看到的檔從尾巴開始，不翻舊帳
run_wd
[ "$(calls)" = 0 ] || fail "2：舊行被翻出來送模型"
addlog "ERROR alpha failed"
run_wd
[ "$(calls)" = 1 ] || fail "2：待判 1 項應叫 1 次，實際 $(calls)"
grep -q 'Watchdog 新問題' "$BRIEF" || fail "2：NEW 沒寫 brief"
run_wd
[ "$(calls)" = 1 ] || fail "2：沒有新錯誤行還叫模型"
addlog "Traceback (most recent call last): beta"
run_wd
[ "$(calls)" = 2 ] || fail "2：第二項應叫第 2 次"
addlog "job rc=3 gamma"
run_wd
[ "$(calls)" = 2 ] || fail "2：每小時上限 2 沒生效（叫了 $(calls) 次）"
grep -q 'gamma' "$MYTHOS_DIR/state/watchdog-pending.jsonl" || fail "2：超過上限的待判沒留到下輪"
grep -q '上限 2' "$WLOG" || fail "2：上限沒寫 log"

# =============== 3. 白名單：假憑證行／合規專案路徑 → canary 命中、LLM 未叫、走退路 ===============
wl_case() { # 名稱 → 回 0＝行為正確
  case_init "$1"
  mk_llm llm-a "1 NOISE"
  printf 'read failed\t讀檔失敗\n' > "$MYTHOS_DIR/state/watchdog-known.tsv"
  run_wd
  addlog "ERROR upload with token $FAKE_TOK"
  addlog "ERROR read failed $HOME/bots/carrie/notes.md"
  run_wd
  [ "$(calls)" = 0 ] || { echo "LLM 被叫了 $(calls) 次" >&2; return 1; }
  grep -q '判不了' "$BRIEF" || { echo "假憑證行沒走到「判不了」" >&2; return 1; }
  grep -q "$FAKE_TOK" "$BRIEF" && { echo "brief 洩了假憑證" >&2; return 1; }
  grep -q 'FALLBACK KNOWN 讀檔失敗' "$WLOG" || { echo "合規路徑行沒走規則表" >&2; return 1; }
  return 0
}
wl_case wl || fail "3：白名單／canary 行為不對"
[ -s "$TMP/canary-in" ] || fail "3：canary 沒被呼叫"
grep -q "$FAKE_TOK" "$TMP/canary-in" || fail "3：canary 沒掃到假憑證行"
grep -qi 'carrie' "$TMP/canary-in" && fail "3：合規專案路徑沒在白名單階段丟掉"
grep -q "$TMP/home" "$TMP/canary-in" && fail "3：家目錄沒遮"
# 找不到 canary 入口 → 內建 regex 也要擋
case_init wl-builtin
mk_llm llm-a "1 NOISE"
unset WATCHDOG_CANARY_CMD; export WATCHDOG_CANARY_DIR="$TMP/no-canary"
run_wd
addlog "ERROR upload with token $FAKE_TOK"
run_wd
[ "$(calls)" = 0 ] || fail "3b：沒 canary 入口時內建 regex 沒擋"
grep -q '判不了' "$BRIEF" || fail "3b：內建 regex 擋下後沒走退路"
# 乾淨的行照常送，送出去的 payload 只有白名單欄位、家目錄已遮
case_init wl-clean
mk_llm llm-a "1 NOISE"
now=$(date +%s)
printf 'o-x1\tmid\t%s\t%s\trunning\t/x\t-\tdcq\n' "$MYTHOS_DIR/task.md" $((now - 100)) > "$MYTHOS_DIR/state/dispatch-jobs.tsv"
printf '# t\n## 目標\n修好 foo 的路徑\n## 驗收\nbash x\n' > "$MYTHOS_DIR/task.md"
run_wd
addlog "ERROR job o-x1 failed at $HOME/dev/foo.js"
run_wd
[ "$(calls)" = 1 ] || fail "3c：乾淨行沒送模型"
grep -q 'job_id=o-x1 backend=dcq status=running age_s=' "$TMP/llm-prompts" || fail "3c：payload 少了 job 欄位"
grep -q '修好 foo 的路徑' "$TMP/llm-prompts" || fail "3c：payload 少了工單目標段"
grep -q 'bash x' "$TMP/llm-prompts" && fail "3c：目標段以外的工單內容出機了"
grep -q "$TMP/home" "$TMP/llm-prompts" && fail "3c：家目錄沒遮就出機"

# =============== 4. canary 自檢：scrub 原樣回傳 → 當天 L1 停、brief「scrub 失效」 ===============
case_init selfcheck
mk_llm llm-a "1 NOISE"
export WATCHDOG_SCRUB_CMD="$S/scrub-bad"
run_wd
addlog "ERROR delta broke"
run_wd
[ "$(calls)" = 0 ] || fail "4：scrub 失效還叫模型"
grep -q 'scrub 失效' "$BRIEF" || fail "4：brief 沒有「scrub 失效」"
addlog "ERROR epsilon broke"
run_wd
[ "$(calls)" = 0 ] || fail "4：當天第二輪還叫模型"
[ "$(wc -l < "$TMP/scrub-calls" | tr -d ' ')" = 1 ] || fail "4：自檢應一天一次"
# 正常的 scrub：自檢過、照常叫
case_init selfcheck-ok
mk_llm llm-a "1 NOISE"
run_wd; addlog "ERROR zeta"; run_wd
[ "$(calls)" = 1 ] || fail "4b：scrub 正常卻沒叫模型"
grep -q 'scrub 失效' "$BRIEF" 2>/dev/null && fail "4b：scrub 正常卻告警"

# =============== 5. 退路：前三棒全失敗 → known.tsv 命中採用；不命中 → brief「判不了」 ===============
case_init fallback
mk_llm llm-a "" 1
mk_llm llm-b "我覺得還好"
export WATCHDOG_LLM_LEGS="$S/llm-a;$S/llm-b x;$S/llm-hang"
printf '# 註解\ndisk full\t磁碟滿\n' > "$MYTHOS_DIR/state/watchdog-known.tsv"
run_wd
addlog "ERROR disk full on /tmp"
addlog "ERROR mystery thing"
t0=$(date +%s)
run_wd
[ $(( $(date +%s) - t0 )) -lt 20 ] || fail "5：逾時那棒沒被硬砍"
[ "$(calls_of llm-a)" = 1 ] && [ "$(calls_of llm-b)" = 1 ] && [ "$(calls_of llm-hang)" = 1 ] || fail "5：三棒沒各跑一次：$(cat "$TMP/llm-calls")"
grep -q 'FALLBACK KNOWN 磁碟滿' "$WLOG" || fail "5：known.tsv 命中沒採用"
grep -q '判不了.*mystery' "$BRIEF" || fail "5：不命中沒寫「判不了」：$(cat "$BRIEF" 2>/dev/null)"
grep -q 'disk full' "$BRIEF" && fail "5：known 命中的還告警"
sleep 2   # run_to 送 TERM 後 1 秒補 KILL
kill -0 "$(cat "$TMP/hang.pid")" 2>/dev/null && fail "5：逾時那棒的 sleep 還活著"
# 有一棒答得出來：記下是哪一棒
case_init fallback-leg2
mk_llm llm-a "" 1
mk_llm llm-b "1 KNOWN 磁碟滿"
export WATCHDOG_LLM_LEGS="$S/llm-a;$S/llm-b;$S/llm-hang"
run_wd; addlog "ERROR omega"; run_wd
grep -q 'L1 leg=llm-b' "$WLOG" || fail "5b：log 沒記哪一棒回答"
[ "$(calls_of llm-hang)" = 0 ] || fail "5b：前一棒答了還往下叫"

# =============== 6. L2：兩棒值不同或超界 → knobs.env 不變、proposals 有檔 ===============
l2_case() { # 名稱 L1提議 L2a L2b
  case_init "$1"
  mk_llm llm-a "1 NOISE
KNOB DEEP_STALL_MIN=$2"
  mk_llm l2-a "KNOB DEEP_STALL_MIN=$3"
  mk_llm l2-b "KNOB DEEP_STALL_MIN=$4"
  printf 'DEEP_STALL_MIN=15\n' > "$MYTHOS_DIR/state/watchdog-knobs.env"
  run_wd; addlog "ERROR knob $1"; run_wd
}
l2_case l2-diff 30 30 45
[ "$(cat "$MYTHOS_DIR/state/watchdog-knobs.env")" = "DEEP_STALL_MIN=15" ] || fail "6：兩棒不同值卻改了 knobs"
[ -n "$(ls "$MYTHOS_DIR/state/watchdog-proposals/" 2>/dev/null)" ] || fail "6：兩棒不同值沒寫 proposals"
grep -q 'Watchdog 提議 DEEP_STALL_MIN=30' "$BRIEF" || fail "6：proposal 沒寫 brief 一行"
l2_case l2-oob 500 500 500
[ "$(cat "$MYTHOS_DIR/state/watchdog-knobs.env")" = "DEEP_STALL_MIN=15" ] || fail "6：超界值卻改了 knobs"
[ -n "$(ls "$MYTHOS_DIR/state/watchdog-proposals/" 2>/dev/null)" ] || fail "6：超界沒寫 proposals"
l2_case l2-ok 30 30 30
[ "$(cat "$MYTHOS_DIR/state/watchdog-knobs.env")" = "DEEP_STALL_MIN=30" ] || fail "6：兩棒同值在界內卻沒套用"
grep -q 'L2 APPLY DEEP_STALL_MIN 15→30' "$WLOG" || fail "6：套用沒寫 log"
# 非白名單旋鈕／prompt 類建議：只提議
case_init l2-propose
mk_llm llm-a "1 NOISE
PROPOSE 把 Router 的 prompt 改短
KNOB PIN_GUARD=0"
mk_llm l2-a "KNOB PIN_GUARD=0"; mk_llm l2-b "KNOB PIN_GUARD=0"
run_wd; addlog "ERROR propose"; run_wd
[ "$(ls "$MYTHOS_DIR/state/watchdog-proposals/" | wc -l | tr -d ' ')" = 2 ] || fail "6b：PROPOSE／白名單外旋鈕應各寫一份 proposals"
[ ! -f "$MYTHOS_DIR/state/watchdog-knobs.env" ] || fail "6b：白名單外旋鈕寫進了 knobs"
[ "$(calls_of l2-a)" = 0 ] || fail "6b：白名單外旋鈕還去問 L2"

# =============== ask：走同一條白名單＋退路鏈 ===============
case_init ask
mk_llm llm-a "目前一切正常"
run_wd
printf '%s FIX test line %s/secret/.ssh/id\n' "$(date '+%F %T')" "$HOME" >> "$WLOG"
out="$(run_wd ask "現在有什麼問題？")"
[ "$out" = "目前一切正常" ] || fail "ask：沒印模型回答：$out"
grep -q '/.ssh/' "$TMP/llm-prompts" && fail "ask：憑證路徑行出機了"
mk_llm llm-a "" 1
set +e; out="$(run_wd ask "再問一次")"; rc=$?; set -e
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q '判不了' || fail "ask：退路鏈全敗沒說判不了（rc=$rc）"

# =============== 7. 突變：拿掉 canary 掃描那行 → 白名單測試必須 fail ===============
if [ -z "${WD_MUTANT:-}" ]; then
  M="$TMP/mutant"; mkdir -p "$M/bin"
  cp "$ROOT"/bin/* "$M/bin/"
  grep -q 'canary_scan "$txt"' "$M/bin/watchdog" || fail "7：找不到 canary 掃描那行"
  grep -v 'canary_scan "$txt"' "$ROOT/bin/watchdog" > "$M/bin/watchdog"
  bash -n "$M/bin/watchdog" || fail "7：突變版語法壞了"
  WD_BIN="$M/bin/watchdog"
  export WATCHDOG_CANARY_CMD="$S/canary"
  if ( wl_case mut ) 2>/dev/null; then fail "7：拿掉 canary 掃描後白名單測試仍通過（測試沒咬住）"; fi
  WD_BIN="$ROOT/bin/watchdog"
fi

# =============== 全程不出網 ===============
[ ! -s "$TMP/net.log" ] || fail "測試出網了：$(cat "$TMP/net.log")"

echo "WATCHDOG-V2 PASS"
