#!/usr/bin/env bash
# 共用 ledger 鎖與讀寫（D）。所有改 state/dispatch-jobs.tsv 與 state/events.jsonl 的地方都先 source 這個再在鎖內改。
# 用法：
#   ledger_lock || exit 1 ; ...改檔... ; ledger_unlock
#   ledger_events <lib-events 子命令> …  → 持鎖呼叫 lib-events.mjs（已持鎖就直接呼叫）
#   ledger_fields  → 讀一行並裁成 8 欄（舊 5／6 欄列補預設，thread/backend 推導）
# 鎖＝固定 fd 9 上的 flock（macOS 內建 perl 取鎖）：行程死掉 fd 關閉，鎖由核心自動釋放，不需要 reap。
# 陷阱：持鎖期間啟動的長壽子行程（nohup、tmux、&）會繼承 fd 9 繼續持鎖，一律帶 `9>&-`。
# /bin/bash 是 3.2，沒有 {fd} 語法，所以固定用 9。
set -u

LEDGER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# MYTHOS_DIR 沒設也能推導（lib 在 <repo>/bin/），不讓 set -u 中斷
LEDGER_LOCK_FILE="${LEDGER_LOCK_FILE:-${MYTHOS_DIR:-$(cd "$LEDGER_LIB_DIR/.." && pwd)}/state/.ledger.flock}"
LEDGER_HELD=''

ledger_lock() {
  mkdir -p "$(dirname "$LEDGER_LOCK_FILE")" || return 1
  exec 9>>"$LEDGER_LOCK_FILE" || return 1
  if ! perl -MFcntl=:flock -e 'open(my $f,">&=",$ARGV[0]) or exit 2; for(1..$ARGV[1]){ exit 0 if flock($f,LOCK_EX|LOCK_NB); select(undef,undef,undef,0.2) } exit 1' 9 "${LEDGER_LOCK_TRIES:-50}"; then
    exec 9>&-; return 1
  fi
  LEDGER_HELD=1
}
# 只關自己這個行程的 fd 9：沒持鎖就什麼都不做，碰不到別人的鎖
ledger_unlock() { [ -n "${LEDGER_HELD:-}" ] || return 0; exec 9>&-; LEDGER_HELD=''; }

# events.jsonl 的所有寫入（upsert／set／bump）都走這裡，跟 ledger 同一把鎖（不另建互斥）。
# 已持鎖（例如 cancel 改 ledger 的同一段）就直接呼叫，不重開 fd 9（重開會把自己的鎖放掉）。
ledger_events() {
  local rc
  if [ -n "${LEDGER_HELD:-}" ]; then
    "${NODE_BIN:-node}" "$LEDGER_LIB_DIR/lib-events.mjs" "$@" 9>&-
    return
  fi
  ledger_lock || return 1
  "${NODE_BIN:-node}" "$LEDGER_LIB_DIR/lib-events.mjs" "$@" 9>&-
  rc=$?
  ledger_unlock
  return "$rc"
}

# 未收尾判定（11-07 從 dispatch-watch unresolved_scan 抽出，FAIL/TIMEOUT 規則共用）：
#   closeouts 有該 id；或帳本狀態已是收尾狀態；或同 thread 後面有 epoch 更大的別張單（重派）。
# 回 0＝已收尾、1＝未收尾。STALL 單的判定（pending 才算未收尾）由呼叫端自理。
#   $1 id；$2 status；$3 thread；$4 epoch；$5 整份帳本（ledger_fields 輸出）；$6 closeouts 檔路徑
ledger_is_closed() {
  local id="$1" st="$2" th="$3" ep="$4" rows="$5" cx="$6"
  if [ -f "$cx" ] && cut -f1 "$cx" | grep -qxF -- "$id"; then return 0; fi
  case "$st" in superseded|cancelled|resolved|notified-PASS|retried|informed|done) return 0 ;; esac
  case "$th" in ''|-) return 1 ;; esac
  printf '%s\n' "$rows" | awk -F'\t' -v t="$th" -v i="$id" -v e="$ep" '
    $7==t && $1!=i && $4+0>e+0 { c++ } END { exit (c+0)>0 ? 0 : 1 }'
}

# 讀一列並統一成 8 欄。缺的欄位只填預設，不改寫歷史列。
#   thread 沒有、id 也不是 deep- 開頭（O 票）→ 用 id 當 thread（同票重派所以還是同一個）
ledger_fields() {
  awk -F'\t' 'BEGIN{OFS="\t"} {
    if (NF < 8) $8 = $8        # 指定第 8 欄就把 NF 撐到 8，中間補空欄（改寫 $NF 不會重切欄，會無窮迴圈）
    if ($7=="" || $7=="-") $7 = ($1 ~ /^deep-/) ? "-" : $1
    if ($8=="" || $8=="-") $8 = ($1 ~ /^deep-/) ? "deep" : "dcq"
    print
  }'
}
