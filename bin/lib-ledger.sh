#!/usr/bin/env bash
# 共用 ledger 鎖與讀寫（D）。所有改 state/dispatch-jobs.tsv 的地方都先 source 這個再在鎖內改。
# 呼叫端要已設好 $TSV（或它自己算）。用法：
#   ledger_lock || exit 1 ; ...改檔... ; ledger_unlock
#   ledger_read  → 讀一行並裁成 8 欄（舊 5／6 欄列補預設，thread/backend 推導）
set -u

LEDGER_LOCK="${LEDGER_LOCK:-$MYTHOS_DIR/state/.ledger.lock}"

ledger_lock() {
  local pid_file="$LEDGER_LOCK/pid" waited=0 holder
  mkdir -p "$(dirname "$LEDGER_LOCK")"
  until mkdir "$LEDGER_LOCK" 2>/dev/null; do
    holder="$(cat "$pid_file" 2>/dev/null || true)"
    # 持有者已死（或還沒寫 pid 且鎖很久了）就接手；不然等
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "$LEDGER_LOCK"
      continue
    fi
    waited=$((waited + 1))
    [ "$waited" -ge 50 ] && return 1          # 10 秒 × 0.2
    sleep 0.2
  done
  printf '%s\n' "$$" > "$pid_file"
  return 0
}

ledger_unlock() { rm -rf "$LEDGER_LOCK"; }

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
