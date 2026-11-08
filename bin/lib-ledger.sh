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

# 11-07：claude 會在 transcript 尾端追加不帶 timestamp 的中繼列（last-prompt、cost-state），
# mtime 一直被刷新，真卡死判不出來。從檔尾 400 列找最後一筆帶 timestamp 的 JSON 列轉 epoch；
# 取不到就 rc=1、不輸出（呼叫端退回 transcript mtime）。watchdog 與 dispatch-watch 都 source 這份。
last_ts_epoch() { # transcript
  local draw
  draw="$(tail -n 400 "$1" 2>/dev/null | jq -r 'select(type=="object" and .timestamp != null) | .timestamp' 2>/dev/null | tail -n 1)" || draw=''
  [ -n "$draw" ] || return 1
  "${NODE_BIN:-node}" -e 'const e = Date.parse(process.argv[1]); if (isNaN(e)) process.exit(1); console.log(Math.floor(e / 1000));' "$draw" 2>/dev/null
}

# ---- P4 N03：同 repo 寫入序列化（hermes） ----
# prompt 檔宣告目標 repo：一行 `repo=<絕對路徑>`；唯讀另加 `readonly=1`。兩者都取檔內最後一行（interrupt 的新指示在後面、覆蓋原需求）。
# 沒宣告 repo ＝不參與序列化（現行行為）。唯讀不擋、也不被擋。
prompt_repo_of() { # prompt 檔 → 印正規化後的 repo（空＝沒宣告）
  local r
  r="$(awk '/^repo=\//{v=substr($0,6)} END{print v}' "$1" 2>/dev/null)"
  [ -n "$r" ] || return 0
  if [ -d "$r" ]; then (cd "$r" 2>/dev/null && pwd -P) || printf '%s\n' "$r"; else printf '%s\n' "$r"; fi
}
prompt_readonly_of() { # prompt 檔 → 印 1＝唯讀，空＝寫入（預設）
  awk '/^readonly=/{v=substr($0,10)} END{if (v=="1") print 1}' "$1" 2>/dev/null
}
# 有沒有 pending 的 hermes 寫入列已佔用同一 repo（唯讀列不算）。0＝有、1＝沒有。
# 呼叫端：dispatch-bg 持 ledger 鎖時呼叫（權威）；dispatch-watch 不持鎖時只當預判，dispatch-bg 會再查一次。
hermes_repo_busy() { # repo
  local want="$1" tsv="$MYTHOS_DIR/state/dispatch-jobs.tsv" p
  [ -f "$tsv" ] || return 1
  while IFS=$'\t' read -r p; do
    [ -n "$p" ] || continue
    [ "$(prompt_repo_of "$p")" = "$want" ] || continue
    [ -n "$(prompt_readonly_of "$p")" ] && continue
    return 0
  done < <(awk -F'\t' '$5=="pending" && $8=="hermes" {print $3}' "$tsv")
  return 1
}

# ---- P4 N02：follow-up 直通的 generation 與收據 ----
# generation：每次 --cancel／--interrupt 停掉 thread 就 +1（state/followup/gen-<thread>）。
# 收據 state/followup/receipts.tsv 一行一事件：epoch event chat fmid thread gen job detail
#   event＝queued（入列）／consumed（信箱派出）／stale（舊 generation，不消費）。同 chat+fmid 有 queued 即視為已入列（去重）。
followup_gen() { # thread → 目前 generation（沒檔＝0）
  local f="${MYTHOS_DIR:-$(cd "$LEDGER_LIB_DIR/.." && pwd)}/state/followup/gen-$1" n
  if [ -f "$f" ]; then n="$(tr -dc '0-9' < "$f")"; fi
  printf '%s\n' "${n:-0}"
}
followup_gen_bump() { # thread
  local d="${MYTHOS_DIR:-$(cd "$LEDGER_LIB_DIR/.." && pwd)}/state/followup" n
  mkdir -p "$d" || return 1
  n=$(( $(followup_gen "$1") + 1 ))
  printf '%s\n' "$n" > "$d/gen-$1.tmp" && mv -f "$d/gen-$1.tmp" "$d/gen-$1"
}
followup_receipt() { # event chat fmid thread gen job detail
  local d="${MYTHOS_DIR:-$(cd "$LEDGER_LIB_DIR/.." && pwd)}/state/followup"
  mkdir -p "$d" || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" "$4" "$5" "${6:--}" "$(printf '%s' "${7:-}" | tr '\t\n' '  ')" >> "$d/receipts.tsv"
}
# 最後一筆 queued 收據的 generation（沒有＝空）
followup_queued_gen() { # chat fmid thread
  local f="${MYTHOS_DIR:-$(cd "$LEDGER_LIB_DIR/.." && pwd)}/state/followup/receipts.tsv"
  [ -f "$f" ] || return 0
  awk -F'\t' -v c="$1" -v m="$2" -v t="$3" '$2=="queued" && $3==c && $4==m && $5==t {g=$6} END{print g}' "$f"
}
