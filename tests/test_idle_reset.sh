#!/usr/bin/env bash
# 驗收：idle-reset 短閒置才清、忙就等、一天只清一次（11-02：舊版 6h 條件被夜間排程永遠擋住）。
set -euo pipefail
export MYTHOS_RUNTIME=claude  # 測 Claude TUI 舊流程；Hermes 模式另見 tests/test-hermes-control-loop.py
SRC="$(cd "$(dirname "$0")/../bin" && pwd)/idle-reset"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$TMP/proj"
cat > "$TMP/tmux" <<EOS
#!/bin/sh
case "\$*" in *capture-pane*) cat "$TMP/pane" 2>/dev/null ;; *send-keys*) echo "\$*" >> "$TMP/sent" ;; esac
EOS
chmod +x "$TMP/tmux"
run() { TMUX_BIN="$TMP/tmux" PROJ="$TMP/proj" STAMP="$TMP/stamp" sh "$SRC"; }
old() { touch -t "$(date -v-"$1"M +%Y%m%d%H%M)" "$TMP/proj/a.jsonl"; }

# 50 分鐘前有動（像夜間排程 03:10 寫完計畫、04:00 檢查）→ 要清
old 50; : > "$TMP/pane"; rm -f "$TMP/sent"
run | grep -q -- '-> /clear' || fail "50 分鐘沒動應送 /clear"
grep -q '/clear' "$TMP/sent" || fail "沒送 /clear 給 tmux"
# 同一天第二次 → 不再清
rm -f "$TMP/sent"; run | grep -q 'already cleared' || fail "一天應只清一次"
[ -e "$TMP/sent" ] && fail "第二次不該送鍵"
# 10 分鐘前有動 → 不清
rm -f "$TMP/stamp"; old 10; run | grep -q 'active' || fail "10 分鐘內有動不該清"
[ -e "$TMP/sent" ] && fail "active 不該送鍵"
# pane 正在跑 → 不清
old 50; echo '✻ Thinking… (esc to interrupt)' > "$TMP/pane"
run | grep -q 'busy' || fail "pane 在跑不該清"
[ -e "$TMP/sent" ] && fail "busy 不該送鍵"
[ -e "$TMP/stamp" ] && fail "沒清不該寫 stamp"
# capture-pane 失敗（假 tmux 讀不到 pane 檔 → exit 1）→ 不清（11-02 Codex 審計）
old 50; rm -f "$TMP/pane"
run | grep -q 'capture-pane failed' || fail "抓不到 pane 不該當閒置"
[ -e "$TMP/sent" ] && fail "抓不到 pane 不該送鍵"
echo "IDLE-RESET PASS"
