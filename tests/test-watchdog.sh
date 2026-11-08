#!/usr/bin/env bash
# 驗收：watchdog v2（計畫「預防加固」7 條）。LLM、scrub、claude agents、tmux、canary 全用 stub，
# PATH 前面再墊假的 curl／opencode：有人想出網就記一筆，最後檢查必須是空的。
export MYTHOS_RUNTIME=claude
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
# 跟真的 sensitive-canary 一樣把 IP／手機長數字當 PII 擋（A1 突變靠這條咬住）
if printf "%s" "$p" | grep -qE "[0-9]{1,3}([.][0-9]{1,3}){3}|09[0-9]{8}"; then exit 2; fi
exit 0
EOF
chmod +x "$S/canary"

# ---- 假 scrub：good 把假 PII 換成佔位；bad 原樣回傳 ----
cat > "$S/scrub-good" <<'EOF'
#!/usr/bin/env bash
in="$(cat)"
# 自檢的假 PII 才算自檢呼叫；逐項 scrub 另記，第 4 段只數自檢
case "$in" in *0912-345-678*) echo x >> "$TMP/scrub-calls" ;; *) echo x >> "$TMP/scrub-item-calls" ;; esac
printf "%s" "$in" | jq -c '{texts: [.texts[0] | gsub("0912-345-678"; "<PHONE>") | gsub("0x[0-9A-Fa-f]{40}"; "<WALLET>") | gsub("[A-Za-z0-9._-]+@[A-Za-z0-9.-]+"; "<EMAIL>")]}'
EOF
cat > "$S/scrub-bad" <<'EOF'
#!/usr/bin/env bash
in="$(cat)"
case "$in" in *0912-345-678*) echo x >> "$TMP/scrub-calls" ;; *) echo x >> "$TMP/scrub-item-calls" ;; esac
printf "%s" "$in"
EOF
chmod +x "$S/scrub-good" "$S/scrub-bad"
# 缺口 A：只把 IP／手機換成佔位，其他原樣（拉掉長數字後 canary 不命中）
cat > "$S/scrub-ip" <<'EOF'
#!/usr/bin/env bash
in="$(cat)"
case "$in" in *0912-345-678*) echo x >> "$TMP/scrub-calls" ;; *) echo x >> "$TMP/scrub-item-calls" ;; esac
printf "%s" "$in" | jq -c '{texts: [.texts[0] | gsub("[0-9]{1,3}([.][0-9]{1,3}){3}"; "<IP>") | gsub("09[0-9]{8}"; "<PHONE>") | gsub("0912-345-678"; "<PHONE>") | gsub("0x[0-9A-Fa-f]{40}"; "<WALLET>") | gsub("[A-Za-z0-9._-]+@[A-Za-z0-9.-]+"; "<EMAIL>")]}'
EOF
# scrub 連不上
cat > "$S/scrub-down" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 7
EOF
# 信任邊界：寫死的保密詞已去識別（測試自己補回去，確認規則還在；信任邊界不改行為）
trust_case() { # 回 0＝保密詞檔生效（直接讀 bin/watchdog 的 SENSITIVE_RE 區塊，不碰 wl_line）
  mkdir -p "$TMP/trust/state"
  printf 'carr%s' ie > "$TMP/trust/state/watchdog-sensitive.re"
  cp "$TMP/trust/state/watchdog-sensitive.re" "$TMP/sensitive.re"
  reres() { awk '/^SENSITIVE_RE=/{f=1} f&&/^fi$/{print;exit} f' "$ROOT/bin/watchdog"; }
  __re="$(export MYTHOS_DIR="$TMP/trust"; eval "$(reres)"; printf %s "$SENSITIVE_RE")"
  printf '%s' "$__re" | grep -qw "$(cat "$TMP/trust/state/watchdog-sensitive.re")" || return 1
  u="$TMP/trust/nonexistent"; mkdir -p "$u"
  __re="$(export MYTHOS_DIR="$u"; eval "$(reres)"; printf %s "$SENSITIVE_RE")"
  printf '%s' "$__re" | grep -qw "$(cat "$TMP/trust/state/watchdog-sensitive.re")" && return 1
  return 0
}
trust_case || fail "3d：保密詞檔沒被讀進白名單"
chmod +x "$S/scrub-ip" "$S/scrub-down"

# ---- 假 claude agents／tmux ----
cat > "$S/claude" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "agents --json" ] || exit 1
cat "$TMP/agents.json" 2>/dev/null || echo '[]'
EOF
cat > "$S/tmux" <<'EOF'
#!/usr/bin/env bash
# deep 專用 socket：只有 `-L deep ls …` 才當 session 清單，預設 socket 印空
if [ "$1 $2" = "-L deep" ] && [ "$3" = ls ]; then cat "$TMP/tmux-sessions" 2>/dev/null; fi
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
  cp "$TMP/sensitive.re" "$C/mythos/state/watchdog-sensitive.re"   # 白名單那條規則原先寫死，測試自己補回
  export MYTHOS_DIR="$C/mythos" MYTHOS_BRIEF_DIR="$C/brief"
  BRIEF="$C/brief/mythos-watchdog.tsv"
  WLOG="$MYTHOS_DIR/logs/watchdog.log"
  : > "$BRIEF"   # 沒告警的情境也要有檔，才能確認「沒寫進來」
  rm -f "$TMP/llm-calls" "$TMP/llm-prompts" "$TMP/canary-in" "$TMP/scrub-calls" "$TMP/scrub-item-calls" "$TMP/agents.json" "$TMP/tmux-sessions"
  : > "$MYTHOS_DIR/logs/app.log"
  export WATCHDOG_LLM_LEGS="$S/llm-a"
  export WATCHDOG_L2_LEGS="$S/l2-a;$S/l2-b"
  export WATCHDOG_SCRUB_CMD="$S/scrub-good"
  export WD_UNOWNED_MAX_MIN=120
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
# 背景 worker waitingFor=permission prompt，第一次看到是 11 分鐘前；
# bg3 是 state=blocked 但 waitingFor 不是 permission prompt（已完成收尾的 worker 也是 blocked）→ 不告警
printf '[{"id":"bg1","kind":"background","state":"blocked","waitingFor":"permission prompt","name":"x"},{"id":"bg2","kind":"background","state":"stopped"},{"id":"bg3","kind":"background","state":"blocked","waitingFor":"review","name":"z"}]' > "$TMP/agents.json"
printf '{"alerted":{},"bg_blocked":{"bg1":%s,"bg3":%s}}\n' $((now - 660)) $((now - 660)) > "$MYTHOS_DIR/state/watchdog.json"
addlog "INFO all good"
run_wd
addlog "INFO still fine"
run_wd
[ "$(calls)" = 0 ] || fail "1：L0 情境叫了模型 $(calls) 次"
grep -q '卡在 pending' "$BRIEF" || fail "1：pending 沒告警"
grep -q 'deep session deep-' "$BRIEF" || fail "1：deep 停滯沒告警：$(cat "$BRIEF")"
grep -q '背景 agent bg1' "$BRIEF" || fail "1：bg blocked 沒告警"
grep -q 'bg2' "$BRIEF" && fail "1：stopped 的 bg 不該告警"
grep -q 'bg3' "$BRIEF" && fail "1：waitingFor 不是 permission prompt 的 bg3 不該告警：$(cat "$BRIEF")"
[ ! -s "$MYTHOS_DIR/state/watchdog-pending.jsonl" ] || fail "1：沒有錯誤行卻進了待判"
[ "$(wc -l < "$BRIEF" | tr -d ' ')" = 3 ] || fail "1：第二輪重複告警：$(cat "$BRIEF")"
[ "$(jq -r '.bg_blocked | keys | length' "$MYTHOS_DIR/state/watchdog.json")" = 1 ] && jq -r '.bg_blocked | has("bg1")' "$MYTHOS_DIR/state/watchdog.json" | grep -q true || fail "1：bg_blocked 沒收斂到 bg1"

# =============== 1b. bg blocked：無 waitingFor 不告警；waitingFor=permission prompt 告警 ===============
case_init bgi
mk_llm llm-a "1 NOISE"
now=$(date +%s)
# (i) state=blocked 但 waitingFor 不是 permission prompt → 不告警
printf 'bg9\tmid\t/x/i.md\t%s\trunning\t/x\t-\tbg\n' $((now - 100)) > "$MYTHOS_DIR/state/dispatch-jobs.tsv"
printf '[{"id":"bg9","kind":"background","state":"blocked","waitingFor":"review","name":"y"}]' > "$TMP/agents.json"
printf '{"alerted":{},"bg_blocked":{"bg9":%s}}\n' $((now - 660)) > "$MYTHOS_DIR/state/watchdog.json"
run_wd
grep -q 'bg9' "$BRIEF" && fail "1b(i)：blocked 無 permission prompt 也告警了：$(cat "$BRIEF")"
# (ii) waitingFor=permission prompt 超過 BG_STALL_MIN → 告警
printf '[{"id":"bg9","kind":"background","state":"blocked","waitingFor":"permission prompt","name":"y"}]' > "$TMP/agents.json"
printf '{"alerted":{},"bg_blocked":{"bg9":%s}}\n' $((now - 660)) > "$MYTHOS_DIR/state/watchdog.json"
run_wd
grep -q '背景 agent bg9' "$BRIEF" || fail "1b(ii)：waitingFor=permission prompt 沒告警：$(cat "$BRIEF")"

# =============== 1c. deep transcript：尾端中繼列刷 mtime、最後 timestamp 很舊 → 照樣判 deep-stall ===============
case_init dep
mk_llm llm-a "1 NOISE"
now=$(date +%s)
printf 'deep-%s-4242\n' "$now" > "$TMP/tmux-sessions"
printf 'deep-88\trunning-deep\t/x/deep.md\t%s\trunning\t/work/proj\t-\tdeep\n' "$now" > "$MYTHOS_DIR/state/dispatch-jobs.tsv"
printf 'pid=1\ndeep_pid=4242\nsession=deep-%s-4242\n' "$now" > "$MYTHOS_DIR/state/deep/deep-88.handle"
mkdir -p "$CLAUDE_PROJECTS_DIR/-work-proj"
ts="$(date -u -r $((now - 1200)) '+%Y-%m-%dT%H:%M:%S.000Z')"
printf '{"type":"assistant","timestamp":"%s"}\n' "$ts" > "$CLAUDE_PROJECTS_DIR/-work-proj/t.jsonl"
touch "$CLAUDE_PROJECTS_DIR/-work-proj/t.jsonl"   # mtime 剛被中繼列刷到現在
run_wd
grep -q 'transcript 20 分鐘沒動' "$BRIEF" || fail "1c(iii)：deep transcript mtime 很新但最後 timestamp 很舊，沒判 deep-stall：$(cat "$BRIEF")"
[ "$(calls)" = 0 ] || fail "1c：L0 情境叫了模型"

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
  addlog "ERROR read failed $HOME/bots/$(printf 'carr%s' 'ie')/notes.md"
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
grep -qi "$(printf 'carr%s' ie)" "$TMP/canary-in" && fail "3：合規專案路徑沒在白名單階段丟掉"
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

# =============== 8. 缺口 A：出機先 scrub 再 canary、不送原值 ===============
case_init a1
mk_llm llm-a "1 NOISE"
export WATCHDOG_SCRUB_CMD="$S/scrub-ip"
run_wd; addlog 'ERROR connect 10.1.2.3 from 0912345678'; run_wd
[ "$(calls)" = 1 ] || fail "A1a：去識別後該放行且只叫 1 次，實際 $(calls)"
grep -q '10.1.2.3' "$TMP/llm-prompts" && fail "A1a：LLM 收到原始 IP"
grep -q '0912345678' "$TMP/llm-prompts" && fail "A1a：LLM 收到原始手機"
grep -q '<IP>' "$TMP/llm-prompts" || fail "A1a：LLM 沒收到 scrub 後文字"
# A1b：scrub 原樣回傳，假憑證照樣被 canary 擋
case_init a1b
mk_llm llm-a "1 NOISE"
export WATCHDOG_SCRUB_CMD="$S/scrub-bad"
run_wd; addlog "ERROR upload with token $FAKE_TOK"; run_wd
[ "$(calls)" = 0 ] || fail "A1b：假憑證去識別後仍送模型"
grep -q 'FALLBACK KNOWN\|判不了' "$WLOG" "$BRIEF" || fail "A1b：假憑證沒走退路"
# A1c：scrub 不通 → 不送模型、log 記 SCRUB_DOWN
for sc in down empty; do
  case_init "a1c-$sc"
  mk_llm llm-a "1 NOISE"
  if [ "$sc" = down ]; then export WATCHDOG_SCRUB_CMD="$S/scrub-down"
  else printf '#!/bin/sh\nexit 0\n' > "$S/scrub-empty"; chmod +x "$S/scrub-empty"; export WATCHDOG_SCRUB_CMD="$S/scrub-empty"; fi
  run_wd; addlog "ERROR theta broke"; run_wd
  [ "$(calls)" = 0 ] || fail "A1c($sc)：scrub 不通還送模型"
  grep -q 'SCRUB_DOWN' "$WLOG" || fail "A1c($sc)：log 沒有 SCRUB_DOWN"
done

# =============== 9. 旋鈕改名：DEEP_REVIEW_MIN ===============
case_init a2
mk_llm llm-a "1 NOISE
KNOB DEEP_REVIEW_MIN=45"
mk_llm l2-a "KNOB DEEP_REVIEW_MIN=45"; mk_llm l2-b "KNOB DEEP_REVIEW_MIN=45"
run_wd; addlog "ERROR knob a2"; run_wd
grep -qx 'DEEP_REVIEW_MIN=45' "$MYTHOS_DIR/state/watchdog-knobs.env" || fail "A2：knobs.env 沒有 DEEP_REVIEW_MIN=45"
grep -qx 'DEEP_REVIEW_MIN=45' "$MYTHOS_DIR/state/watchdog-knobs.env" && [ "$(wc -l < "$MYTHOS_DIR/state/watchdog-knobs.env" | tr -d ' ')" = 1 ] || fail "A2：knobs.env 混了別的行"
grep -q "$(printf 'REVIEW%s' _EVERY)" "$MYTHOS_DIR/state/watchdog-knobs.env" && fail "A2：knobs.env 還有舊名"

# =============== 10. 無主 deep session ===============
case_init a3
mk_llm llm-a "1 NOISE"
now=$(date +%s)
printf 'deep-%s-999\ndeep-%s-998\n' $((now - 10800)) $((now - 600)) > "$TMP/tmux-sessions"
run_wd
grep -q "無主 deep session deep-$((now - 10800))-999" "$BRIEF" || fail "A3：3 小時的無主 session 沒告警"
grep -q "deep-$((now - 600))-998" "$BRIEF" && fail "A3：10 分鐘的無主 session 不該告警"
[ "$(calls)" = 0 ] || fail "A3：L0 情境叫了模型"

# =============== 11. run_to 逾時強制 KILL：忽略 TERM 也要在幾秒內結束 ===============
eval "$(awk '/^run_to\(\) \{/,/^\}/' "$WD_BIN")"
t0=$(date +%s)
# $! 取號，$( … ) 才不會等握著 stdout 的 killed 子程序而卡住
run_to 1 /bin/bash -c 'trap "" TERM; exec sleep 30' & rt_j=$!
set +e; wait "$rt_j"; rt_rc=$?; set -e
el=$(( $(date +%s) - t0 ))
[ "$rt_rc" != 0 ] || fail "11：run_to 逾時卻 rc=0"
[ "$el" -le 8 ] || fail "11：run_to 沒強制砍（${el}s）"
eval "$(awk '/^run_to\(\) \{/,/^\}/' "$ROOT/bin/watchdog")"   # 還原，後續突變子測試用原版

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

# =============== 8b. 突變：順序換回 canary 先 → A1a 必 fail ===============
if [ -z "${WD_MUTANT:-}" ]; then
  M2="$TMP/mutant2"; mkdir -p "$M2/bin"
  cp "$ROOT"/bin/* "$M2/bin/"
  python3 - "$ROOT/bin/watchdog" "$M2/bin/watchdog" <<'PY' || fail "8b：找不到 scrub→canary 那段"
import sys
s = open(sys.argv[1], encoding='utf-8').read()
a = '''    if ! scrub_payload "$txt"; then
      log "SCRUB_DOWN [$src] 連不上或回應壞，不送模型"
      fallback_item "$sig" "$src" "$raw" "scrub 不通" ""
      continue
    fi
    txt="$SCRUBBED"
'''
b = '''    txt="$SCRUBBED"
'''
assert s.count(a) == 1
s = s.replace(a, '''    blocked=0
    canary_scan "$txt" || blocked=1
    if [ "$blocked" = 1 ]; then
      log "CANARY 命中 [$src]，不送模型"
      fallback_item "$sig" "$src" "$raw" "canary 命中" ""
      continue
    fi
''' + b, 1)
open(sys.argv[2], 'w', encoding='utf-8').write(s)
PY
  bash -n "$M2/bin/watchdog" || fail "8b：突變版語法壞了"
  ( WD_BIN="$M2/bin/watchdog" WD_MUTANT=1 WATCHDOG_SCRUB_CMD="$S/scrub-ip" bash "$0" ) 2>/dev/null \
    && fail "8b：canary 先於 scrub 的順序仍通過（測試沒咬住）"
  WD_BIN="$ROOT/bin/watchdog"
fi

# =============== 全程不出網 ===============
[ ! -s "$TMP/net.log" ] || fail "測試出網了：$(cat "$TMP/net.log")"

echo "WATCHDOG-V2 PASS"
