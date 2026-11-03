#!/usr/bin/env bash
# 共用 ledger 鎖與讀寫（D）。所有改 state/dispatch-jobs.tsv 的地方都先 source 這個再在鎖內改。
# 呼叫端要已設好 $TSV（或它自己算）。用法：
#   ledger_lock || exit 1 ; ...改檔... ; ledger_unlock
#   ledger_read  → 讀一行並裁成 8 欄（舊 5／6 欄列補預設，thread/backend 推導）
set -u

LEDGER_LOCK="${LEDGER_LOCK:-$MYTHOS_DIR/state/.ledger.lock}"

# 接手（reap）：先把鎖目錄原子搬走再刪，兩個等待者不會互刪對方剛建的新鎖；
# 搬走的目錄只刪得到「被搬走的那個」，pid 檔比對後不是自己的絕不動。
ledger_reap() {
  local moved="$LEDGER_LOCK.stale.$$"
  mv "$LEDGER_LOCK" "$moved" 2>/dev/null || return 1
  rm -rf "$moved"
}

ledger_lock() {
  local pid_file="$LEDGER_LOCK/pid" waited=0 holder mtime age
  mkdir -p "$(dirname "$LEDGER_LOCK")"
  until mkdir "$LEDGER_LOCK" 2>/dev/null; do
    holder="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "$holder" ]; then
      # 持有者已死就接手
      if ! kill -0 "$holder" 2>/dev/null; then ledger_reap; continue; fi
    else
      # 還沒寫 pid：鎖 mtime 超過 10 秒＝建立者死在寫 pid 之前
      mtime="$(stat -f %m "$LEDGER_LOCK" 2>/dev/null || stat -c %Y "$LEDGER_LOCK" 2>/dev/null || echo "$(date +%s)")"
      age=$(( $(date +%s) - mtime ))
      if [ "$age" -ge 10 ]; then ledger_reap; continue; fi
    fi
    waited=$((waited + 1))
    [ "$waited" -ge 50 ] && return 1          # 10 秒 × 0.2
    sleep 0.2
  done
  printf '%s\n' "$$" > "$pid_file"
  return 0
}

# 只刪 pid 是自己的鎖：別人接手後 pid 檔換人，這裡不會誤刪
ledger_mine() { [ "$(cat "$LEDGER_LOCK/pid" 2>/dev/null || true)" = "$$" ]; }
ledger_unlock() {
  ledger_mine || return 0
  rm -rf "$LEDGER_LOCK"
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
