#!/usr/bin/env bash
# 驗收：派工抽查兩段過濾。review-judge 四種判定 + dispatch-watch 在 ON_TRACK 時不喚醒 Mythos。
set -euo pipefail

BIN="$(cd "$(dirname "$0")/../bin" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- 假免費模型 ---
mk_llm() {
  local path="$1" body="$2" rc="${3:-0}"
  cat > "$path" <<EOF
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "$body"
exit $rc
EOF
  chmod +x "$path"
}

task="$TMP/task.md"
cat > "$task" <<'EOF'
# 工單：修 foo.mjs 的路徑比對
## 驗收
bash tests/test-foo.sh
EOF
progress="Edit /Users/x/foo.mjs；Bash bash tests/test-foo.sh"

# 1. ON_TRACK
mk_llm "$TMP/llm1" "ON_TRACK"
out="$(REVIEW_JUDGE_LLM="$TMP/llm1" "$BIN/review-judge" "$task" "$progress")"
[ "$out" = "ON_TRACK" ] || fail "ON_TRACK 應原樣輸出，得到：$out"

# 2. OFF_TRACK（理由要帶出來）
mk_llm "$TMP/llm2" "OFF_TRACK 在改驗收腳本本身"
out="$(REVIEW_JUDGE_LLM="$TMP/llm2" "$BIN/review-judge" "$task" "$progress")"
case "$out" in OFF_TRACK*驗收*) ;; *) fail "OFF_TRACK 理由沒帶出來：$out" ;; esac

# 3. 模型講廢話 → UNKNOWN
mk_llm "$TMP/llm3" "我覺得還行吧"
out="$(REVIEW_JUDGE_LLM="$TMP/llm3" "$BIN/review-judge" "$task" "$progress")"
case "$out" in UNKNOWN*) ;; *) fail "看不懂的輸出應判 UNKNOWN：$out" ;; esac

# 4. 模型不通 → UNKNOWN
mk_llm "$TMP/llm4" "" 1
out="$(REVIEW_JUDGE_LLM="$TMP/llm4" "$BIN/review-judge" "$task" "$progress")"
case "$out" in UNKNOWN*) ;; *) fail "模型不通應判 UNKNOWN：$out" ;; esac

# 5. 讀不到進度 → UNKNOWN（不花模型呼叫）
out="$(REVIEW_JUDGE_LLM=/nonexistent "$BIN/review-judge" "$task" "讀不到進度")"
case "$out" in UNKNOWN*) ;; *) fail "沒進度應判 UNKNOWN：$out" ;; esac

# 6. 免費鏈：第一棒掛 → 第二棒接手
out="$(REVIEW_JUDGE_LLM="$TMP/llm4 $TMP/llm1" "$BIN/review-judge" "$task" "$progress")"
[ "$out" = "ON_TRACK" ] || fail "第一棒掛掉應換第二棒：$out"

# 7. 免費鏈：第一棒答非所問 → 第二棒判 OFF_TRACK
out="$(REVIEW_JUDGE_LLM="$TMP/llm3 $TMP/llm2" "$BIN/review-judge" "$task" "$progress")"
case "$out" in OFF_TRACK*) ;; *) fail "第一棒看不懂應換第二棒：$out" ;; esac

# 8. 免費鏈：不存在的棒跳過、全敗 → UNKNOWN 並說最後一棒原因
out="$(REVIEW_JUDGE_LLM="/nonexistent $TMP/llm4" "$BIN/review-judge" "$task" "$progress")"
case "$out" in UNKNOWN*llm4*) ;; *) fail "全敗應 UNKNOWN 帶最後一棒：$out" ;; esac

# 9. 每棒逾時要砍掉並換下一棒
cat > "$TMP/llm-slow" <<'EOF'
#!/usr/bin/env bash
sleep 10; echo ON_TRACK
EOF
chmod +x "$TMP/llm-slow"
start=$(date +%s)
out="$(REVIEW_JUDGE_TIMEOUT_S=1 REVIEW_JUDGE_LLM="$TMP/llm-slow $TMP/llm2" "$BIN/review-judge" "$task" "$progress")"
[ $(( $(date +%s) - start )) -lt 8 ] || fail "逾時沒砍掉慢棒"
case "$out" in OFF_TRACK*) ;; *) fail "慢棒逾時後應由第二棒判：$out" ;; esac

# 10. oc-free-ask：scrub 不通就不送（fail closed，exit 3），也不得呼叫 opencode
cat > "$TMP/fake-oc" <<EOF
#!/usr/bin/env bash
touch "$TMP/oc-called"; echo ON_TRACK
EOF
chmod +x "$TMP/fake-oc"
set +e
echo hi | OC_FREE_ASK_SCRUB=http://127.0.0.1:9/scrub OC_FREE_ASK_BIN="$TMP/fake-oc" "$BIN/oc-free-ask" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 3 ] || fail "scrub 不通 oc-free-ask 應 exit 3，得到 $rc"
if [ -e "$TMP/oc-called" ]; then fail "scrub 不通仍呼叫了 opencode"; fi

# --- dispatch-watch 整合 ---
MD="$TMP/mythos"; mkdir -p "$MD/state/deep" "$MD/bin"
cwd="$TMP/work"; mkdir -p "$cwd"
slug="$(printf '%s' "$cwd" | sed 's/[\/.]/-/g')"
PROJ="$TMP/projects"; mkdir -p "$PROJ/$slug"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/x/foo.mjs"}}]}}' \
  > "$PROJ/$slug/s.jsonl"

old=$(( $(date +%s) - 3600 ))
printf 'deep-1-task\thard\t%s\t%s\tpending\t%s\n' "$task" "$old" "$cwd" > "$MD/state/dispatch-jobs.tsv"

# 假 tmux：pane 看起來閒置，所有呼叫記進 log
cat > "$TMP/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/tmux.log"
for a in "\$@"; do [ "\$a" = capture-pane ] && { echo "idle prompt"; exit 0; }; done
exit 0
EOF
chmod +x "$TMP/tmux"
# A（11-03）：終態事件同一 event_id 只建一次，重送看 delivered_at；每次 run_watch 視為下一輪，
# 先把已投遞的 delivered_at 推回 11 分鐘前（不碰事件本身，只跨過 10 分鐘重送門檻）
reset_delivered() {
  [ -f "$MD/state/events.jsonl" ] || return 0
  jq -c '.delivered_at = ((now | floor) - 660)' "$MD/state/events.jsonl" > "$TMP/ev.tmp" && mv "$TMP/ev.tmp" "$MD/state/events.jsonl"
}

# 反例：否定／無效輸出不得被當成 ON_TRACK（11-02 Codex 審計）
i=0
for bad in "NOT_ON_TRACK" "UNKNOWN: expected ON_TRACK or OFF_TRACK" "ON_TRACKING_INVALID" "我認為不是 ON_TRACK" "UNKNOWN"; do
  i=$((i+1)); mk_llm "$TMP/llm-bad$i" "$bad"
  out="$(REVIEW_JUDGE_LLM="$TMP/llm-bad$i" "$BIN/review-judge" "$task" "$progress")"
  case "$out" in UNKNOWN*) ;; *) fail "「${bad}」應判 UNKNOWN，得到：$out" ;; esac
done
# 正例：markdown 包裝的合法輸出照收
mk_llm "$TMP/llm-md" '**ON_TRACK**'
out="$(REVIEW_JUDGE_LLM="$TMP/llm-md" "$BIN/review-judge" "$task" "$progress")"
[ "$out" = "ON_TRACK" ] || fail "**ON_TRACK** 應判 ON_TRACK：$out"
mk_llm "$TMP/llm-md2" "*STUCK*：一直重跑同一條測試"
out="$(REVIEW_JUDGE_LLM="$TMP/llm-md2" "$BIN/review-judge" "$task" "$progress")"
case "$out" in STUCK*) ;; *) fail "*STUCK* 應判 STUCK：$out" ;; esac

run_watch() {
  reset_delivered
  MYTHOS_DIR="$MD" DCQ_HOME="$TMP/dcq" TMUX_BIN="$TMP/tmux" MYTHOS_TRANSCRIPT_DIR="$TMP/transcript" \
    CLAUDE_PROJECTS_DIR="$PROJ" REVIEW_JUDGE="$1" bash "$BIN/dispatch-watch"
}

# 5a. ON_TRACK：不得出現 send-keys，last-review 要被寫上
: > "$TMP/tmux.log"
cat > "$TMP/judge-ok" <<'EOF'
#!/usr/bin/env bash
echo ON_TRACK
EOF
chmod +x "$TMP/judge-ok"
run_watch "$TMP/judge-ok"
if grep -q send-keys "$TMP/tmux.log" 2>/dev/null; then
  fail "ON_TRACK 仍喚醒了 Mythos：$(cat "$TMP/tmux.log")"
fi
[ -s "$MD/state/deep/deep-1-task.last-review" ] || fail "ON_TRACK 沒有把抽查間隔往前推"

# 5b. OFF_TRACK：必須喚醒，訊息要帶判定
: > "$TMP/tmux.log"
printf '%s\n' "$old" > "$MD/state/deep/deep-1-task.last-review"
cat > "$TMP/judge-bad" <<'EOF'
#!/usr/bin/env bash
echo "OFF_TRACK 在改驗收腳本本身"
EOF
chmod +x "$TMP/judge-bad"
run_watch "$TMP/judge-bad"
grep -q send-keys "$TMP/tmux.log" || fail "OFF_TRACK 沒有喚醒 Mythos"
grep -q "OFF_TRACK" "$TMP/tmux.log" || fail "喚醒訊息沒帶判定：$(cat "$TMP/tmux.log")"

# 5d. judge 印 ON_TRACK 卻非零退出：算失敗，照樣喚醒（11-02 Codex 審計）
: > "$TMP/tmux.log"
printf '%s\n' "$old" > "$MD/state/deep/deep-1-task.last-review"
printf '#!/usr/bin/env bash\necho ON_TRACK\nexit 7\n' > "$TMP/judge-crash"
chmod +x "$TMP/judge-crash"
run_watch "$TMP/judge-crash"
grep -q send-keys "$TMP/tmux.log" || fail "judge 非零退出卻被當 ON_TRACK 壓掉喚醒"

# 5c. 沒有 judge（退回舊行為）：照樣喚醒
: > "$TMP/tmux.log"
printf '%s\n' "$old" > "$MD/state/deep/deep-1-task.last-review"
run_watch "$TMP/no-such-judge"
grep -q send-keys "$TMP/tmux.log" || fail "judge 不存在時應退回舊行為喚醒 Mythos"

echo "REVIEW-JUDGE PASS"
